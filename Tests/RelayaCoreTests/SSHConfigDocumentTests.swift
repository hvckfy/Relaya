import Testing
@testable import RelayaCore

@Suite struct SSHConfigDocumentTests {
    static let sample = """
    # мои хосты
    Host *
        ServerAliveInterval 60

    # relaya: group=prod env=prod
    Host db-main
        HostName db.internal
        User postgres
        LocalForward 5432 localhost:5432

    Host a b
        User shared
    """

    @Test func addsHostAtEnd() throws {
        var doc = SSHConfigDocument(text: "Host x\n    User u\n")
        try doc.upsert(SSHHost(alias: "new", hostName: "1.2.3.4", user: "root", group: "dev", environment: .dev),
                       originalAlias: nil)
        #expect(doc.text == """
        Host x
            User u

        # relaya: group=dev env=dev
        Host new
            HostName 1.2.3.4
            User root

        """)
    }

    @Test func addsToEmptyFile() throws {
        var doc = SSHConfigDocument(text: "")
        try doc.upsert(SSHHost(alias: "h", hostName: "h.example"), originalAlias: nil)
        #expect(doc.text == "Host h\n    HostName h.example\n")
    }

    @Test func editKeepsUnknownDirectivesAndRestOfFile() throws {
        var doc = SSHConfigDocument(text: Self.sample)
        var host = try #require(SSHConfigParser.parse(Self.sample).first { $0.alias == "db-main" })
        host.alias = "db-primary"
        host.port = 2222
        try doc.upsert(host, originalAlias: "db-main")

        #expect(doc.text.contains("# мои хосты\nHost *\n    ServerAliveInterval 60\n"))
        #expect(doc.text.contains("""
        # relaya: group=prod env=prod
        Host db-primary
            HostName db.internal
            User postgres
            Port 2222
            LocalForward 5432 localhost:5432

        Host a b
        """))
        #expect(!doc.text.contains("db-main"))
    }

    @Test func roundTripsThroughParser() throws {
        var doc = SSHConfigDocument(text: "")
        let host = SSHHost(alias: "h", hostName: "x", user: "u", port: 2200, identityFile: "~/.ssh/k",
                           proxyJump: "bastion", forwardAgent: true, serverAliveInterval: 30,
                           compression: true, group: "g", environment: .staging, color: "orange")
        try doc.upsert(host, originalAlias: nil)
        #expect(SSHConfigParser.parse(doc.text) == [host])
    }

    @Test func rejectsDuplicateAlias() {
        var doc = SSHConfigDocument(text: Self.sample)
        #expect(throws: SSHConfigDocument.EditError.aliasTaken("db-main")) {
            try doc.upsert(SSHHost(alias: "db-main"), originalAlias: nil)
        }
    }

    @Test func refusesSharedBlock() {
        var doc = SSHConfigDocument(text: Self.sample)
        #expect(throws: SSHConfigDocument.EditError.sharedBlock("a")) {
            try doc.upsert(SSHHost(alias: "a"), originalAlias: "a")
        }
    }

    @Test func removesBlockWithMeta() throws {
        var doc = SSHConfigDocument(text: Self.sample)
        try doc.remove(alias: "db-main")
        #expect(!doc.text.contains("db-main"))
        #expect(!doc.text.contains("relaya:"))
        #expect(doc.text.contains("ServerAliveInterval 60\n\nHost a b"))
    }

    @Test func diffMarksChanges() {
        let d = LineDiff.diff(["a", "b", "c"], ["a", "x", "c", "d"])
        #expect(d.map(\.kind) == [.same, .added, .removed, .same, .added]
                || d.map(\.kind) == [.same, .removed, .added, .same, .added])
    }
}
