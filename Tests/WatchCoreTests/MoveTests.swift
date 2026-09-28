import XCTest
@testable import WatchCore

final class ConfigMoveTests: XCTestCase {
    func testOrgNamesDecodeAndDefault() throws {
        let json = #"{"orgNames": {"793c": "Hamagan Technologies"}}"#
        let cfg = try JSONCoder.decoder.decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.orgNames["793c"], "Hamagan Technologies")
        XCTAssertEqual(try JSONCoder.decoder.decode(Config.self, from: Data("{}".utf8)).orgNames, [:])
    }

    func testChatLocationId() {
        let l = ChatLocation(profileId: "claude-2-x", accountUuid: "acc", orgUuid: "org")
        XCTAssertEqual(l.id, "claude-2-x/acc/org")
    }
}
