using System.Collections.Concurrent;
using uniffi.relaya_core;

namespace Relaya.Platform;

/// <summary>
/// Stops background logins to a host after the server refused one (B-4, B-5): every further attempt with the same
/// password or key is another failed login, and fail2ban bans the address after a few. The gate opens again on
/// Refresh in the host card, a password change or a successful login.
/// </summary>
internal static class LoginGate
{
    private static readonly ConcurrentDictionary<string, string> Refused = new();

    /// <summary>Raised with the host alias when a background call was refused (the disk unmounts on it).</summary>
    public static event System.Action<string>? Closed;

    /// <summary>The reason background calls to this host are stopped, or null when they may run.</summary>
    public static string? Reason(string alias) => Refused.TryGetValue(alias, out var r) ? r : null;

    /// <summary>Records the outcome of a background ssh or sftp call; returns true when it was a refusal.</summary>
    public static bool Note(string alias, int status, string stderr)
    {
        // ssh and sftp exit with 255 when the connection or login fails; a failed command (a read-only folder,
        // docker without the docker group) exits with its own code and proves the login worked (V-1).
        // A negative status (timeout, cancel, not started) says nothing about the login and leaves the gate as is.
        if (status != 255) { if (status >= 0) Open(alias); return false; }
        if (!RelayaCoreMethods.SshAuthRefused(stderr) && !RelayaCoreMethods.SshBlocked(stderr)) return false;
        var reason = SshErrors.Describe(stderr, Strings.L("Сервер не принял вход."));
        if (Refused.TryAdd(alias, reason)) Closed?.Invoke(alias);
        return true;
    }

    /// <summary>Allows background calls again: Refresh, a new password, a successful login.</summary>
    public static void Open(string alias) => Refused.TryRemove(alias, out _);
}
