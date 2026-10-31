import Testing
@testable import RelayaCore

struct LocalPortsTests {
    @Test func findsDevServerAddresses() {
        let out = "  VITE ready\n  ➜  Local:   http://localhost:5173/\n  listening on 0.0.0.0:8080, 127.0.0.1:8080 and [::1]:9000"
        #expect(LocalPorts.find(in: out) == [5173, 8080, 9000])
    }

    @Test func ignoresNoise() {
        #expect(LocalPorts.find(in: "ssh localhost:22 and 10.0.0.1:3000 and localhost:99999").isEmpty)
    }
}
