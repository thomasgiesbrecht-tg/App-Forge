import ActivityKit
import SwiftUI
import WidgetKit

/// Live-Aktivität auf dem Sperrbildschirm und in der Dynamic Island.
struct TaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Palette.black)
                .activitySystemActionForegroundColor(Palette.text)
                .widgetURL(context.attributes.link)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.projectName, systemImage: context.attributes.isMac ? "desktopcomputer" : "hammer.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusBadge(state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let activity = state.activity {
                            Text(activity).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2)
                        }
                        Footer(state: state)
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(state.kind)).foregroundStyle(Palette.color(for: state.kind))
            } compactTrailing: {
                if state.kind == .running {
                    Text(Date(timeIntervalSince1970: state.startedAt), style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                        .font(.caption2)
                } else {
                    Text(state.status).font(.caption2).foregroundStyle(Palette.color(for: state.kind))
                }
            } minimal: {
                Image(systemName: symbol(state.kind)).foregroundStyle(Palette.color(for: state.kind))
            }
            .widgetURL(context.attributes.link)
            .keylineTint(Palette.orange)
        }
    }
}

private func symbol(_ kind: LiveTaskState.Kind) -> String {
    switch kind {
    case .running: "hammer.fill"
    case .needsYou: "questionmark.bubble.fill"
    case .done: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
}

private struct LockScreenView: View {
    let attributes: TaskActivityAttributes
    let state: LiveTaskState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(attributes.projectName, systemImage: attributes.isMac ? "desktopcomputer" : "hammer.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.secondary)
                Spacer()
                StatusBadge(state: state)
            }
            Text(state.title).font(.headline).foregroundStyle(Palette.text).lineLimit(1)
            if let activity = state.activity {
                Text(activity).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(2)
            }
            Footer(state: state)
        }
        .padding(16)
    }
}

private struct StatusBadge: View {
    let state: LiveTaskState

    var body: some View {
        Label(state.status, systemImage: symbol(state.kind))
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.color(for: state.kind))
            .lineLimit(1)
    }
}

private struct Footer: View {
    let state: LiveTaskState

    var body: some View {
        HStack(spacing: 10) {
            if state.partsTotal > 1 {
                ProgressView(value: Double(state.partsDone), total: Double(state.partsTotal))
                    .tint(Palette.orange)
                Text("\(state.partsDone)/\(state.partsTotal)")
            }
            if let end = state.endedAt {
                Text(Duration.seconds(end - state.startedAt).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
            } else {
                Text(Date(timeIntervalSince1970: state.startedAt), style: .timer).monospacedDigit()
            }
            Spacer()
            if state.spentUSD > 0 {
                Text(state.spentUSD, format: .currency(code: "USD").precision(.fractionLength(2)))
            }
        }
        .font(.caption2)
        .foregroundStyle(Palette.tertiary)
    }
}
