import Testing
@testable import RelayaCore

@Suite struct RemoteDesktopTests {
    @Test func vncURL() {
        let d = RemoteDesktop(name: "mini", kind: .vnc, address: "10.0.0.5", user: "admin")
        #expect(d.port == 5900)
        #expect(d.vncURL(host: "10.0.0.5", port: 5900)?.absoluteString == "vnc://admin@10.0.0.5:5900")
    }

    @Test func rdpFile() {
        let d = RemoteDesktop(name: "win", kind: .rdp, address: "win.local", user: "CORP\\me", fullScreen: true)
        let f = d.rdpFile(host: "localhost", port: 51000)
        #expect(f.contains("full address:s:localhost:51000\r\n"))
        #expect(f.contains("username:s:CORP\\me"))
        #expect(f.contains("screen mode id:i:2"))
    }

    @Test func tunnelViaSSH() {
        let d = RemoteDesktop(name: "x", kind: .vnc, address: "localhost", viaSSHHost: "mac-mini")
        let t = d.tunnel(localPort: 55900)
        #expect(t?.spec == "55900:localhost:5900")
        #expect(t?.hostAlias == "mac-mini")
        #expect(RemoteDesktop(name: "y", kind: .rdp, address: "a").tunnel(localPort: 1) == nil)
    }

    @Test func freePort() {
        #expect((1024...65535).contains(RemoteDesktop.freeLocalPort()))
    }
}
