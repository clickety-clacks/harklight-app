import UIKit
import UserNotifications
import UserNotificationsUI

@MainActor
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let notificationView = ExpandedNotificationView(frame: .zero)

    override func loadView() {
        view = notificationView
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        loadViewIfNeeded()
        notificationView.display(ExpandedNotificationPresentation(
            category: content.categoryIdentifier, title: content.title,
            subtitle: content.subtitle, body: content.body, userInfo: content.userInfo))
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0 else { return }
        let size = notificationView.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if preferredContentSize != size { preferredContentSize = size }
    }
}
