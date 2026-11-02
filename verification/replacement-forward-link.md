# Replacement forward-link verification

## Source and contract

- App source under test: `ccba554934f22592a6ed4bffc48d1d1cab5228ed`.
- The inspected public Server main was `e73057e67f8cf27a0b917b9fbd6e03c7487446eb`. Its accepted forward delivery already carries the replacement sender ID, message ID, and superseded message IDs to account devices. No Server change was needed.

## Focused run

- Command: `Scripts/verify.sh test`
- Selection: `HARKLIGHT_ONLY_TESTING=HarklightTests/SupersedesPresentationTests`
- Runtime: iOS 27.0 simulator, iPhone 17 Pro; Xcode 27.1.
- Result: exit 0, 9 tests executed, 0 failures.

The selected tests cover forward identity from accepted events and inbox pages, multiple replacements, a deferred replacement identity before its contents load, backward loading of older account state, and preservation of the existing reverse `Supersedes` link.

The wrapper regenerated the Xcode project in the isolated test checkout before building. That generated project file was not included in the source branch. Xcode emitted a non-fatal SDK-record warning (`invalidDigitCount(94232)`); the test command exited successfully.

## Limits

This focused run compiled the app and exercised the replacement relationship and presentation projection. It did not automate a tap through the rendered SwiftUI navigation link, exercise a live Server, or verify an installed build on account phones. The replacement destination uses the existing normal request-detail route when its content is present and shows an unavailable-yet message while retaining the original detail when it is not.
