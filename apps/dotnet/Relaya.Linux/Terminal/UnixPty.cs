using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Relaya.Terminal;

/// Процесс в псевдотерминале Linux: те же события и методы, что у PseudoConsole (ConPTY) на Windows.
/// Без fork() из управляемого кода: posix_spawnp с POSIX_SPAWN_SETSID, а slave открывается уже в новой
/// сессии и становится управляющим терминалом (glibc делает setsid до file actions).
internal sealed class UnixPty : IDisposable
{
    private readonly int master;
    private readonly int pid;
    private readonly FileStream stream;
    private int exited;

    public event Action<byte[]>? Output;
    public event Action<int>? Exited;

    public int ProcessId => pid;

    public UnixPty(string[] argv, short cols, short rows, IDictionary<string, string>? extraEnv = null)
    {
        master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
        if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        var name = new byte[128];
        if (ptsname_r(master, name, name.Length) != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        Resize(cols, rows);

        var env = new Dictionary<string, string>();
        foreach (DictionaryEntry e in Environment.GetEnvironmentVariables()) env[(string)e.Key] = (string?)e.Value ?? "";
        env["TERM"] = "xterm-256color";
        if (extraEnv != null) foreach (var (k, v) in extraEnv) env[k] = v;

        var actions = Marshal.AllocHGlobal(1024);
        var attr = Marshal.AllocHGlobal(1024);
        var set = Marshal.AllocHGlobal(256);
        var args = Strings(argv);
        var envp = Strings([.. System.Linq.Enumerable.Select(env, kv => $"{kv.Key}={kv.Value}")]);
        try
        {
            posix_spawn_file_actions_init(actions);
            posix_spawn_file_actions_addopen(actions, 0, name, O_RDWR, 0);
            posix_spawn_file_actions_adddup2(actions, 0, 1);
            posix_spawn_file_actions_adddup2(actions, 0, 2);
            posix_spawnattr_init(attr);
            // Маску и обработчики сигналов .NET (SIGPIPE игнорируется и т. п.) ssh наследовать не должен.
            sigemptyset(set);
            posix_spawnattr_setsigmask(attr, set);
            sigfillset(set);
            posix_spawnattr_setsigdefault(attr, set);
            posix_spawnattr_setflags(attr, PosixSpawnSetsid | PosixSpawnSetsigmask | PosixSpawnSetsigdef);
            var rc = posix_spawnp(out pid, argv[0], actions, attr, args, envp);
            if (rc != 0) throw new Win32Exception(rc);
        }
        finally
        {
            posix_spawn_file_actions_destroy(actions);
            posix_spawnattr_destroy(attr);
            Marshal.FreeHGlobal(actions);
            Marshal.FreeHGlobal(attr);
            Marshal.FreeHGlobal(set);
            Free(args);
            Free(envp);
        }
        stream = new FileStream(new SafeFileHandle(master, ownsHandle: false), FileAccess.ReadWrite, 1);
    }

    /// Чтение и ожидание выхода — только после подписки на Output/Exited, как у PseudoConsole.
    public void Start()
    {
        Task.Factory.StartNew(ReadLoop, TaskCreationOptions.LongRunning);
        Task.Factory.StartNew(() =>
        {
            int status;
            while (waitpid(pid, out status, 0) < 0 && Marshal.GetLastWin32Error() == EINTR) { }
            Volatile.Write(ref exited, 1);
            var code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f);
            Exited?.Invoke(code);
        }, TaskCreationOptions.LongRunning);
    }

    private void ReadLoop()
    {
        var buf = new byte[16 * 1024];
        try
        {
            int n;
            // Когда процесс закрыл slave, read() на master даёт EIO — это конец потока.
            while ((n = stream.Read(buf)) > 0)
            {
                try { Output?.Invoke(buf[..n]); }
                catch (Exception e) { System.Diagnostics.Debug.WriteLine($"pty output handler: {e}"); }
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    public void Write(byte[] data)
    {
        try { stream.Write(data); stream.Flush(); }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    public void Resize(short cols, short rows)
    {
        var ws = new WinSize { Rows = (ushort)rows, Cols = (ushort)cols };
        ioctl(master, TIOCSWINSZ, ref ws);
    }

    public void Dispose()
    {
        if (Volatile.Read(ref exited) == 0) kill(pid, SIGHUP);
        stream.Dispose();
        close(master);
    }

    private static IntPtr Strings(string[] items)
    {
        var p = Marshal.AllocHGlobal(IntPtr.Size * (items.Length + 1));
        for (var i = 0; i < items.Length; i++) Marshal.WriteIntPtr(p, i * IntPtr.Size, Marshal.StringToCoTaskMemUTF8(items[i]));
        Marshal.WriteIntPtr(p, items.Length * IntPtr.Size, IntPtr.Zero);
        return p;
    }

    private static void Free(IntPtr p)
    {
        for (var i = 0; ; i++)
        {
            var s = Marshal.ReadIntPtr(p, i * IntPtr.Size);
            if (s == IntPtr.Zero) break;
            Marshal.FreeCoTaskMem(s);
        }
        Marshal.FreeHGlobal(p);
    }

    // Значения одинаковы для x86_64 и aarch64.
    private const int O_RDWR = 2, O_NOCTTY = 0x100, O_CLOEXEC = 0x80000;
    private const ulong TIOCSWINSZ = 0x5414;
    private const int EINTR = 4, SIGHUP = 1;
    private const short PosixSpawnSetsigdef = 0x04, PosixSpawnSetsigmask = 0x08, PosixSpawnSetsid = 0x80;

    [StructLayout(LayoutKind.Sequential)]
    private struct WinSize { public ushort Rows, Cols, XPixel, YPixel; }

    [DllImport("libc", SetLastError = true)] private static extern int posix_openpt(int flags);
    [DllImport("libc", SetLastError = true)] private static extern int grantpt(int fd);
    [DllImport("libc", SetLastError = true)] private static extern int unlockpt(int fd);
    [DllImport("libc", SetLastError = true)] private static extern int ptsname_r(int fd, byte[] buf, nint len);
    [DllImport("libc", SetLastError = true)] private static extern int ioctl(int fd, ulong request, ref WinSize ws);
    [DllImport("libc", SetLastError = true)] private static extern int close(int fd);
    [DllImport("libc", SetLastError = true)] private static extern int kill(int pid, int sig);
    [DllImport("libc", SetLastError = true)] private static extern int waitpid(int pid, out int status, int options);
    [DllImport("libc")] private static extern int sigemptyset(IntPtr set);
    [DllImport("libc")] private static extern int sigfillset(IntPtr set);
    [DllImport("libc")] private static extern int posix_spawn_file_actions_init(IntPtr fa);
    [DllImport("libc")] private static extern int posix_spawn_file_actions_destroy(IntPtr fa);
    [DllImport("libc")] private static extern int posix_spawn_file_actions_addopen(IntPtr fa, int fd, byte[] path, int flags, uint mode);
    [DllImport("libc")] private static extern int posix_spawn_file_actions_adddup2(IntPtr fa, int fd, int newfd);
    [DllImport("libc")] private static extern int posix_spawnattr_init(IntPtr attr);
    [DllImport("libc")] private static extern int posix_spawnattr_destroy(IntPtr attr);
    [DllImport("libc")] private static extern int posix_spawnattr_setflags(IntPtr attr, short flags);
    [DllImport("libc")] private static extern int posix_spawnattr_setsigmask(IntPtr attr, IntPtr set);
    [DllImport("libc")] private static extern int posix_spawnattr_setsigdefault(IntPtr attr, IntPtr set);
    [DllImport("libc")] private static extern int posix_spawnp(out int pid, string file, IntPtr fa, IntPtr attr, IntPtr argv, IntPtr envp);
}
