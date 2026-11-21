import AttentionDomain
import SwiftUI
import UIKit

struct PreviousDeviceUnsentTextView: View {
    var title = "Unsent from your previous device"
    var explanation: String? = nil
    let load: @MainActor () throws -> [ExactText]
    @State private var text: [ExactText] = []
    @State private var loadFailed = false

    var body: some View {
        List {
            if let explanation { Text(explanation).foregroundStyle(.secondary) }
            if loadFailed {
                Text("The saved text could not be opened.")
            } else if text.isEmpty {
                Text("There is no unsent text on this device.")
            }
            ForEach(Array(text.enumerated()), id: \.offset) { _, value in
                VStack(alignment: .leading, spacing: 8) {
                    Text(value.rawValue).textSelection(.enabled)
                    Button("Copy") { UIPasteboard.general.string = value.rawValue }
                }
            }
        }
        .navigationTitle(title)
        .task {
            do { text = try load() }
            catch { loadFailed = true }
        }
    }
}
