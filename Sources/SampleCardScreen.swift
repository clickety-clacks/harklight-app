import SwiftUI
import AttentionDomain

/// Shake data enters the same admitted-message detail renderer as relay data.
/// The store is fixture-only, so its answer and Seen controls remain local.
@MainActor
struct SampleCardScreen: View {
    let response: SampleResponse
    let context: InboxCardContext

    var body: some View {
        if let request = response.viewModel.request(for: response.key) {
            LiveRequestDetail(request: request,
                              store: response.viewModel,
                              context: context,
                              localExample: response)
        } else {
            ContentUnavailableView("Example unavailable", systemImage: "questionmark.folder")
        }
    }
}
