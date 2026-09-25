import AppIntents
import SwiftUI
import WidgetKit

/// Ideen-Widget: Icon und Name der Apps – ein Tipp öffnet direkt die Ideen-Erfassung.
struct IdeaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "IdeaWidget", intent: SelectAppsIntent.self, provider: IdeaProvider()) { entry in
            IdeaWidgetView(entry: entry)
                .containerBackground(Palette.black, for: .widget)
        }
        .configurationDisplayName("Ideen")
        .description("Tippe auf eine App und sprich oder schreib deine Idee.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
    }
}

struct IdeaEntry: TimelineEntry {
    var date: Date
    var projects: [CompanionProject]
}

struct IdeaProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> IdeaEntry {
        IdeaEntry(date: .now, projects: [
            CompanionProject(id: "a", name: "Meine App", folderName: "", iconPNG: nil, openIdeas: 3, spentUSD: 0, isMac: false),
            CompanionProject(id: "b", name: "Zweite App", folderName: "", iconPNG: nil, openIdeas: 0, spentUSD: 0, isMac: false),
        ])
    }

    func snapshot(for configuration: SelectAppsIntent, in context: Context) async -> IdeaEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectAppsIntent, in context: Context) async -> Timeline<IdeaEntry> {
        // Die App lädt das Widget neu, sobald sich Projekte oder Ideen ändern.
        Timeline(entries: [entry(for: configuration)], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func entry(for configuration: SelectAppsIntent) -> IdeaEntry {
        let all = SharedStore.projectsByRecent()
        let chosen = configuration.apps ?? []
        let projects = chosen.isEmpty
            ? all
            : chosen.compactMap { entity in all.first { $0.id == entity.id } }
        return IdeaEntry(date: .now, projects: projects)
    }
}

struct IdeaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: IdeaEntry

    var body: some View {
        if entry.projects.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "lightbulb").font(.title2).foregroundStyle(Palette.accent)
                Text("Öffne AppForge einmal, damit deine Apps hier erscheinen.")
                    .font(.caption2).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            }
        } else {
            switch family {
            case .systemSmall: small
            case .systemMedium: grid(columns: 4, rows: 1, withButtons: false)
            case .systemLarge: grid(columns: 2, rows: 4, withButtons: true)
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            default: small
            }
        }
    }

    // Klein: eine App, groß – ein Tipp, dann schreiben oder sprechen.
    private var small: some View {
        let project = entry.projects[0]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProjectIconView(project, size: 46)
                Spacer()
                Image(systemName: "lightbulb.fill").foregroundStyle(Palette.accent)
            }
            Spacer(minLength: 0)
            Text(project.name).font(.headline).foregroundStyle(Palette.text).lineLimit(1)
            Text(project.openIdeas > 0 ? "\(project.openIdeas) offene Ideen" : "Neue Idee")
                .font(.caption).foregroundStyle(Palette.secondary)
        }
        .widgetURL(DeepLink.capture(project.id, mode: .write))
    }

    private func grid(columns: Int, rows: Int, withButtons: Bool) -> some View {
        let items = Array(entry.projects.prefix(columns * rows))
        let layout = Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
        return VStack(alignment: .leading, spacing: 10) {
            if withButtons {
                Label("Idee notieren", systemImage: "lightbulb.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            LazyVGrid(columns: layout, alignment: .leading, spacing: withButtons ? 12 : 8) {
                ForEach(items) { project in
                    if withButtons {
                        largeTile(project)
                    } else {
                        Link(destination: DeepLink.capture(project.id, mode: .write)) { tile(project) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tile(_ project: CompanionProject) -> some View {
        VStack(spacing: 6) {
            ProjectIconView(project, size: 48)
            Text(project.name).font(.caption2).foregroundStyle(Palette.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // Groß: je App direkt „schreiben“ oder „sprechen“.
    private func largeTile(_ project: CompanionProject) -> some View {
        HStack(spacing: 8) {
            Link(destination: DeepLink.capture(project.id, mode: .write)) {
                HStack(spacing: 8) {
                    ProjectIconView(project, size: 36)
                    Text(project.name).font(.caption.weight(.medium)).foregroundStyle(Palette.text).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            Link(destination: DeepLink.capture(project.id, mode: .speak)) {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.black)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.accent))
            }
        }
    }

    private var circular: some View {
        let project = entry.projects[0]
        return ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "lightbulb.fill").font(.caption)
                Text(String(project.name.prefix(6))).font(.system(size: 9, weight: .semibold)).lineLimit(1)
            }
        }
        .widgetURL(DeepLink.capture(project.id, mode: .speak))
    }

    private var rectangular: some View {
        let project = entry.projects[0]
        return VStack(alignment: .leading, spacing: 2) {
            Label("Idee", systemImage: "lightbulb.fill").font(.caption.weight(.semibold))
            Text(project.name).font(.headline).lineLimit(1)
            Text("antippen und sprechen").font(.caption2)
        }
        .widgetURL(DeepLink.capture(project.id, mode: .speak))
    }
}
