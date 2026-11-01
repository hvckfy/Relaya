using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using uniffi.relaya_core;
using static Relaya.Strings;

namespace Relaya.Platform;

/// Кодек H.264 от Cisco (OpenH264) для встроенного RDP (чек-лист 9.12), как OpenH264.swift на Mac: скачивается только
/// по включению (лицензия Cisco разрешает распространять их двоичный файл, но не наш). Проверки — в ядре: sha256 архива,
/// sha256 библиотеки перед каждым использованием, FreeRDP грузит проверенную копию (checked_copy). Windows — не нужно:
/// там H.264 через Media Foundation.
internal static class OpenH264
{
    /// Переключатель есть, если ядро собрано с FreeRDP (remote_supports_h264) и это не Windows.
    public static bool Available => !OperatingSystem.IsWindows() && RelayaCoreMethods.RemoteSupportsH264() && Info != null;

    public static OpenH264Info? Info =>
        RelayaCoreMethods.Openh264CurrentPlatform() is { } p ? RelayaCoreMethods.Openh264Info(p) : null;

    public static string? LibraryFile => Info is { } i ? Path.Combine(Data.AppState.Support, i.fileName) : null;

    public static bool IsInstalled => LibraryFile is { } f && File.Exists(f) && RelayaCoreMethods.Openh264Verify(f);

    /// Путь для RdpConfig.h264LibraryPath; null — H.264 выключен.
    public static string? LibraryPath => Available && IsInstalled ? LibraryFile : null;

    /// Скачать (https), проверить архив, распаковать во временный файл 0600, проверить библиотеку, переименовать.
    public static async Task InstallAsync()
    {
        if (Info is not { } info || RelayaCoreMethods.Openh264CurrentPlatform() is not { } platform || LibraryFile is not { } dest)
            throw new InvalidOperationException(L("Для этой платформы кодека нет."));
        Directory.CreateDirectory(Data.AppState.Support);
        var archive = dest + ".bz2.part";
        var tmp = dest + ".part";
        try
        {
            // Сервер Cisco отдаёт и https — канал шифруем (S4), целостность держит закреплённый sha256.
            var url = info.url.Replace("http://", "https://", StringComparison.Ordinal);
            using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(2) })
            using (var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
            {
                response.EnsureSuccessStatusCode();
                await using var file = File.Create(archive);
                await response.Content.CopyToAsync(file);
            }
            if (!RelayaCoreMethods.Openh264VerifyArchive(archive, platform))
                throw new InvalidOperationException(L("Архив кодека не прошёл проверку — не устанавливаю."));
            await DecompressAsync(archive, tmp);
            if (!RelayaCoreMethods.Openh264Verify(tmp))
                throw new InvalidOperationException(L("Библиотека кодека не прошла проверку — не устанавливаю."));
            File.Move(tmp, dest, overwrite: true);
        }
        finally
        {
            TryDelete(archive);
            TryDelete(tmp);
        }
    }

    /// Выключить: удалить библиотеку.
    public static void Remove()
    {
        if (LibraryFile is { } f && File.Exists(f)) File.Delete(f);
    }

    // bunzip2 -c в файл 0600: в .NET нет bz2, системный bzip2 есть в любом дистрибутиве (Depends пакета).
    private static async Task DecompressAsync(string archive, string target)
    {
        var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        await using var output = new FileStream(target, options);
        var info = new ProcessStartInfo("bunzip2") { UseShellExecute = false, RedirectStandardOutput = true };
        info.ArgumentList.Add("-c");
        info.ArgumentList.Add(archive);
        using var p = Process.Start(info) ?? throw new InvalidOperationException(L("Не удалось распаковать кодек."));
        await p.StandardOutput.BaseStream.CopyToAsync(output);
        await p.WaitForExitAsync();
        if (p.ExitCode != 0) throw new InvalidOperationException(L("Не удалось распаковать кодек."));
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception) { }
    }
}
