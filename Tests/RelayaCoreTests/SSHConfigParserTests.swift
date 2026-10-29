import Testing
@testable import RelayaCore

@Suite struct SSHConfigParserTests {
    @Test func parsesBasicHost() {
        let hosts = SSHConfigParser.parse("""
        Host prod-api-1
            HostName 10.0.0.5
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """)
        #expect(hosts.count == 1)
        #expect(hosts[0].alias == "prod-api-1")
        #expect(hosts[0].subtitle == "deploy@10.0.0.5:2222")
        #expect(hosts[0].usesKey)
    }

    @Test func skipsWildcardsAndMatch() {
        let hosts = SSHConfigParser.parse("""
        Host *
            User root
        Host a b
            HostName=example.com
        Match host x
            User nobody
        """)
        #expect(hosts.map(\.alias) == ["a", "b"])
        #expect(hosts.allSatisfy { $0.user == nil && $0.hostName == "example.com" })
    }

    @Test func firstValueWins() {
        let hosts = SSHConfigParser.parse("Host a\n User one\n User two")
        #expect(hosts[0].user == "one")
    }

    @Test func readsRelayaMeta() {
        let hosts = SSHConfigParser.parse("""
        # relaya: group=prod env=prod
        Host db-main
            HostName db.internal
        Host plain
        """)
        #expect(hosts[0].group == "prod")
        #expect(hosts[0].environment == .prod)
        #expect(hosts[1].group == nil)
    }
}
