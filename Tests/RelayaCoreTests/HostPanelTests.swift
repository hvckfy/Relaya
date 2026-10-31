import Testing
@testable import RelayaCore

struct HostPanelTests {
    let sample = """
    ##SERVICES
    cron.service loaded active running Regular background program processing daemon
    nginx.service loaded failed failed A high performance web server
    ssh.service loaded active running OpenBSD Secure Shell server
    ##PORTS
    tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=612,fd=3))
    tcp LISTEN 0 511 [::]:80 [::]:* users:(("nginx",pid=700,fd=6))
    udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=500,fd=13))
    ##ERRORS
    2026-10-31T10:00:00+0000 web nginx[700]: bind() failed
    ##UPDATES
    openssl/stable 3.0.15-1 amd64 [upgradable from: 3.0.14-1]
    curl/stable 8.5.0-2 amd64 [upgradable from: 8.5.0-1]
    """

    @Test func parsesAllSections() {
        let p = HostPanel.parse(sample)
        #expect(p.hasSystemd)
        #expect(p.services.first?.name == "nginx.service")
        #expect(p.services.first?.isFailed == true)
        #expect(p.services.count == 3)
        #expect(p.services.map(\.shortName) == ["nginx", "cron", "ssh"])
        #expect(p.ports.map(\.port) == [22, 53, 80])
        #expect(p.ports.first?.process == "sshd")
        #expect(p.errors.count == 1)
        #expect(p.updates == ["openssl", "curl"])
    }

    @Test func noPackageManagerAndNoSystemd() {
        let p = HostPanel.parse("##SERVICES\n##PORTS\n##ERRORS\n##UPDATES\nRELAYA_NO_PM\n")
        #expect(!p.hasSystemd)
        #expect(p.updates == nil)
    }

    @Test func commandsQuoteAndSudo() {
        let u = ServiceUnit(name: "my app.service", active: "active", sub: "running", description: "")
        #expect(HostPanel.serviceCommand("restart", u, root: false) == "sudo systemctl restart 'my app.service'")
        #expect(HostPanel.serviceCommand("stop", u, root: true) == "systemctl stop 'my app.service'")
        #expect(HostPanel.probeCommand(for: .debian).contains("apt list --upgradable"))
        #expect(HostPanel.probeCommand(for: .macos).contains("RELAYA_NO_PM"))
    }
}
