import Testing
@testable import RelayaCore

@Suite struct ServerOSTests {
    @Test func parsesUbuntu() {
        #expect(ServerOS.parse(probe: "Linux\nNAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n") == .ubuntu)
    }

    @Test func openWrtWinsOverOsRelease() {
        #expect(ServerOS.parse(probe: "Linux\nNAME=\"OpenWrt\"\nID=\"openwrt\"\nID=openwrt\n") == .openwrt)
    }

    @Test func fallsBackToIDLike() {
        #expect(ServerOS.parse(probe: "Linux\nID=kali\nID_LIKE=debian\n") == .kali)
        #expect(ServerOS.parse(probe: "Linux\nID=debian\nID=proxmox\n") == .proxmox)
        #expect(ServerOS.parse(probe: "Linux\nID=someforkofdebian\nID_LIKE=debian\n") == .debian)
    }

    @Test func unameOnly() {
        #expect(ServerOS.parse(probe: "Darwin\n") == .macos)
        #expect(ServerOS.parse(probe: "Linux\n") == .linux)
        #expect(ServerOS.parse(probe: "") == nil)
    }

    @Test func guessesFromBanner() {
        #expect(ServerOS.guess(fromBanner: "BusyBox v1.36\n OpenWrt 23.05.3") == .openwrt)
        #expect(ServerOS.guess(fromBanner: "Welcome to Ubuntu 24.04 LTS") == .ubuntu)
        #expect(ServerOS.guess(fromBanner: "Last login: today") == nil)
    }

    @Test func osRoundTripsInMeta() throws {
        var doc = SSHConfigDocument(text: "")
        let host = SSHHost(alias: "r", hostName: "192.168.2.1", user: "root", os: .openwrt)
        try doc.upsert(host, originalAlias: nil)
        #expect(doc.text.hasPrefix("# relaya: os=openwrt\n"))
        #expect(SSHConfigParser.parse(doc.text) == [host])
    }

    @Test func everyOSHasActions() {
        for os in ServerOS.allCases { #expect(!os.actions.isEmpty) }
    }
}

@Suite struct PasswordLoginCommandTests {
    @Test func linuxUsesDropInAndFallback() {
        let off = ServerOS.ubuntu.passwordLoginCommand(enabled: false)
        #expect(off.contains("sshd_config.d/00-relaya.conf"))
        #expect(off.contains("PasswordAuthentication no"))
        #expect(off.contains("sudo sshd -t"))
        #expect(ServerOS.ubuntu.passwordLoginCommand(enabled: true).contains("PasswordAuthentication yes"))
    }

    @Test func openWrtUsesUci() {
        #expect(ServerOS.openwrt.passwordLoginCommand(enabled: false).contains("PasswordAuth='off'"))
        #expect(ServerOS.openwrt.passwordLoginCommand(enabled: true).contains("PasswordAuth='on'"))
    }
}
