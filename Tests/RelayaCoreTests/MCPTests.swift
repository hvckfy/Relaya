import Foundation
import Testing
@testable import RelayaCore

@Suite struct MCPPolicyTests {
    @Test(arguments: ["df -h", "cat /etc/os-release", "journalctl -u nginx -n 50 | grep error",
                      "docker ps", "systemctl status ssh", "ps aux | sort -rk3 | head"])
    func readOnlyAllowed(_ cmd: String) {
        #expect(MCPPolicy.isReadOnly(cmd))
    }

    @Test(arguments: ["rm -rf /tmp/x", "echo hi > /etc/motd", "cat a; reboot", "ls && shutdown now",
                      "sudo cat /etc/shadow", "sed -i s/a/b/ f", "find / -delete", "echo $(whoami)",
                      "systemctl restart nginx", "docker rm x", ""])
    func readOnlyDenied(_ cmd: String) {
        #expect(!MCPPolicy.isReadOnly(cmd))
    }

    @Test func modes() {
        let p = MCPPolicy(enabled: true, defaultMode: .readOnly, hosts: ["prod": .off])
        #expect(p.mode(for: "prod") == .off)
        #expect(p.mode(for: "dev") == .readOnly)
        #expect(MCPPolicy(enabled: false).mode(for: "dev") == .off)
    }
}

@Suite struct MCPServerTests {
    let hosts = [SSHHost(alias: "web", hostName: "1.2.3.4", user: "root", tags: ["prod"], os: .ubuntu),
                 SSHHost(alias: "secret")]

    func server(_ policy: MCPPolicy, confirm: Bool = false, ran: @escaping @Sendable (String) -> Void = { _ in }) -> MCPServer {
        MCPServer(hosts: { hosts }, policy: { policy }, log: nil,
                  execute: { _, cmd, _ in ran(cmd); return ProcessResult(status: 0, stdout: "ok", stderr: "") },
                  confirm: { _, _, _ in confirm })
    }

    func call(_ s: MCPServer, _ name: String, _ args: [String: Any]) async -> [String: Any] {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let line = String(data: try! JSONSerialization.data(withJSONObject: req), encoding: .utf8)!
        let resp = await s.handle(line)!
        let obj = try! JSONSerialization.jsonObject(with: Data(resp.utf8)) as! [String: Any]
        return obj["result"] as! [String: Any]
    }

    func text(_ result: [String: Any]) -> String {
        ((result["content"] as! [[String: Any]])[0]["text"] as! String)
    }

    @Test func initializeAndList() async {
        let s = server(MCPPolicy())
        let r = await s.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"Claude"}}}"#)!
        #expect(r.contains("\"name\":\"relaya\""))
        #expect(await s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let tools = await s.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        #expect(tools.contains("run_command") && tools.contains("read_file") && tools.contains("list_hosts"))
        let unknown = await s.handle(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)!
        #expect(unknown.contains("-32601"))
    }

    @Test func listHidesOffHosts() async {
        let s = server(MCPPolicy(defaultMode: .readOnly, hosts: ["secret": .off]))
        let t = text(await call(s, "list_hosts", [:]))
        #expect(t.contains("web") && !t.contains("secret"))
    }

    @Test func readOnlyBlocksWrites() async {
        let s = server(MCPPolicy(defaultMode: .readOnly))
        let denied = await call(s, "run_command", ["host": "web", "command": "rm -rf /"])
        #expect(denied["isError"] as? Bool == true)
        let ok = await call(s, "run_command", ["host": "web", "command": "df -h"])
        #expect(ok["isError"] as? Bool == false)
        #expect(text(ok).contains("ok"))
    }

    @Test func confirmRespectsDecision() async {
        let refused = await call(server(MCPPolicy(defaultMode: .confirm), confirm: false), "run_command",
                                 ["host": "web", "command": "reboot"])
        #expect(text(refused).contains("отклонил"))
        let approved = await call(server(MCPPolicy(defaultMode: .confirm), confirm: true), "run_command",
                                  ["host": "web", "command": "reboot"])
        #expect(approved["isError"] as? Bool == false)
    }

    @Test func disabledPolicy() async {
        let r = await call(server(MCPPolicy(enabled: false)), "list_hosts", [:])
        #expect(r["isError"] as? Bool == true)
    }

    @Test func readFileQuotesPath() async {
        let box = Box()
        let s = server(MCPPolicy(defaultMode: .trusted)) { box.value = $0 }
        _ = await call(s, "read_file", ["host": "web", "path": "/tmp/it's here"])
        #expect(box.value == #"head -c 65536 -- '/tmp/it'\''s here'"#)
    }
}

final class Box: @unchecked Sendable {
    var value = ""
}

struct MCPRulesTests {
    @Test func patternsAndGrants() {
        var p = MCPPolicy(defaultMode: .confirm)
        p.allow = ["web": ["systemctl restart *"], "*": ["docker restart *"]]
        p.deny = ["*": ["rm -rf *", "reboot*"]]
        #expect(p.isAllowed("systemctl restart nginx", on: "web"))
        #expect(!p.isAllowed("systemctl restart nginx", on: "db"))
        #expect(p.isAllowed("docker restart api", on: "db"))
        #expect(!p.isAllowed("systemctl restart nginx; rm -rf /", on: "web"))
        #expect(p.isDenied("rm -rf /var", on: "web"))
        #expect(p.isDenied("reboot now", on: "db"))
        let now = Date()
        p.grants = ["db": .init(mode: .trusted, until: now.addingTimeInterval(1800))]
        #expect(p.mode(for: "db", now: now) == .trusted)
        #expect(p.mode(for: "db", now: now.addingTimeInterval(3600)) == .confirm)
    }

    @Test func summariesGroupChangingCommands() {
        let s = UUID()
        var a = MCPLogEntry(client: "Claude", tool: "run_command", host: "web", detail: "systemctl restart nginx",
                            decision: "одобрено пользователем", exitCode: 0)
        a.session = s; a.changes = true
        var b = MCPLogEntry(client: "Claude", tool: "run_command", host: "web", detail: "ls", decision: "разрешено: чтение", exitCode: 0)
        b.session = s; b.changes = false
        let sum = MCPLog.summaries([a, b])
        #expect(sum.count == 1 && sum[0].changes.count == 1 && sum[0].hosts == ["web"])
    }
}
