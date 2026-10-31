using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Relaya.Terminal;

/// Процесс в псевдоконсоли Windows (ConPTY): как pty на macOS — байты туда и обратно плюс размер окна.
internal sealed class PseudoConsole : IDisposable
{
    private IntPtr hpc;
    private readonly FileStream input, output;
    // Свой handle процесса из CreateProcess: GetProcessById падает, если короткий процесс уже завершился.
    private readonly SafeProcessHandle process;

    public event Action<byte[]>? Output;
    public event Action<int>? Exited;

    /// Исключение подписчика Output: чтение продолжается, а сессия пишет ошибку в лог и в терминал.
    public event Action<Exception>? HandlerFailed;

    public PseudoConsole(string commandLine, short cols, short rows)
    {
        if (!CreatePipe(out var inRead, out var inWrite, IntPtr.Zero, 0) ||
            !CreatePipe(out var outRead, out var outWrite, IntPtr.Zero, 0))
            throw new Win32Exception();
        var hr = CreatePseudoConsole(new Coord(cols, rows), inRead, outWrite, 0, out hpc);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        // Концы, переданные консоли, больше не нужны — иначе чтение не увидит конец потока.
        inRead.Dispose();
        outWrite.Dispose();

        var size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        var si = new StartupInfoEx();
        si.StartupInfo.cb = Marshal.SizeOf<StartupInfoEx>();
        // Без STARTF_USESTDHANDLES дочерний процесс наследует std-хендлы родителя (если они есть — перенаправленный
        // вывод, CI, запуск из другой программы) и пишет туда, а не в ConPTY: во вкладке пусто, ssh ждёт пароль и выходит с 255.
        si.StartupInfo.dwFlags = 0x00000100; // STARTF_USESTDHANDLES, хендлы нулевые → консоль ConPTY
        si.lpAttributeList = Marshal.AllocHGlobal(size);
        try
        {
            if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, ref size) ||
                !UpdateProcThreadAttribute(si.lpAttributeList, 0, (IntPtr)ProcThreadAttributePseudoConsole, hpc,
                    (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero) ||
                !CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                    ExtendedStartupInfoPresent, IntPtr.Zero, null, ref si, out var pi))
                throw new Win32Exception();
            CloseHandle(pi.hThread);
            process = new SafeProcessHandle(pi.hProcess, ownsHandle: true);
        }
        finally
        {
            DeleteProcThreadAttributeList(si.lpAttributeList);
            Marshal.FreeHGlobal(si.lpAttributeList);
        }

        input = new FileStream(inWrite, FileAccess.Write);
        output = new FileStream(outRead, FileAccess.Read);
    }

    /// Чтение и ожидание выхода — только после подписки на Output/Exited, иначе первые байты и быстрый выход теряются.
    public void Start()
    {
        Task.Run(ReadLoop);
        Task.Run(async () =>
        {
            int code;
            try
            {
                await Task.Run(() => WaitForSingleObject(process, Infinite));
                code = GetExitCodeProcess(process, out var c) ? (int)c : -1;
            }
            catch (ObjectDisposedException) { return; } // вкладку закрыли
            Exited?.Invoke(code);
        });
    }

    private async Task ReadLoop()
    {
        var buf = new byte[16 * 1024];
        try
        {
            int n;
            while ((n = await output.ReadAsync(buf)) > 0)
            {
                // Исключение подписчика не должно останавливать чтение: иначе ConPTY встаёт,
                // вкладка чёрная, а ssh через время выходит с кодом 255.
                try { Output?.Invoke(buf[..n]); }
                catch (Exception e)
                {
                    Log("ConPTY output handler: " + e);
                    try { HandlerFailed?.Invoke(e); } catch (Exception) { }
                }
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    // %APPDATA%\Relaya\terminal.log — тот же файл, что у TerminalView.
    private static void Log(string message)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Relaya");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "terminal.log"), $"{DateTime.Now:O} {message}\n");
        }
        catch (Exception) { }
    }

    public void Write(byte[] data)
    {
        try { input.Write(data); input.Flush(); }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    public void Resize(short cols, short rows)
    {
        if (hpc != IntPtr.Zero) ResizePseudoConsole(hpc, new Coord(cols, rows));
    }

    public void Dispose()
    {
        if (hpc != IntPtr.Zero) { ClosePseudoConsole(hpc); hpc = IntPtr.Zero; }
        if (!process.IsClosed && WaitForSingleObject(process, 0) != 0) TerminateProcess(process, 1);
        process.Dispose();
        input.Dispose();
        output.Dispose();
    }

    private const int ProcThreadAttributePseudoConsole = 0x00020016;
    private const uint ExtendedStartupInfoPresent = 0x00080000;

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct Coord(short x, short y) { public readonly short X = x, Y = y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public IntPtr lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(Coord size, SafeFileHandle hInput, SafeFileHandle hOutput, uint flags, out IntPtr phPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int ResizePseudoConsole(IntPtr hPC, Coord size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attrs, int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returnSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(string? app, StringBuilder commandLine, IntPtr processAttrs, IntPtr threadAttrs,
        bool inheritHandles, uint flags, IntPtr env, string? cwd, ref StartupInfoEx si, out ProcessInformation pi);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private const uint Infinite = 0xFFFFFFFF;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(SafeProcessHandle handle, out uint code);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(SafeProcessHandle handle, uint code);
}
