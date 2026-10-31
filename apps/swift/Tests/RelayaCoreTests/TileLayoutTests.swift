import Foundation
import Testing
@testable import RelayaCore

struct TileLayoutTests {
    typealias T = TileLayout<Int>

    @Test func automaticThreeSpansBottom() {
        #expect(T.automatic([1, 2, 3]) == .column([.row([.leaf(1), .leaf(2)]), .leaf(3)]))
        #expect(T.automatic([1, 2, 3, 4]) == .column([.row([.leaf(1), .leaf(2)]), .row([.leaf(3), .leaf(4)])]))
        #expect(T.automatic([1, 2]) == .row([.leaf(1), .leaf(2)]))
    }

    @Test func insertAtEdgeOfTile() {
        let l = T.row([.leaf(1), .leaf(2)])
        #expect(l.inserting(3, at: .bottom, of: 2) == .row([.leaf(1), .column([.leaf(2), .leaf(3)])]))
        #expect(l.inserting(3, at: .left, of: 2) == .row([.leaf(1), .leaf(3), .leaf(2)]))
    }

    @Test func insertAtRootEdgeSpans() {
        let l = T.row([.leaf(1), .leaf(2)])
        #expect(l.inserting(3, at: .bottom, of: nil) == .column([.row([.leaf(1), .leaf(2)]), .leaf(3)]))
    }

    @Test func moveExistingTileAndCollapse() {
        let l = T.column([.row([.leaf(1), .leaf(2)]), .leaf(3)])
        #expect(l.inserting(1, at: .right, of: 3) == .column([.leaf(2), .row([.leaf(3), .leaf(1)])]))
        #expect(l.removing(3) == .row([.leaf(1), .leaf(2)]))
    }

    @Test func syncRemovesAndAppends() {
        let l = T.row([.leaf(1), .leaf(2)])
        #expect(l.synced(with: [2, 5]) == .row([.leaf(2), .leaf(5)]))
        #expect(l.swapping(1, 2) == .row([.leaf(2), .leaf(1)]))
    }
}

struct TileLayoutNavigationTests {
    typealias T = TileLayout<Int>

    @Test func neighborsInThreeTiles() {
        let l = T.column([.row([.leaf(1), .leaf(2)]), .leaf(3)])
        #expect(l.neighbor(of: 1, toward: .right) == 2)
        #expect(l.neighbor(of: 2, toward: .left) == 1)
        #expect(l.neighbor(of: 1, toward: .bottom) == 3)
        #expect(l.neighbor(of: 3, toward: .top) != nil)
        #expect(l.neighbor(of: 3, toward: .bottom) == nil)
    }

    @Test func mapAndCodableRoundTrip() throws {
        let l = T.row([.leaf(1), .column([.leaf(2), .leaf(3)])])
        let s = l.map { "h\($0)" }
        #expect(s == .row([.leaf("h1"), .column([.leaf("h2"), .leaf("h3")])]))
        #expect(l.map { $0 == 2 ? nil : $0 } == .row([.leaf(1), .leaf(3)]))
        let data = try JSONEncoder().encode(s!)
        #expect(try JSONDecoder().decode(TileLayout<String>.self, from: data) == s)
    }
}
