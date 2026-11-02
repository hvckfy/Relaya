import RelayaRust

/// Fictional data for `Relaya --demo`, shared with Windows and Linux through the core.
public enum Demo {
    /// The demo `~/.ssh/config`: fictional hosts, documentation addresses only.
    public static var sshConfig: String { demoSshConfig() }
}
