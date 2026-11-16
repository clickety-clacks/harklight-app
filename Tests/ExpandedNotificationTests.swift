import UIKit
import UserNotifications
import XCTest
@testable import Harklight

@MainActor
final class ExpandedNotificationTests: XCTestCase {
    func testPinnedServerBatchRendersOrderedDuplicateWholeTitles() throws {
        let payload = try fixture("expanded-notification-batch-v1")
        let presentation = try delivered(payload)
        let titles = ["Same title", "Same title", "Quote \"slash\\\n雪 👩‍👩‍👧‍👦"]
        XCTAssertEqual(presentation.batch?.titles, titles)
        XCTAssertEqual(presentation.batch?.remainingCount, 0)
        XCTAssertEqual(render(presentation), ["3 new requests"] + titles)
    }

    func testPinnedServerSingleUsesFinalDeliveredPreviewOnly() throws {
        let presentation = try delivered(fixture("expanded-notification-chat-v1"))
        XCTAssertNil(presentation.batch)
        XCTAssertEqual(render(presentation), ["Sender", "Final fitted…"])
    }

    func testPartialBatchShowsHonestRemainingCount() {
        let presentation = batch(titles: ["First", "Second"], total: 5)
        XCTAssertEqual(render(presentation), ["Batch", "First", "Second", "3 more messages"])
    }

    func testCountOnlyBatchDoesNotInventMessageTitles() {
        XCTAssertEqual(render(batch(titles: [], total: 3)), ["Batch", "3 messages"])
        XCTAssertEqual(render(batch(titles: [], total: 0)), ["Batch", "0 messages"])
    }

    func testSingularCountsUseSingularLabels() {
        XCTAssertEqual(render(batch(titles: [], total: 1)), ["Batch", "1 message"])
        XCTAssertEqual(render(batch(titles: ["First"], total: 2)), ["Batch", "First", "1 more message"])
    }

    func testMalformedBatchFallsBackToDeliveredAlertWithoutPartialTitles() {
        let invalid: [[String: Any]] = [
            ["v": 2, "titles": ["Unavailable"], "total_count": 1],
            ["v": true, "titles": ["Unavailable"], "total_count": 1],
            ["v": 1, "titles": ["Unavailable", 7], "total_count": 2],
            ["v": 1, "titles": ["Unavailable"], "total_count": 0],
            ["v": 1, "titles": [], "total_count": -1],
            ["v": 1, "titles": [], "total_count": true],
            ["v": 1, "titles": [], "total_count": 1.5],
            ["v": 1, "titles": [], "total_count": "3"],
            ["v": 1, "titles": [], "total_count": UInt64.max],
            ["titles": [], "total_count": 1],
            ["v": 1, "total_count": 1],
            ["v": 1, "titles": []]
        ]
        for expanded in invalid {
            let presentation = make(category: ExpandedNotificationPresentation.batchCategory,
                                    info: ["attention": ["expanded": expanded]])
            XCTAssertNil(presentation.batch, "Invalid metadata must not masquerade as a complete batch")
            XCTAssertEqual(render(presentation), ["Delivered title", "Delivered subtitle", "Delivered body"])
        }
    }

    func testMissingNullAndWrongShapeMetadataUseDeliveredFallback() {
        let payloads: [[AnyHashable: Any]] = [
            [:], ["attention": NSNull()], ["attention": ["expanded": NSNull()]],
            ["attention": ["expanded": "unavailable"]]
        ]
        for payload in payloads {
            XCTAssertEqual(render(make(category: ExpandedNotificationPresentation.batchCategory, info: payload)),
                           ["Delivered title", "Delivered subtitle", "Delivered body"])
        }
    }

    func testLegacyUnknownAndSingleCategoriesNeverConsumeBatchMetadata() {
        for category in ["", "future.category", ExpandedNotificationPresentation.singleCategory] {
            let presentation = make(category: category, info: [
                "attention": ["expanded": ["v": 1, "titles": ["Not a single preview"], "total_count": 1]]
            ])
            XCTAssertNil(presentation.batch)
            XCTAssertEqual(render(presentation), ["Delivered title", "Delivered subtitle", "Delivered body"])
        }
    }

    func testEmptyDeliveredFallbackDoesNotFabricateAProfileOrPreview() {
        let presentation = ExpandedNotificationPresentation(category: "", title: "", subtitle: "", body: "", userInfo: [:])
        XCTAssertEqual(render(presentation), ["Open Harklight to view this notification."])
    }

    func testEveryDeliveredTitleIsRetainedWithoutClientCapOrReordering() {
        let titles = (0..<100).map { "Title \($0)" } + ["", "Title 0"]
        XCTAssertEqual(render(batch(titles: titles, total: titles.count)), ["Batch"] + titles)
    }

    func testNextNotificationReplacesPriorContentRatherThanRetainingIt() {
        let view = ExpandedNotificationView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.display(batch(titles: ["Old title"], total: 1))
        view.display(make(category: ExpandedNotificationPresentation.singleCategory))
        XCTAssertEqual(labels(in: view).map(\.text), ["Delivered title", "Delivered subtitle", "Delivered body"])
    }

    func testRendererWrapsWholeTitlesAndSupportsDynamicTypeWithoutActions() {
        let view = ExpandedNotificationView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.display(batch(titles: [String(repeating: "Whole title ", count: 50)], total: 1))
        XCTAssertFalse(view.isUserInteractionEnabled)
        XCTAssertTrue(labels(in: view).allSatisfy { $0.numberOfLines == 0 && $0.adjustsFontForContentSizeCategory })
        let measured = view.systemLayoutSizeFitting(CGSize(width: 320, height: 0),
                                                  withHorizontalFittingPriority: .required,
                                                  verticalFittingPriority: .fittingSizeLevel)
        XCTAssertGreaterThan(measured.height, 100, "Long content must expand instead of being capped to one line")
    }

    func testCategoriesHaveNoActionsOrHiddenPreviewDisclosureOverrides() {
        let categories = ExpandedNotificationPresentation.categories()
        XCTAssertEqual(Set(categories.map(\.identifier)), ["harklight.expanded.single.v1", "harklight.expanded.batch.v1"])
        for category in categories {
            XCTAssertTrue(category.actions.isEmpty)
            XCTAssertFalse(category.options.contains(.hiddenPreviewsShowTitle))
            XCTAssertFalse(category.options.contains(.hiddenPreviewsShowSubtitle))
            XCTAssertTrue(category.intentIdentifiers.isEmpty)
        }
    }

    func testEmbeddedExtensionSelectsBothCategoriesAndRemainsPassive() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let bundle = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("HarklightNotificationContent.appex")))
        let entry = try XCTUnwrap(bundle.infoDictionary?["NSExtension"] as? [String: Any])
        XCTAssertEqual(entry["NSExtensionPointIdentifier"] as? String, "com.apple.usernotifications.content-extension")
        XCTAssertEqual(entry["NSExtensionMainStoryboard"] as? String, "NotificationView")
        let attributes = try XCTUnwrap(entry["NSExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(attributes["UNNotificationExtensionCategory"] as? [String])),
                       Set(ExpandedNotificationPresentation.categories().map(\.identifier)))
        XCTAssertEqual(attributes["UNNotificationExtensionUserInteractionEnabled"] as? Bool, false)
        XCTAssertNil(attributes["UNNotificationExtensionOverridesDefaultTitle"])
        XCTAssertNotNil(bundle.url(forResource: "NotificationView", withExtension: "storyboardc"))
    }

    private func make(category: String, info: [AnyHashable: Any] = [:]) -> ExpandedNotificationPresentation {
        ExpandedNotificationPresentation(category: category, title: "Delivered title", subtitle: "Delivered subtitle",
                                         body: "Delivered body", userInfo: info)
    }

    private func batch(titles: [String], total: Int) -> ExpandedNotificationPresentation {
        ExpandedNotificationPresentation(category: ExpandedNotificationPresentation.batchCategory,
                                         title: "Batch", subtitle: "", body: "Delivered summary",
                                         userInfo: ["attention": ["expanded": ["v": 1, "titles": titles, "total_count": total]]])
    }

    private func render(_ presentation: ExpandedNotificationPresentation) -> [String] {
        let view = ExpandedNotificationView(frame: .zero)
        view.display(presentation)
        return labels(in: view).map { $0.text ?? "" }
    }

    private func labels(in view: UIView) -> [UILabel] {
        if let label = view as? UILabel { return [label] }
        return view.subviews.flatMap { labels(in: $0) }
    }

    private func fixture(_ name: String) throws -> [AnyHashable: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [AnyHashable: Any])
    }

    private func delivered(_ payload: [AnyHashable: Any]) throws -> ExpandedNotificationPresentation {
        let aps = try XCTUnwrap(payload["aps"] as? [String: Any])
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
        return ExpandedNotificationPresentation(category: try XCTUnwrap(aps["category"] as? String),
                                                title: alert["title"] as? String ?? "",
                                                subtitle: alert["subtitle"] as? String ?? "",
                                                body: alert["body"] as? String ?? "", userInfo: payload)
    }
}
