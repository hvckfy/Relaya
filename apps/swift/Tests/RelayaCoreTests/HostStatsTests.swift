import Testing
@testable import RelayaCore

@Suite struct HostStatsTests {
    @Test func parsesLinuxOutput() throws {
        let out = """
        L 0.52 0.40 0.31 1/245 12345
        N 4
        M 8048576 6024288
        D 41152736 18874368
        U 3600.25
        """
        let s = try #require(HostStats.parse(out))
        #expect(s.cores == 4)
        #expect(abs(s.loadPercent - 0.13) < 0.001)
        #expect(s.memTotal == 8048576 * 1024)
        #expect(abs(s.memPercent - 0.2515) < 0.001)
        #expect(abs(s.diskPercent - 0.4586) < 0.001)
        #expect(s.uptime == 3600.25)
    }

    @Test func busyboxWithoutMemAvailable() throws {
        // В старых ядрах/busybox MemAvailable нет — берём MemFree (awk в команде).
        let s = try #require(HostStats.parse("L 1.0 1 1\nN 1\nM 1000 250\nD 100 50\nU 10"))
        #expect(s.loadPercent == 1)
        #expect(s.memPercent == 0.75)
    }

    @Test func nonLinuxGivesNil() {
        #expect(HostStats.parse("L \nN \nU ") == nil)
    }
}
