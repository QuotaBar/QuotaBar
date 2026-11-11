import XCTest
@testable import QuotaCore
final class DeskOrientationTests: XCTestCase {
    func testLegacyCardRemainsHorizontal() throws {
        let card = try JSONDecoder().decode(DeskCard.self, from: Data(#"{"id":"old","style":"classic","size":"medium","x":0.2,"y":0.3}"#.utf8))
        XCTAssertFalse(card.vertical)
        XCTAssertEqual(card.id, "old")
        XCTAssertEqual(card.x, 0.2)
    }
    func testVerticalPersistsWithoutChangingIdentityOrPosition() throws {
        var card = DeskCard(id: "test", style: .classic, x: 0.2, y: 0.3)
        card.vertical = true
        let result = try JSONDecoder().decode(DeskCard.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(result, card)
    }
    func testInvalidOrientationKeepsOtherSettings() throws {
        let card = try JSONDecoder().decode(DeskCard.self, from: Data(#"{"id":"test","style":"classic","vertical":"future"}"#.utf8))
        XCTAssertFalse(card.vertical)
        XCTAssertEqual(card.style, .classic)
    }
}
