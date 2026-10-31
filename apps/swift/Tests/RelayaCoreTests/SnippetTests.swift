import Testing
@testable import RelayaCore

@Suite struct SnippetTests {
    @Test func extractsVariablesOnce() {
        let s = Snippet(name: "x", command: "cp {{src}} {{ dst }} && ls {{src}}")
        #expect(s.variables == ["src", "dst"])
        #expect(s.filled(["src": "a b", "dst": "$HOME/c"]) == "cp a b $HOME/c && ls a b")
    }

    @Test func goTemplatesAreNotVariables() {
        // {{.Names}} из docker --format — не переменная.
        let s = Snippet(name: "d", command: "docker ps --format '{{.Names}}' {{name}}")
        #expect(s.variables == ["name"])
    }

    @Test func unfilledStays() {
        let s = Snippet(name: "x", command: "echo {{a}} {{b}}")
        #expect(s.filled(["a": "1"]) == "echo 1 {{b}}")
    }
}
