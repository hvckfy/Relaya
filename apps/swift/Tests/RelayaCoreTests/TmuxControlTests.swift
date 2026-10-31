import Testing
@testable import RelayaCore

struct TmuxControlTests {
    @Test func unescapesOctalAndBackslash() {
        let s = Array("a\\033[1mb\\\\c\\015\\012".utf8)
        #expect(TmuxControl.unescape(s) == [97, 27, 91, 49, 109, 98, 92, 99, 13, 10])
    }

    @Test func parsesEventsAcrossChunks() {
        var p = TmuxControl.Parser()
        var events = p.feed(Array("\u{1B}P1000p%begin 1 2 0\n@1 %1 bash\n@2 %4 htop\n%end 1 2 0\n%out".utf8))
        events += p.feed(Array("put %1 hi\\015\\012\n%window-add @3\n%window-close @2\n%exit\n".utf8))
        #expect(events == [
            .reply(lines: ["@1 %1 bash", "@2 %4 htop"], error: false),
            .output(pane: "%1", data: Array("hi\r\n".utf8)),
            .windowAdd(window: "@3"),
            .windowClose(window: "@2"),
            .exit(reason: nil),
        ])
    }

    @Test func commands() {
        #expect(TmuxControl.sendKeys(pane: "%1", [0x6c, 0x73, 0x0d]) == "send-keys -t %1 -H 6c 73 0d")
        let w = TmuxControl.parseWindows(["@1 %1 bash", "junk", "@2 %4 my editor"])
        #expect(w.count == 2 && w[1].name == "my editor")
        #expect(TmuxControl.attachCommand(name: "relaya-a-1") == "tmux -CC attach-session -t relaya-a-1")
        let prep = Tmux.prepareControlCommand(name: "relaya-a-1", ttlMinutes: 60)
        #expect(prep.contains("window-size manual") && prep.contains("sleep 3600") && prep.contains("RELAYA_NO_TMUX"))
    }
}
