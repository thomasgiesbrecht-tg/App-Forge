import Foundation

/// Fasst zusammen, was ein Agent gerade tut – in wenigen Worten, für die Live-Ansicht.
enum ActivityDigest {
    /// Aktuelle Tätigkeit aus dem Verlauf einer Sitzung, z. B. „bearbeitet Timeline.swift“.
    static func activity(of messages: [ChatMessage]) -> String? {
        guard let last = messages.last(where: { !$0.info.isUser }) else {
            return messages.isEmpty ? nil : "liest den Auftrag"
        }
        for part in last.parts.reversed() {
            switch part.type {
            case "tool":
                return describe(part)
            case "text":
                if let text = part.text, !text.isEmpty { return "schreibt: " + short(firstSentence(text), 42) }
            case "reasoning":
                if let text = part.text, !text.isEmpty { return "überlegt: " + short(firstSentence(text), 40) }
            default:
                continue
            }
        }
        return "denkt nach"
    }

    /// Schlusssatz eines fertigen Auftrags.
    static func summary(of messages: [ChatMessage]) -> String? {
        guard let last = messages.last(where: { !$0.info.isUser }) else { return nil }
        let text = last.parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: " ")
        return text.isEmpty ? nil : short(firstSentence(text), 60)
    }

    /// Unteragenten, die ein Agent über das Task-Werkzeug beauftragt hat.
    static func subagents(in messages: [ChatMessage], lookup: (String) -> [ChatMessage]?) -> [SubagentSnapshot] {
        messages.flatMap(\.parts)
            .filter { $0.type == "tool" && $0.tool == "task" }
            .map { part in
                let child = part.childSessionID
                return SubagentSnapshot(
                    name: part.state?.input?["subagent_type"]?.stringValue ?? "unteragent",
                    task: short(part.state?.input?["description"]?.stringValue ?? part.state?.title ?? "Auftrag", 40),
                    status: part.state?.status ?? "pending",
                    activity: child.flatMap(lookup).flatMap(activity(of:)),
                    childSessionID: child
                )
            }
    }

    // MARK: Hilfen

    private static func describe(_ part: Part) -> String {
        let tool = part.tool ?? ""
        let file = part.state?.input?["filePath"]?.stringValue.map { ($0 as NSString).lastPathComponent }
        let title = part.state?.title ?? ""
        let running = part.state?.status == "running"
        switch tool {
        case "read": return "liest " + (file ?? short(title, 30))
        case "write": return "schreibt " + (file ?? short(title, 30))
        case "edit", "multiedit", "apply_patch", "patch": return "bearbeitet " + (file ?? short(title, 30))
        case "grep", "glob", "list": return "durchsucht den Code"
        case "bash":
            let command = part.state?.input?["command"]?.stringValue ?? title
            if command.contains("xcodebuild") && command.contains("test") { return running ? "führt Tests aus" : "Tests gelaufen" }
            if command.contains("xcodebuild") || command.contains("swift build") { return running ? "baut das Projekt" : "Build fertig" }
            return (running ? "führt aus: " : "ausgeführt: ") + short(command, 30)
        case "task": return "beauftragt @" + (part.state?.input?["subagent_type"]?.stringValue ?? "unteragent")
        case "skill": return "lädt Skill " + (part.state?.input?["name"]?.stringValue ?? "")
        case "webfetch", "websearch": return "recherchiert im Web"
        case "todowrite": return "plant die nächsten Schritte"
        default:
            if tool.hasPrefix("xcodebuildmcp_") || tool.hasPrefix("xcode_") {
                if tool.contains("screenshot") { return "prüft den Simulator" }
                if tool.contains("test") { return "führt Tests aus" }
                if tool.contains("build") { return "baut in Xcode" }
                return "arbeitet in Xcode"
            }
            if let range = tool.range(of: "_") {
                return "nutzt " + tool[..<range.lowerBound] + " · " + short(String(tool[range.upperBound...]).replacingOccurrences(of: "_", with: " "), 24)
            }
            return "nutzt " + tool
        }
    }

    private static func firstSentence(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if let end = flat.firstIndex(where: { ".!?".contains($0) }) { return String(flat[...end]) }
        return flat
    }

    static func short(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
