import Testing
@testable import RelayaCore

@Suite struct PasswordPromptTests {
    @Test(arguments: [
        "root@10.0.0.5's password: ",
        "Last login...\nPassword:",
        "(deploy@bastion) Password: ",
    ])
    func detectsSSHPrompts(_ text: String) {
        #expect(PasswordPrompt.matches(text))
    }

    @Test(arguments: [
        "[sudo] password for ubuntu: ",
        "Enter passphrase for key '/Users/me/.ssh/id_ed25519': ",
        "password: ok\n$ ",
        "New password: ",
        "Current password: ",
    ])
    func ignoresOtherPrompts(_ text: String) {
        #expect(!PasswordPrompt.matches(text))
    }
}

@Suite struct KeychainAccountTests {
    @Test func accountUsesEndpointNotAlias() {
        let a = SSHHost(alias: "web", hostName: "1.2.3.4", user: "root", port: 2222)
        var b = a
        b.alias = "renamed"
        #expect(a.keychainAccount == "root@1.2.3.4:2222")
        #expect(a.keychainAccount == b.keychainAccount)
    }

    @Test func defaultsPortAndHost() {
        #expect(SSHHost(alias: "box", user: "u").keychainAccount == "u@box:22")
    }
}

@Suite struct KeyFingerprintTests {
    @Test func parsesKeygenOutput() {
        let fp = KeyFingerprint.parse("256 SHA256:Xq3vN1abc heckfy@macbook-air · web (ED25519)\n")
        #expect(fp == KeyFingerprint(bits: 256, fingerprint: "SHA256:Xq3vN1abc",
                                     comment: "heckfy@macbook-air · web", type: "ed25519"))
    }

    @Test func rejectsGarbage() {
        #expect(KeyFingerprint.parse("The agent has no identities.") == nil)
    }

    @Test func identityFileAddsKeychainDirectives() throws {
        var doc = SSHConfigDocument(text: "")
        try doc.upsert(SSHHost(alias: "h", identityFile: "~/.ssh/k"), originalAlias: nil)
        #expect(doc.text == "Host h\n    IdentityFile ~/.ssh/k\n    UseKeychain yes\n    AddKeysToAgent yes\n")
    }
}

struct SudoPromptTests {
    @Test func detectsSudoPrompts() {
        #expect(PasswordPrompt.isSudo("$ sudo apt update\n[sudo] password for alex: "))
        #expect(PasswordPrompt.isSudo("[sudo] пароль для alex:"))
        #expect(!PasswordPrompt.isSudo("alex@host's password:"))
        #expect(!PasswordPrompt.matches("[sudo] password for alex:"))
    }
}
