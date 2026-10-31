import Foundation
import Testing
@testable import RelayaCore

struct TmuxTests {
    @Test func nameIsShellSafe() {
        let name = Tmux.sessionName(alias: "Web 1.prod", id: UUID(uuidString: "3F9A0000-0000-0000-0000-000000000000")!)
        #expect(name == "relaya-web-1-prod--3f9a0000")
    }

    @Test func attachCommandCreatesOrAttachesAndArmsReaper() {
        let cmd = Tmux.attachCommand(name: "relaya-a-1", ttlMinutes: 60)
        #expect(cmd.contains("new-session -A -s relaya-a-1"))
        #expect(cmd.contains("client-detached"))
        #expect(cmd.contains("sleep 3600"))
        #expect(cmd.contains("kill-session -t relaya-a-1"))
        #expect(cmd.contains("else exec"))
    }

    @Test func parsesListing() {
        let out = "relaya-a-1|0|100|200|150|1\nrelaya-a-2|1|100|300||\nother|0|1|1||\n"
        let s = Tmux.parse(out)
        #expect(s.count == 2)
        #expect(s[0].keep && s[0].detachedAt == Date(timeIntervalSince1970: 150))
        #expect(s[1].attached == 1 && s[1].detachedAt == nil && !s[1].keep)
    }

    @Test func staleSkipsAttachedOpenFreshAndOtherHosts() {
        let now = Date(timeIntervalSince1970: 10_000)
        let old = Date(timeIntervalSince1970: 10_000 - 7200)
        let fresh = Date(timeIntervalSince1970: 10_000 - 60)
        let s = [
            TmuxSession(name: "relaya-a--0000001d", attached: 0, created: old, activity: old, detachedAt: old),
            TmuxSession(name: "relaya-a--0000f2e5", attached: 0, created: old, activity: fresh, detachedAt: fresh),
            TmuxSession(name: "relaya-a--000000a0", attached: 1, created: old, activity: old, detachedAt: old),
            TmuxSession(name: "relaya-a--000000ab", attached: 0, created: old, activity: old, detachedAt: old),
            TmuxSession(name: "relaya-a--000000ee", attached: 0, created: old, activity: old, detachedAt: old, keep: true),
            TmuxSession(name: "relaya-b--0000001d", attached: 0, created: old, activity: old, detachedAt: old),
        ]
        #expect(Tmux.stale(s, alias: "a", open: ["relaya-a--000000ab"], ttlMinutes: 60, now: now) == ["relaya-a--0000001d"])
    }

    @Test func staleEnforcesCap() {
        let now = Date(timeIntervalSince1970: 10_000)
        let s = (0..<12).map { i in
            TmuxSession(name: String(format: "relaya-a--%08x", i), attached: 0, created: now,
                        activity: Date(timeIntervalSince1970: 9_000 + Double(i)), detachedAt: now)
        }
        #expect(Tmux.stale(s, alias: "a", open: [], ttlMinutes: 60, now: now) == ["relaya-a--00000000", "relaya-a--00000001"])
    }
}

struct TmuxMetaTests {
    @Test func tmuxFlagRoundTrips() {
        let hosts = SSHConfigParser.parse("# relaya: tmux=on\nHost a\n    HostName a.example\n")
        #expect(hosts.first?.tmux == true)
        #expect(SSHConfigParser.parse("Host b\n").first?.tmux == false)
    }
}
