import Foundation

/// Was ein Auftrag bisher bewirkt hat – für Live-Ansicht und Auftragsliste.
struct MissionInsights: Codable, Hashable, Sendable {
    struct Build: Codable, Hashable, Sendable {
        var ok: Bool
        var time: Double
        var errors: Int?
    }
    struct Tests: Codable, Hashable, Sendable {
        var ok: Bool
        var passed: Int?
        var total: Int?
        var time: Double
    }

    /// Kurzform der geänderten Dateien (z. B. „Ansicht/Timeline.swift“).
    var files: [String] = []
    var additions = 0
    var deletions = 0
    var build: Build?
    var tests: Tests?
    var todoDone = 0
    var todoTotal = 0
    var contextUsed: Double = 0
    var contextLimit: Double = 0

    var progress: Double? { todoTotal > 0 ? Double(todoDone) / Double(todoTotal) : nil }
    var contextFraction: Double? { contextLimit > 0 && contextUsed > 0 ? min(1, contextUsed / contextLimit) : nil }

    var testsLabel: String? {
        guard let tests else { return nil }
        if let passed = tests.passed, let total = tests.total { return "Tests \(passed)/\(total)" }
        return tests.ok ? "Tests grün" : "Tests rot"
    }
}

/// Liest die Kennzahlen aus den Chat-Verläufen eines Auftrags (Hauptsitzung und Unteragenten).
enum InsightExtractor {
    struct Result {
        var insights: MissionInsights
        /// Letztes Bild (Screenshot, erzeugtes Bild) – nur live verfügbar, nicht gespeichert.
        var preview: Part?
    }

    static func extract(main: [ChatMessage], children: [[ChatMessage]], contextLimit: Double) -> Result {
        var insights = MissionInsights()
        var preview: Part?
        var fileOrder: [String] = []
        var fileSet = Set<String>()

        func addFile(_ path: String) {
            let short = shortPath(path)
            if fileSet.insert(short).inserted { fileOrder.append(short) }
        }

        let allParts = ([main] + children).flatMap { $0.flatMap(\.parts) }
        for part in allParts {
            // Bilder: angehängte Dateien und Werkzeug-Ergebnisse (Screenshots)
            if part.isImage { preview = part }
            if let images = part.state?.attachments?.filter(\.isImage), let last = images.last { preview = last }

            guard part.type == "tool", let tool = part.tool, let state = part.state else { continue }
            let end = state.time?.end ?? state.time?.start ?? 0

            switch tool {
            case "edit", "write", "multiedit", "patch", "apply_patch":
                if let path = state.input?["filePath"]?.stringValue { addFile(path) }
                if let diff = state.metadata?["filediff"] {
                    if case .number(let add) = diff["additions"] { insights.additions += Int(add) }
                    if case .number(let del) = diff["deletions"] { insights.deletions += Int(del) }
                }
            case "todowrite":
                if case .array(let todos) = state.input?["todos"] {
                    insights.todoTotal = todos.filter { $0["status"]?.stringValue != "cancelled" }.count
                    insights.todoDone = todos.filter { $0["status"]?.stringValue == "completed" }.count
                }
            case "bash":
                guard state.status == "completed" || state.status == "error" else { continue }
                let command = state.input?["command"]?.stringValue ?? ""
                let output = state.output ?? state.error ?? ""
                let isTest = (command.contains("xcodebuild") && command.contains(" test")) || command.contains("swift test")
                let isBuild = !isTest && (command.contains("xcodebuild") || command.contains("swift build"))
                if isTest, let tests = parseTests(output, time: end) { insights.tests = newer(insights.tests, tests) }
                if isBuild, let build = parseBuild(output, time: end) { insights.build = newer(insights.build, build) }
                if isTest, let build = parseBuild(output, time: end) { insights.build = newer(insights.build, build) }
            default:
                // XcodeBuildMCP- und Xcode-Werkzeuge
                guard tool.hasPrefix("xcodebuildmcp_") || tool.hasPrefix("xcode_"),
                      state.status == "completed" || state.status == "error" else { continue }
                let output = (state.output ?? state.error ?? "").lowercased()
                let failed = state.status == "error" || output.contains("failed") || output.contains("❌") || output.contains("error:")
                if tool.contains("test") {
                    let parsed = parseTests(state.output ?? "", time: end) ?? MissionInsights.Tests(ok: !failed, time: end)
                    insights.tests = newer(insights.tests, parsed)
                } else if tool.contains("build") {
                    insights.build = newer(insights.build, MissionInsights.Build(ok: !failed, time: end, errors: nil))
                }
            }
        }

        // Dateiänderungen laut Zusammenfassung der Nutzer-Nachrichten (präziser als die Werkzeuge)
        let summarized = main.filter(\.info.isUser).flatMap(\.info.fileChanges)
        if !summarized.isEmpty {
            insights.additions = Int(summarized.reduce(0) { $0 + $1.additions })
            insights.deletions = Int(summarized.reduce(0) { $0 + $1.deletions })
            for change in summarized { if let file = change.file { addFile(file) } }
        }
        insights.files = fileOrder

        if let last = main.last(where: { !$0.info.isUser && $0.info.tokens != nil }), let tokens = last.info.tokens {
            insights.contextUsed = tokens.contextUsed
            insights.contextLimit = contextLimit
        }
        return Result(insights: insights, preview: preview)
    }

    // MARK: Auswertung von Build- und Testausgaben

    static func parseBuild(_ output: String, time: Double) -> MissionInsights.Build? {
        let errors = output.components(separatedBy: "error:").count - 1
        if output.contains("BUILD SUCCEEDED") || output.contains("Build complete!") {
            return MissionInsights.Build(ok: true, time: time, errors: 0)
        }
        if output.contains("BUILD FAILED") || output.contains("error: fatalError") || errors > 0 {
            return MissionInsights.Build(ok: false, time: time, errors: max(errors, 1))
        }
        return nil
    }

    static func parseTests(_ output: String, time: Double) -> MissionInsights.Tests? {
        // XCTest: „Executed 45 tests, with 3 failures …“
        if let match = output.matches(of: /Executed (\d+) tests?, with (\d+) failures?/).last,
           let total = Int(match.1), let failures = Int(match.2) {
            return MissionInsights.Tests(ok: failures == 0, passed: total - failures, total: total, time: time)
        }
        // Swift Testing: „Test run with 12 tests passed …“ / „Test run with 12 tests failed … with 2 issues“
        if let match = output.matches(of: /Test run with (\d+) tests?[^\n]*?(passed|failed)/).last, let total = Int(match.1) {
            let passed = match.2 == "passed"
            var failing = 0
            if !passed, let issues = output.matches(of: /with (\d+) issues?/).last, let count = Int(issues.1) { failing = count }
            return MissionInsights.Tests(ok: passed, passed: passed ? total : max(0, total - failing), total: total, time: time)
        }
        if output.contains("TEST SUCCEEDED") { return MissionInsights.Tests(ok: true, time: time) }
        if output.contains("TEST FAILED") { return MissionInsights.Tests(ok: false, time: time) }
        return nil
    }

    private static func newer<T>(_ current: T?, _ candidate: T) -> T where T: TimedResult {
        guard let current else { return candidate }
        return candidate.time >= current.time ? candidate : current
    }

    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

protocol TimedResult { var time: Double { get } }
extension MissionInsights.Build: TimedResult {}
extension MissionInsights.Tests: TimedResult {}
