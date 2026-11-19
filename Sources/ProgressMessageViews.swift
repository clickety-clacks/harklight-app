import AttentionDomain
import SwiftUI

private enum ProgressStageStyle {
    static func label(_ stage: String) -> String {
        switch stage {
        case "spec_writing": "Spec writing"
        case "coding": "Coding"
        case "review": "Review"
        default: stage
        }
    }

    static func hasLabel(_ stage: String) -> Bool {
        !stage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "45%" or "45% · Coding"; a blank stage shows the percent alone.
    static func summary(percent: Double, stage: String) -> String {
        hasLabel(stage) ? "\(number(percent)) percent, \(label(stage))" : "\(number(percent)) percent"
    }

    static func color(_ stage: String) -> HarklightColor {
        let token: HarklightColor.Token = switch stage {
        case "spec_writing": .sky
        case "coding": .teal
        case "review": .amber
        default: .secondary
        }
        return HarklightColor(token: token)
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

struct ProgressSegmentedBar: View {
    let snapshot: ProgressSnapshot
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(snapshot.visits.enumerated()), id: \.offset) { _, visit in
                    if visit.width > 0 {
                        Rectangle()
                            .fill(ProgressStageStyle.color(visit.stage))
                            .frame(width: geometry.size.width * visit.width / 100)
                    }
                }
                Spacer(minLength: 0)
            }
            .background(.hkLine)
            .clipShape(RoundedRectangle(cornerRadius: height > 7 ? 7 : 6))
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(ProgressStageStyle.summary(percent: snapshot.percent, stage: snapshot.stage))
    }
}

struct ProgressMessageRow: View {
    let title: String
    let progress: MessageProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .harklightType(.rowTitle)
                .foregroundStyle(.hkText)
            if let snapshot = progress.snapshot {
                ProgressSegmentedBar(snapshot: snapshot)
                HStack(alignment: .firstTextBaseline) {
                    Text(ProgressStageStyle.hasLabel(snapshot.stage)
                         ? "\(ProgressStageStyle.number(snapshot.percent))% · \(ProgressStageStyle.label(snapshot.stage))"
                         : "\(ProgressStageStyle.number(snapshot.percent))%")
                    Spacer(minLength: 8)
                    Text(snapshot.updatedAt, format: .dateTime.hour().minute())
                }
                .harklightType(.rowTime)
                .foregroundStyle(.hkLabel)
            } else {
                Text("Progress unavailable")
                    .harklightType(.rowBody)
                    .foregroundStyle(.hkSecondary)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Dedicated Progress content: it has no answer, Seen, chat or dismissal action.
/// The caller supplies the current accepted revision, including authoritative
/// lifecycle removal, through the same navigation used for the ordinary identity.
struct ProgressMessageDetail: View {
    let title: String
    let sender: String
    let bodyText: String?
    let progress: MessageProgress

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(sender)
                    .harklightType(.messageSender)
                    .foregroundStyle(.hkSecondary)
                Text(title)
                    .harklightType(.messageTitle)
                    .foregroundStyle(.hkText)
                    .accessibilityAddTraits(.isHeader)
                if let snapshot = progress.snapshot {
                    snapshotContent(snapshot)
                } else {
                    Text("Progress unavailable")
                        .harklightType(.messageBody)
                        .foregroundStyle(.hkSecondary)
                }
                if let bodyText, !bodyText.isEmpty {
                    Text(bodyText)
                        .harklightType(.messageBody)
                        .foregroundStyle(.hkText)
                        .textSelection(.enabled)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.hkBackground)
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("progress.detail")
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: ProgressSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(ProgressStageStyle.number(snapshot.percent))%")
                .font(.largeTitle.bold())
                .monospacedDigit()
                .foregroundStyle(.hkText)
            if ProgressStageStyle.hasLabel(snapshot.stage) {
                Text(ProgressStageStyle.label(snapshot.stage))
                    .harklightType(.messageBody)
                    .foregroundStyle(.hkSecondary)
            }
        }
        ProgressSegmentedBar(snapshot: snapshot, height: 22)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading) {
            ForEach(Array(snapshot.legend.enumerated()), id: \.offset) { _, stage in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ProgressStageStyle.color(stage))
                        .frame(width: 9, height: 9)
                    Text(ProgressStageStyle.label(stage))
                        .harklightType(.rowSender)
                        .foregroundStyle(.hkSecondary)
                }
            }
        }
        if let note = snapshot.note, !note.isEmpty {
            Text(note)
                .harklightType(.messageBody)
                .foregroundStyle(.hkText)
                .textSelection(.enabled)
        }
        Text("Agent update time: \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            .harklightType(.rowTime)
            .foregroundStyle(.hkLabel)
        ForEach(Array(snapshot.visits.enumerated().reversed()), id: \.offset) { _, visit in
            VStack(alignment: .leading, spacing: 6) {
                Divider().overlay(.hkLine)
                HStack(alignment: .firstTextBaseline) {
                    if ProgressStageStyle.hasLabel(visit.stage) {
                        Text(ProgressStageStyle.label(visit.stage))
                    }
                    if let percent = visit.reportedPercent {
                        Text("\(ProgressStageStyle.number(percent))%")
                    }
                    if let delta = visit.delta {
                        Text("\(delta >= 0 ? "+" : "")\(ProgressStageStyle.number(delta))%")
                    }
                }
                .harklightType(.rowSender)
                .foregroundStyle(.hkSecondary)
                if let time = visit.visitAt {
                    Text("Agent time: \(time.formatted(date: .abbreviated, time: .shortened))")
                        .harklightType(.rowTime)
                        .foregroundStyle(.hkLabel)
                }
                if let note = visit.note {
                    Text(note)
                        .harklightType(.rowBody)
                        .foregroundStyle(.hkText)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
