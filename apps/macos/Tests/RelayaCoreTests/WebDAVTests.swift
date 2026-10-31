import Foundation
import Testing
@testable import RelayaCore

struct WebDAVTests {
    @Test func parsesContentLengthAndPipelined() {
        var p = WebDAV.Parser()
        let raw = "PUT /t/web/a%20b.txt HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhelloPROPFIND /t/web/ HTTP/1.1\r\nDepth: 0\r\n\r\n"
        var reqs = p.feed(Data(raw.prefix(40).utf8))
        reqs += p.feed(Data(raw.dropFirst(40).utf8))
        #expect(reqs.count == 2)
        #expect(reqs[0].method == "PUT" && reqs[0].path == "/t/web/a b.txt" && reqs[0].body == Data("hello".utf8))
        #expect(reqs[1].method == "PROPFIND" && reqs[1].depth == 0)
    }

    @Test func parsesChunked() {
        var p = WebDAV.Parser()
        let raw = "PUT /f HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        let r = p.feed(Data(raw.utf8))
        #expect(r.count == 1 && r[0].body == Data("hello world".utf8))
        #expect(p.feed(Data("PUT /g HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab".utf8)).isEmpty)
    }

    @Test func multistatusAndHelpers() {
        let xml = String(decoding: WebDAV.multistatus([
            .init(href: "/t/web/", name: "web", isDirectory: true, size: 0, modified: Date(timeIntervalSince1970: 0)),
            .init(href: "/t/web/a & b.txt", name: "a & b.txt", isDirectory: false, size: 12, modified: Date(timeIntervalSince1970: 0)),
        ]), as: UTF8.self)
        #expect(xml.contains("<D:collection/>"))
        #expect(xml.contains("<D:getcontentlength>12</D:getcontentlength>"))
        #expect(xml.contains("a%20&amp;%20b.txt") || xml.contains("a%20%26%20b.txt"))
        #expect(xml.contains("Thu, 01 Jan 1970 00:00:00 GMT"))
        #expect(WebDAV.destinationPath("http://127.0.0.1:5000/t/web/new%20name") == "/t/web/new name")
        #expect(WebDAV.isFinderJunk("._photo.jpg") && WebDAV.isFinderJunk(".DS_Store") && !WebDAV.isFinderJunk("notes.txt"))
    }

    @Test func listingDates() {
        let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
        let d = WebDAV.date(fromListing: "Oct 29 12:00", now: now)
        #expect(Calendar(identifier: .gregorian).component(.year, from: d) == 2026)
        let old = WebDAV.date(fromListing: "Mar 3  2024", now: now)
        #expect(Calendar(identifier: .gregorian).component(.year, from: old) == 2024)
    }
}
