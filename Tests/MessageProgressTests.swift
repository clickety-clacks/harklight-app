import XCTest
import AttentionDomain

final class MessageProgressTests: XCTestCase {
    private func message(_ member: String, type: String = "fyi") throws -> JSONValue {
        try JSONValue.parse(Data(("{\"message_type\":\"" + type + "\",\"progress\":" + member + "}").utf8))
    }

    func testMarkerIncludesNullAndMalformedButNotRequestsOrOrdinaryFYI() throws {
        XCTAssertEqual(MessageProgress.read(from: try message("null")), .unavailable)
        XCTAssertEqual(MessageProgress.read(from: try message("\"bad\"")), .unavailable)
        XCTAssertNil(MessageProgress.read(from: try message("null", type: "request")))
        XCTAssertNil(MessageProgress.read(from: try JSONValue.parse(Data(#"{"message_type":"fyi"}"#.utf8))))
    }

    func testLoweredWidthsPreserveOriginalVisitMetadataAndZeroWidthLegend() throws {
        let raw = #"""
        {"updated_at":"2026-11-09T10:00:00.000Z","percent":45,"stage":"testing","note":" correction ",
         "segments":[
          {"stage":"spec_writing","width":10,"note":"scope","visit_at":"2026-11-09T09:00:00Z","reported_percent":10,"delta":10},
          {"stage":"coding","width":30,"note":null,"reported_percent":40,"delta":30},
          {"stage":"review","width":0,"note":"review"},
          {"stage":"coding","width":5,"note":"built","reported_percent":60,"delta":20},
          {"stage":"testing","width":0,"note":" correction ","reported_percent":45,"delta":-15}]}
        """#
        let snapshot = try XCTUnwrap(MessageProgress.read(from: message(raw))?.snapshot)
        XCTAssertEqual(snapshot.percent, 45)
        XCTAssertEqual(snapshot.legend, ["spec_writing", "coding", "review", "testing"])
        XCTAssertEqual(snapshot.visits.map(\.width), [10, 30, 0, 5, 0])
        XCTAssertEqual(snapshot.visits[3].reportedPercent, 60)
        XCTAssertEqual(snapshot.visits[4].delta, -15)
        XCTAssertEqual(snapshot.visits[4].note, " correction ")
        XCTAssertNil(snapshot.visits[2].reportedPercent)
        XCTAssertNil(snapshot.visits[2].delta)
        XCTAssertNil(snapshot.visits[2].visitAt)
        XCTAssertNotNil(snapshot.visits[0].visitAt)
        XCTAssertNotNil(snapshot.updatedAt)
    }

    func testInvalidBarDoesNotInventHistory() throws {
        for raw in [
            #"{"percent":101,"stage":"coding","segments":[]}"#,
            #"{"percent":20,"stage":"coding","segments":[{"stage":"coding","width":19}]}"#,
            #"{"percent":0,"stage":"coding","segments":[{"stage":"coding","width":-1}]}"#,
            #"{"percent":0,"stage":"","segments":[]}"#,
            #"{"percent":0,"stage":"coding","segments":[null]}"#
        ] {
            XCTAssertEqual(MessageProgress.read(from: try message(raw)), .unavailable)
        }
    }

    func testCompleteRemainsProgressAndMissingAnnotationsStayAbsent() throws {
        let raw = #"{"percent":100,"stage":"packaging","segments":[{"stage":"packaging","width":100,"visit_at":"bad","reported_percent":"100","delta":null}]}"#
        let snapshot = try XCTUnwrap(MessageProgress.read(from: message(raw))?.snapshot)
        XCTAssertEqual(snapshot.percent, 100)
        XCTAssertEqual(snapshot.legend, ["packaging"])
        XCTAssertNil(snapshot.updatedAt)
        XCTAssertNil(snapshot.visits[0].visitAt)
        XCTAssertNil(snapshot.visits[0].reportedPercent)
        XCTAssertNil(snapshot.visits[0].delta)
    }
}
