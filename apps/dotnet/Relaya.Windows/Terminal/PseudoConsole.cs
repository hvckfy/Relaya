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
    private readonly Process process;

    public event Action<byte[]>? Output;
    public event Action<int>? Exited;

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
            CloseHandle(pi.hProcess);
            process = Process.GetProcessById(pi.dwProcessId);
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
            await process.WaitForExitAsync();
            Exited?.Invoke(process.ExitCode);
        });
    }

    private async Task ReadLoop()
    {
        var buf = new byte[16 * 1024];
        try
        {
            int n;
            while ((n = await output.ReadAsync(buf)) > 0) Output?.Invoke(buf[..n]);
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
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
        try { if (!process.HasExited) process.Kill(); } catch (InvalidOperationException) { }
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
}
