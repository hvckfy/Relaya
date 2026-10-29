import Testing
@testable import RelayaCore

@Suite struct TerminalHighlighterTests {
    let red = HighlightRule(name: "err", pattern: "error", isRegex: false, color: 1)

    @Test func wrapsMatches() {
        var h = TerminalHighlighter(rules: [red])
        #expect(h.process("an Error here") == "an \u{1B}[31mError\u{1B}[39m here")
    }

    @Test func leavesEscapeSequencesAlone() {
        var h = TerminalHighlighter(rules: [HighlightRule(name: "m", pattern: "m", isRegex: false, color: 2)])
        // «m» внутри ESC[0m не должна подсветиться.
        #expect(h.process("\u{1B}[0mx") == "\u{1B}[0mx")
    }

    @Test func skipsRemoteColoredText() {
        var h = TerminalHighlighter(rules: [red])
        #expect(h.process("\u{1B}[32merror\u{1B}[0m error") == "\u{1B}[32merror\u{1B}[0m \u{1B}[31merror\u{1B}[39m")
    }

    @Test func offInAlternateScreen() {
        var h = TerminalHighlighter(rules: [red])
        #expect(h.process("\u{1B}[?1049herror") == "\u{1B}[?1049herror")
        #expect(h.process("\u{1B}[?1049lerror") == "\u{1B}[?1049l\u{1B}[31merror\u{1B}[39m")
    }

    @Test func carriesSplitEscape() {
        var h = TerminalHighlighter(rules: [red])
        #expect(h.process("a\u{1B}[3") == "a")
        #expect(h.process("2merror") == "\u{1B}[32merror")
    }

    @Test func defaultsCompileAndMatchIP() {
        var h = TerminalHighlighter(rules: HighlightRule.defaults)
        #expect(h.isActive)
        #expect(h.process("host 192.168.2.1 up").contains("\u{1B}[96m192.168.2.1"))
    }

    @Test func invalidRegexIsSkipped() {
        let bad = HighlightRule(name: "bad", pattern: "([", color: 1)
        #expect(!TerminalHighlighter(rules: [bad]).isActive)
    }
}
