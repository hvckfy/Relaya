using System.IO;
using uniffi.relaya_core;

namespace Relaya.Platform;

/// <summary>
/// Stops background logins to a host after the server refused one (B-4, B-5): every further attempt with the same
/// password or key is another failed login, and fail2ban bans the address after a few. The gate opens again on
/// Refresh in the host card, a password change or a successful login.
/// </summary>
/// <remarks>
/// The state is the core's <c>login-gate.json</c> in the Relaya folder, shared with the <c>--mcp</c> process (B-7):
/// Refresh or a new password in the app also lets agents try again, without restarting the MCP server.
/// </remarks>
internal static class LoginGate
{
    /// <summary>The gate file shared by the app and the MCP server.</summary>
    public static readonly string File = Path.Combine(Data.AppState.Support, "login-gate.json");

    /// <summary>Raised with the host alias when a background call was refused (the disk unmounts on it).</summary>
    public static event System.Action<string>? Closed;

    /// <summary>The reason background calls to this host are stopped, or null when they may run.</summary>
    public static string? Reason(string alias) => RelayaCoreMethods.LoginGateReason(File, alias);

    /// <summary>Records the outcome of a background ssh or sftp call; returns true when it was a refusal.</summary>
    /// <remarks>
    /// The rule is the core's <c>login_outcome</c>: only exit code 255 with a refusal or block closes the gate; a
    /// failed command proves the login worked (V-1); a negative status (timeout, cancel, not started) changes nothing.
    /// </remarks>
    public static bool Note(string alias, int status, string stderr)
    {
        switch (RelayaCoreMethods.LoginOutcome(status, false, stderr))
        {
            case LoginOutcome.Worked:
                Open(alias);
                return false;
            case LoginOutcome.Refused:
                var wasOpen = Reason(alias) == null;
                Write(() => RelayaCoreMethods.LoginGateClose(File, alias, SshErrors.Describe(stderr, Strings.L("Сервер не принял вход."))));
                if (wasOpen) Closed?.Invoke(alias);
                return true;
            default:
                return false;
        }
    }

    /// <summary>Allows background calls again: Refresh, a new password, a successful login.</summary>
    public static void Open(string alias) => Write(() => RelayaCoreMethods.LoginGateOpen(File, alias));

    /// <summary>Raised with the error text when the gate file cannot be written; agents then keep the old state.</summary>
    public static event System.Action<string>? WriteFailed;

    // Callers are UI handlers and background probes: a write error must not crash them, it is reported instead.
    private static void Write(System.Action body)
    {
        try { body(); }
        catch (CoreException e)
        {
            Terminal.TerminalView.Trace("login gate: " + e.Message);
            WriteFailed?.Invoke(Strings.L("Не удалось сохранить состояние входа: %@", e.Message));
        }
    }
}
