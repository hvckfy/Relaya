using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Relaya.Platform;

/// Пароли хостов в Windows Credential Manager (аналог Keychain на Mac). Запись: «Relaya/<алиас>», тип Generic.
internal static class CredentialStore
{
    private const string Prefix = "Relaya/";

    public static string? Read(string account)
    {
        if (!CredReadW(Prefix + account, CredTypeGeneric, 0, out var ptr)) return null;
        try
        {
            var cred = Marshal.PtrToStructure<Credential>(ptr);
            if (cred.CredentialBlobSize == 0) return "";
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.Unicode.GetString(bytes);
        }
        finally { CredFree(ptr); }
    }

    public static bool Has(string account) => Read(account) != null;

    public static void Write(string account, string secret)
    {
        var bytes = Encoding.Unicode.GetBytes(secret);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var cred = new Credential
            {
                Type = CredTypeGeneric,
                TargetName = Prefix + account,
                UserName = account,
                CredentialBlob = blob,
                CredentialBlobSize = bytes.Length,
                Persist = CredPersistLocalMachine,
            };
            if (!CredWriteW(ref cred, 0)) throw new System.ComponentModel.Win32Exception();
        }
        finally
        {
            Array.Clear(bytes);
            Marshal.FreeHGlobal(blob);
        }
    }

    public static void Delete(string account) => CredDeleteW(Prefix + account, CredTypeGeneric, 0);

    private const int CredTypeGeneric = 1;
    private const int CredPersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public int Flags, Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist, AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias, UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref Credential credential, int flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, int type, int flags);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}

/// Приглашение ssh ввести пароль сервера в конце вывода — как PasswordPrompt на Mac.
internal static class PasswordPrompt
{
    /// Приглашение shell в последней строке: `user@host:~$`, `#`, `>`, `%`.
    public static bool IsShellPrompt(string tail)
    {
        var t = tail.Split('\n')[^1].TrimEnd();
        return t.Length > 1 && (t.EndsWith('$') || t.EndsWith('#') || t.EndsWith('>') || t.EndsWith('%'));
    }

    /// Любой запрос пароля (su, sudo, mysql -p…), а не только ssh: «Password:», «[sudo] password for x:», «Пароль:».
    public static bool IsAnyPasswordPrompt(string tail)
    {
        var t = tail.Split('\n')[^1].Trim().ToLowerInvariant();
        return t.EndsWith(':') && (t.Contains("password") || t.Contains("пароль")) && !t.Contains("passphrase") && !t.Contains("new");
    }

    public static bool Matches(string tail)
    {
        var lines = tail.Split('\n');
        var t = lines[^1].Trim().ToLowerInvariant();
        if (!t.EndsWith("password:")) return false;
        return !t.Contains("sudo") && !t.Contains("passphrase") && !t.Contains("new password") && !t.Contains("current password");
    }
}
