import SwiftUI
import WidgetKit

/// Komplikationen fürs Zifferblatt: laufende Aufträge, offene Freigaben, heutige Kosten.
/// Die Daten legt die Watch-App in die gemeinsame App-Gruppe.
struct WatchEntry: TimelineEntry {
    let date: Date
    let state: WatchState
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry {
        var sample = WatchState.empty
        sample.connected = true
        sample.spentTodayUSD = 0.14
        return WatchEntry(date: .now, state: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(WatchEntry(date: .now, state: WatchStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        // Aktualisiert wird vor allem, wenn die Watch-App neue Daten bekommt (reloadAllTimelines).
        completion(Timeline(entries: [WatchEntry(date: .now, state: WatchStore.load())], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

private let green = Color(red: 0.298, green: 0.851, blue: 0.482)
private let orange = Color(red: 1.0, green: 0.541, blue: 0.2)

struct WatchComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchEntry

    var body: some View {
        let state = entry.state
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Image(systemName: state.permissions.isEmpty ? "hammer.fill" : "hand.raised.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.permissions.isEmpty ? green : orange)
                    Text("\(state.permissions.isEmpty ? state.running : state.permissions.count)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                }
            }
            .widgetAccentable()
        case .accessoryCorner:
            Image(systemName: "hammer.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(green)
                .widgetLabel {
                    Text(state.permissions.isEmpty ? "\(state.running) laufen" : "\(state.permissions.count) Freigabe")
                }
        case .accessoryInline:
            Text(state.permissions.isEmpty
                 ? "AppForge · \(state.running) laufen"
                 : "AppForge · \(state.permissions.count) Freigabe offen")
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "hammer.fill").foregroundStyle(green)
                    Text("AppForge").font(.headline)
                }
                Text(state.running == 1 ? "1 Auftrag läuft" : "\(state.running) Aufträge laufen")
                    .font(.caption)
                if !state.permissions.isEmpty {
                    Text(state.permissions.count == 1 ? "1 Freigabe offen" : "\(state.permissions.count) Freigaben offen")
                        .font(.caption)
                        .foregroundStyle(orange)
                } else {
                    Text("heute \(state.euroShort(state.spentTodayUSD))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct AppForgeWatchComplications: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AppForgeWatch", provider: WatchProvider()) { entry in
            WatchComplicationView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("AppForge")
        .description("Laufende Aufträge, offene Freigaben und heutige Kosten.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
