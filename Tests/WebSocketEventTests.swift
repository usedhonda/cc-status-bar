import XCTest
@testable import CCStatusBarLib

final class WebSocketEventTests: XCTestCase {

    // MARK: - Helper

    private func parseJSON(_ jsonString: String) -> [String: Any]? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - toJSON

    func testToJSONSessionsList() {
        let sessions: [[String: Any]] = [
            ["id": "s1", "status": "running"],
            ["id": "s2", "status": "waiting_input"]
        ]
        let event = WebSocketEvent(type: .sessionsList, sessions: sessions)
        let json = parseJSON(event.toJSON())

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["type"] as? String, "sessions.list")
        let parsedSessions = json?["sessions"] as? [[String: Any]]
        XCTAssertEqual(parsedSessions?.count, 2)
        XCTAssertEqual(parsedSessions?[0]["id"] as? String, "s1")
    }

    func testToJSONSessionAdded() {
        let session: [String: Any] = ["id": "s1", "project": "test-project", "status": "running"]
        let event = WebSocketEvent(type: .sessionAdded, session: session)
        let json = parseJSON(event.toJSON())

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["type"] as? String, "session.added")
        let parsedSession = json?["session"] as? [String: Any]
        XCTAssertEqual(parsedSession?["project"] as? String, "test-project")
    }

    func testToJSONSessionRemoved() {
        let event = WebSocketEvent(type: .sessionRemoved, sessionId: "s1:ttys001")
        let json = parseJSON(event.toJSON())

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["type"] as? String, "session.removed")
        XCTAssertEqual(json?["session_id"] as? String, "s1:ttys001")
        // Should not have sessions or session fields
        XCTAssertNil(json?["sessions"])
        XCTAssertNil(json?["session"])
    }

    func testToJSONWithIcons() {
        let icons = ["ghostty": "base64data==", "iTerm2": "otherbase64=="]
        let event = WebSocketEvent(type: .sessionsList, sessions: [], icons: icons)
        let json = parseJSON(event.toJSON())

        XCTAssertNotNil(json)
        let parsedIcons = json?["icons"] as? [String: String]
        XCTAssertEqual(parsedIcons?["ghostty"], "base64data==")
        XCTAssertEqual(parsedIcons?["iTerm2"], "otherbase64==")
    }

    func testToJSONMinimal() {
        let event = WebSocketEvent(type: .hostInfo)
        let json = parseJSON(event.toJSON())

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["type"] as? String, "host_info")
        // Only "type" key should exist (no nil fields serialized)
        XCTAssertNil(json?["sessions"])
        XCTAssertNil(json?["session"])
        XCTAssertNil(json?["session_id"])
        XCTAssertNil(json?["icons"])
    }

    func testToJSONSessionUpdated() {
        let session: [String: Any] = ["id": "s1", "status": "waiting_input"]
        let event = WebSocketEvent(type: .sessionUpdated, session: session)
        let json = parseJSON(event.toJSON())

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["type"] as? String, "session.updated")
        let parsedSession = json?["session"] as? [String: Any]
        XCTAssertEqual(parsedSession?["status"] as? String, "waiting_input")
    }

    func testToJSONWithIcon() {
        let session: [String: Any] = ["id": "s1"]
        let event = WebSocketEvent(type: .sessionAdded, session: session, icon: "iconbase64==")
        let json = parseJSON(event.toJSON())

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["icon"] as? String, "iconbase64==")
    }

    // MARK: - WebSocketEventType

    func testEventTypeRawValues() {
        XCTAssertEqual(WebSocketEventType.sessionsList.rawValue, "sessions.list")
        XCTAssertEqual(WebSocketEventType.sessionAdded.rawValue, "session.added")
        XCTAssertEqual(WebSocketEventType.sessionUpdated.rawValue, "session.updated")
        XCTAssertEqual(WebSocketEventType.sessionRemoved.rawValue, "session.removed")
        XCTAssertEqual(WebSocketEventType.hostInfo.rawValue, "host_info")
    }
}
