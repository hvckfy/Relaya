import Foundation
import Testing
@testable import RelayaCore

struct SyncTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "relaya-sync-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func paths(_ dir: URL) -> Sync.Paths { Sync.Paths(ssh: dir, support: dir) }

    let config = """
    # relaya: group=work
    Host web
        HostName 10.0.0.1

    # relaya: group=home
    Host nas
        HostName 192.168.1.5

    Host github.com
        User git
    """

    @Test func keyVaultRoundTripAndWrongPassword() throws {
        let data = Data("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n".utf8)
        let blob = try KeyVault.encrypt(data, passphrase: "correct horse", rounds: 1000)
        #expect(try KeyVault.decrypt(blob, passphrase: "correct horse") == data)
        #expect(throws: KeyVault.Failure.self) { try KeyVault.decrypt(blob, passphrase: "wrong") }
    }

    @Test func extractAndMergeConfigBlocks() {
        let work = SyncConfig.extract(config, aliases: ["web"])
        #expect(work.contains("Host web") && !work.contains("Host nas"))
        #expect(work.contains("# relaya: group=work"))
        let local = "Host nas\n    HostName old\n\nHost web\n    HostName 1.1.1.1\n"
        let merged = SyncConfig.merge(local: local, incoming: work)
        #expect(merged.contains("HostName 10.0.0.1") && !merged.contains("1.1.1.1"))
        #expect(merged.contains("HostName old"))
        let added = SyncConfig.merge(local: "Host x\n    HostName x\n", incoming: work)
        #expect(added.contains("Host x") && added.contains("Host web"))
    }

    @Test func profileScopeByGroupAndMergedImport() throws {
        let a = tempDir(), repo = tempDir(), b = tempDir()
        try Data(config.utf8).write(to: a.appending(path: "config"))
        let tunnels = [Tunnel(name: "w", hostAlias: "web", listenPort: 1, targetHost: "x", targetPort: 2),
                       Tunnel(name: "n", hostAlias: "nas", listenPort: 3, targetHost: "y", targetPort: 4)]
        try JSONEncoder().encode(tunnels).write(to: a.appending(path: "tunnels.json"))
        var p = Sync.Profile(name: "work")
        p.scope = Sync.Scope(allHosts: false, groups: ["work"])
        try Sync.export(p, paths: paths(a), to: repo)
        let exported = try String(contentsOf: repo.appending(path: "ssh/config"), encoding: .utf8)
        #expect(exported.contains("Host web") && !exported.contains("nas") && !exported.contains("github"))
        let t: [Tunnel] = Sync.load(repo.appending(path: "relaya/tunnels.json"))!
        #expect(t.map(\.name) == ["w"])

        try Data("Host mine\n    HostName m\n".utf8).write(to: b.appending(path: "config"))
        let changed = try Sync.import(p, paths: paths(b), from: repo)
        #expect(changed.contains(.sshConfig) && changed.contains(.tunnels))
        let merged = try String(contentsOf: b.appending(path: "config"), encoding: .utf8)
        #expect(merged.contains("Host mine") && merged.contains("Host web"))
        #expect(FileManager.default.fileExists(atPath: b.appending(path: "config.bak").path))
        #expect(try Sync.import(p, paths: paths(b), from: repo).isEmpty)
    }

    @Test func keysOnlyForProfileHosts() throws {
        let ssh = tempDir(), repo = tempDir(), other = tempDir()
        try Data("PRIVATE".utf8).write(to: ssh.appending(path: "id_web"))
        try Data("ssh-ed25519 AAAA web".utf8).write(to: ssh.appending(path: "id_web.pub"))
        try Data("OTHER".utf8).write(to: ssh.appending(path: "id_other"))
        try Data("ssh-ed25519 AAAA other".utf8).write(to: ssh.appending(path: "id_other.pub"))
        try Data("Host web\n    IdentityFile \(ssh.appending(path: "id_web").path)\n".utf8).write(to: ssh.appending(path: "config"))
        var p = Sync.Profile(name: "all")
        p.items = [.sshConfig, .keys]
        try Sync.export(p, paths: paths(ssh), passphrase: "pw", to: repo)
        #expect(FileManager.default.fileExists(atPath: repo.appending(path: "keys/id_web.relaya-key").path))
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "keys/id_other.relaya-key").path))
        let blob = try Data(contentsOf: repo.appending(path: "keys/id_web.relaya-key"))
        #expect(!String(decoding: blob, as: UTF8.self).contains("PRIVATE"))
        #expect(try Sync.importKeys(ssh: other, passphrase: "pw", from: repo) == ["id_web"])
    }

    @Test func gitTwoMachinesSyncAndConflict() async throws {
        let bare = tempDir()
        _ = try await ProcessRunner.run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", bare.path])
        let localA = tempDir(), localB = tempDir()
        let a = GitSync(repo: tempDir().appending(path: "repo"), remote: bare.path)
        let b = GitSync(repo: tempDir().appending(path: "repo"), remote: bare.path)
        let p = Sync.Profile(name: "all")
        let pa = paths(localA), pb = paths(localB)

        try Data("Host a\n    HostName 1\n".utf8).write(to: localA.appending(path: "config"))
        #expect(try await a.sync(machine: "A", profile: p, paths: pa) == .synced(pulled: false, imported: []))

        // Пустой Mac не обнуляет общий файл и получает хосты.
        _ = try await b.sync(machine: "B", profile: p, paths: pb)
        #expect(try String(contentsOf: b.repo.appending(path: "ssh/config"), encoding: .utf8).contains("Host a"))
        try Sync.import(p, paths: pb, from: b.repo)
        #expect(try String(contentsOf: localB.appending(path: "config"), encoding: .utf8).contains("Host a"))

        try Data("Host a\n    HostName from-A\n".utf8).write(to: localA.appending(path: "config"))
        _ = try await a.sync(machine: "A", profile: p, paths: pa)
        try Data("Host a\n    HostName from-B\n".utf8).write(to: localB.appending(path: "config"))
        let outcome = try await b.sync(machine: "B", profile: p, paths: pb)
        guard case .conflict(let c) = outcome else { Issue.record("expected conflict, got \(outcome)"); return }
        #expect(c.map(\.path) == ["ssh/config"])
        #expect(c[0].mine.contains("from-B") && c[0].theirs.contains("from-A"))

        _ = try await b.resolve(["ssh/config": false], profile: p, paths: pb)
        #expect(try String(contentsOf: localB.appending(path: "config"), encoding: .utf8).contains("from-A"))
        #expect(try await b.sync(machine: "B", profile: p, paths: pb) == .upToDate)
    }
}
