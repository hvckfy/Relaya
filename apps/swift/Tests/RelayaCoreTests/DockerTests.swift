import Testing
@testable import RelayaCore

@Suite struct DockerTests {
    @Test func parsesContainers() throws {
        let out = """
        {"Command":"\\"/docker-entrypoint.…\\"","ID":"a1","Image":"nginx:1.27","Names":"web","Ports":"0.0.0.0:80->80/tcp","State":"running","Status":"Up 2 hours"}
        {"ID":"b2","Image":"postgres:16","Names":"db","Ports":"","State":"exited","Status":"Exited (0) 3 days ago"}
        {"ID":"c3","Image":"redis","Names":"cache","Ports":"6379/tcp","State":"running","Status":"Up 5 minutes"}
        """
        guard case .containers(let list) = Docker.parse(stdout: out, stderr: "", status: 0) else {
            Issue.record("expected containers"); return
        }
        #expect(list.map(\.name) == ["cache", "web", "db"])
        #expect(list[1].ports == "0.0.0.0:80->80/tcp")
        #expect(!list[2].isRunning)
    }

    @Test func notInstalledAndPermission() {
        #expect(Docker.parse(stdout: "RELAYA_NO_DOCKER\n", stderr: "", status: 0) == .notInstalled)
        #expect(Docker.parse(stdout: "", stderr: "permission denied while trying to connect to the Docker daemon socket", status: 1)
                == .permissionDenied)
        #expect(Docker.parse(stdout: "", stderr: "", status: 0) == .containers([]))
    }

    @Test func quotesNames() {
        let c = DockerContainer(id: "x", name: "it's", image: "", state: "running", status: "", ports: "")
        #expect(Docker.actionCommand("restart", container: c) == #"docker restart 'it'\''s'"#)
    }
}
