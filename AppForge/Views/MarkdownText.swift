import SwiftUI

/// Markdown-Darstellung im Stil „Aura dunkel“: Absätze, Überschriften, Listen, Tabellen, Zitate, Code.
struct MarkdownText: View {
    let text: String
    var showsCaret = false

    var body: some View {
        let blocks = MarkdownCache.blocks(for: text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                let isLast = block.id == blocks.last?.id
                BlockView(block: block, showsCaret: showsCaret && isLast && block.acceptsCaret)
            }
            if showsCaret, !(blocks.last?.acceptsCaret ?? false) {
                BlinkingCaret()
            }
        }
    }
}

// MARK: Parser

struct MarkdownBlock: Identifiable {
    enum Kind {
        case paragraph(String)
        case heading(level: Int, String)
        case bullets([String])
        case numbered([(number: String, text: String)])
        case table(header: [String], rows: [[String]])
        case quote(String)
        case code(language: String, String)
        case rule
    }

    let id: Int
    let kind: Kind

    var acceptsCaret: Bool {
        if case .paragraph = kind { return true }
        return false
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock.Kind] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [(String, String)] = []
        var tableRows: [[String]] = []
        var quote: [String] = []
        var code: [String] = []
        var codeLanguage = ""
        var inCode = false

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered.map { (number: $0.0, text: $0.1) })); numbered = [] }
            if !tableRows.isEmpty {
                blocks.append(.table(header: tableRows[0], rows: Array(tableRows.dropFirst())))
                tableRows = []
            }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: codeLanguage, code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flush()
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { code.append(rawLine); continue }

            if line.isEmpty { flush(); continue }

            if line.hasPrefix("|") {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty {
                    let pending = tableRows; flush(); tableRows = pending
                }
                if line.range(of: #"^\|?[\s:\-|]+\|?$"#, options: .regularExpression) != nil, line.contains("-") { continue }
                tableRows.append(cells(of: line))
                continue
            } else if !tableRows.isEmpty {
                flush()
            }

            if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = line[match].filter { $0 == "#" }.count
                blocks.append(.heading(level: level, String(line[match.upperBound...])))
            } else if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flush()
                blocks.append(.rule)
            } else if let match = line.range(of: #"^[-*•+]\s+"#, options: .regularExpression) {
                if bullets.isEmpty { flush() }
                bullets.append(String(line[match.upperBound...]))
            } else if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                if numbered.isEmpty { flush() }
                let number = line[match].trimmingCharacters(in: .whitespaces)
                numbered.append((number, String(line[match.upperBound...])))
            } else if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !bullets.isEmpty, rawLine.hasPrefix("  ") {
                bullets[bullets.count - 1] += " " + line
            } else {
                if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        if inCode { blocks.append(.code(language: codeLanguage, code.joined(separator: "\n"))) }
        flush()
        return blocks.enumerated().map { MarkdownBlock(id: $0.offset, kind: $0.element) }
    }

    private static func cells(of line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = Theme.Fonts.mono(12.5)
                result[run.range].foregroundColor = Theme.sand
            }
            if run.link != nil {
                result[run.range].foregroundColor = Theme.ochre
            }
        }
        return result
    }
}

// MARK: Zwischenspeicher

/// Zerlegte Antworten und formatierte Absätze zwischenspeichern.
/// Ohne das würde beim Scrollen jede sichtbare Antwort bei jedem Neuzeichnen neu geparst.
@MainActor
enum MarkdownCache {
    private final class Blocks { let value: [MarkdownBlock]; init(_ value: [MarkdownBlock]) { self.value = value } }
    private final class Inline { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }

    private static let blockCache: NSCache<NSString, Blocks> = {
        let cache = NSCache<NSString, Blocks>()
        cache.countLimit = 400
        return cache
    }()
    private static let inlineCache: NSCache<NSString, Inline> = {
        let cache = NSCache<NSString, Inline>()
        cache.countLimit = 3000
        return cache
    }()

    static func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let cached = blockCache.object(forKey: key) { return cached.value }
        let parsed = MarkdownParser.parse(text)
        blockCache.setObject(Blocks(parsed), forKey: key)
        return parsed
    }

    static func inline(_ text: String) -> AttributedString {
        let key = text as NSString
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        let formatted = MarkdownParser.inline(text)
        inlineCache.setObject(Inline(formatted), forKey: key)
        return formatted
    }
}

// MARK: Darstellung

private struct BlockView: View {
    let block: MarkdownBlock
    let showsCaret: Bool

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            ProseText(attributed: MarkdownCache.inline(text), showsCaret: showsCaret)

        case .heading(let level, let text):
            Text(MarkdownCache.inline(text))
                .font(Theme.Fonts.sans(level <= 1 ? 19 : level == 2 ? 16.5 : 14.5, level <= 2 ? .regular : .medium))
                .tracking(level <= 2 ? -0.2 : 0)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 6)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(Theme.textTertiary)
                            .frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(MarkdownCache.inline(item))
                            .font(Theme.Fonts.sans(14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 4)

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.number)
                            .font(Theme.Fonts.mono(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(MarkdownCache.inline(item.text))
                            .font(Theme.Fonts.sans(14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
            }

        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)

        case .quote(let text):
            Text(MarkdownCache.inline(text))
                .font(Theme.Fonts.sans(13.5, .light))
                .lineSpacing(4)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.moss).frame(width: 2)
                }

        case .code(let language, let code):
            CodeBlock(title: language.isEmpty ? nil : language, code: code)

        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 6)
        }
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownCache.inline(cell))
                            .font(Theme.Fonts.sans(12.5))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.vertical, 9)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { column in
                            let isLast = column == header.count - 1
                            Text(MarkdownCache.inline(column < row.count ? row[column] : ""))
                                .font(Theme.Fonts.sans(13))
                                .foregroundStyle(column == 0 ? Theme.textPrimary : Theme.textSecondary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: !isLast && header.count > 1, vertical: true)
                                .frame(maxWidth: isLast ? .infinity : 240, alignment: .leading)
                                .padding(.vertical, 9)
                                .textSelection(.enabled)
                        }
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .glass(cornerRadius: 14, tintOpacity: 0.25, shadow: false)
    }
}

/// Fließtext mit blinkendem Cursor, solange die Antwort noch einläuft.
private struct ProseText: View {
    let attributed: AttributedString
    let showsCaret: Bool

    var body: some View {
        Group {
            if showsCaret {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let visible = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    Text(attributed) + Text(" ▍").foregroundColor(Theme.ochre.opacity(visible ? 1 : 0))
                }
            } else {
                Text(attributed)
            }
        }
        .font(Theme.Fonts.sans(14))
        .lineSpacing(4.5)
        .foregroundStyle(Theme.textPrimary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlinkingCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let visible = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.ochre)
                .frame(width: 7, height: 15)
                .opacity(visible ? 1 : 0)
        }
    }
}

struct CodeBlock: View {
    let title: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let title { Eyebrow(title) }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(Theme.Motion.bouncy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(Theme.Motion.gentle) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(copied ? Theme.sage : Theme.textTertiary)
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("Kopieren")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            ScrollView(.horizontal) {
                Text(code)
                    .font(Theme.Fonts.mono(12))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.sand.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.void.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}
