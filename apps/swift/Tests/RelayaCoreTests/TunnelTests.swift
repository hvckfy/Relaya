import Foundation
import Testing
@testable import RelayaCore

@Suite struct TunnelTests {
    @Test func localArguments() {
        let t = Tunnel(name: "db", hostAlias: "web", listenPort: 15432, targetHost: "db.internal", targetPort: 5432)
        let args = t.sshArguments(passwordOnly: false)
        #expect(args.suffix(3) == ["-L", "15432:db.internal:5432", "web"])
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ExitOnForwardFailure=yes"))
    }

    @Test func dynamicAndPasswordOnly() {
        let t = Tunnel(name: "socks", hostAlias: "vps", kind: .dynamic, listenPort: 1080)
        let args = t.sshArguments(passwordOnly: true)
        #expect(args.suffix(3) == ["-D", "1080", "vps"])
        #expect(!args.contains("BatchMode=yes"))
        #expect(args.contains("PubkeyAuthentication=no"))
        #expect(t.validationError == nil)
    }

    @Test func validation() {
        #expect(Tunnel(name: "", hostAlias: "h", listenPort: 0).validationError != nil)
        #expect(Tunnel(name: "", hostAlias: "h", listenPort: 80, targetHost: "x", targetPort: 0).validationError != nil)
    }

    @Test func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "relaya-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TunnelStore(url: url)
        let t = Tunnel(name: "a", hostAlias: "h", kind: .remote, listenPort: 9000, targetPort: 3000, autoStart: true)
        try store.save([t])
        #expect(store.load() == [t])
    }
}
