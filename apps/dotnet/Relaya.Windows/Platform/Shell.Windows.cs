using System.Diagnostics;

namespace Relaya.Platform;

internal static partial class Shell
{
    public static partial void OpenFolder(string path)
    {
        var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        info.ArgumentList.Add(path);
        // Из обработчика кнопки: без файлового менеджера — запись в трассировку, а не падение.
        try { Process.Start(info); }
        catch (System.Exception e) { Trace.WriteLine($"Shell.OpenFolder: {e.Message}"); }
    }

    public static partial void Reveal(string path)
    {
        var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        info.ArgumentList.Add("/select," + path);
        try { Process.Start(info); }
        catch (System.Exception e) { Trace.WriteLine($"Shell.Reveal: {e.Message}"); }
    }

    // SHFileOperation без своих окон (FOF_NO_UI): ошибку показывает вызывающий, второго системного окна нет.
    public static partial void Trash(string path)
    {
        var op = new ShFileOp { wFunc = FO_DELETE, pFrom = path + "\0\0", fFlags = FOF_ALLOWUNDO | FOF_NO_UI };
        var rc = SHFileOperationW(ref op);
        if (rc != 0 || op.fAnyOperationsAborted) throw new System.IO.IOException(Relaya.Strings.L("Не удалось переместить в Корзину: %@", path));
    }

    private const uint FO_DELETE = 3;
    private const ushort FOF_ALLOWUNDO = 0x40, FOF_NO_UI = 0x614; // SILENT | NOCONFIRMATION | NOERRORUI | NOCONFIRMMKDIR

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private struct ShFileOp
    {
        public System.IntPtr hwnd;
        public uint wFunc;
        public string pFrom;
        public string? pTo;
        public ushort fFlags;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public System.IntPtr hNameMappings;
        public string? lpszProgressTitle;
    }

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int SHFileOperationW(ref ShFileOp op);
}
