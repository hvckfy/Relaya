import Testing
@testable import RelayaCore

struct FuzzyMatchTests {
    @Test func matchesInOrder() {
        #expect(FuzzyMatch.score("dbp", in: "db-primary") != nil)
        #expect(FuzzyMatch.score("xyz", in: "db-primary") == nil)
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }

    @Test func prefersWordStartsAndSubstrings() {
        let a = FuzzyMatch.score("web", in: "web-1")!
        let b = FuzzyMatch.score("web", in: "jellyfin-webui-backup")!
        #expect(a > b)
        let c = FuzzyMatch.score("pp", in: "proxmox-pve1")!
        let d = FuzzyMatch.score("pp", in: "happy")!
        #expect(c > d)
    }

    @Test func multipleFields() {
        #expect(FuzzyMatch.score("192.168", in: ["web-1", "root@192.168.1.5"]) != nil)
    }
}
