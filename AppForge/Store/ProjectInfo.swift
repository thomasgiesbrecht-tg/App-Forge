import AppKit
import Foundation

/// App-Name und App-Icon eines Projekts – gelesen aus dem Xcode-Projekt, damit Projekte
/// in AppForge so aussehen wie die App, die dabei entsteht.
struct ProjectInfo {
    var appName: String
    var folderName: String
    var icon: NSImage?
}

@MainActor
enum ProjectInfoCache {
    private static var cache: [String: ProjectInfo] = [:]

    static func info(for path: String) -> ProjectInfo {
        if let cached = cache[path] { return cached }
        let info = load(path)
        cache[path] = info
        return info
    }

    /// Neu einlesen, z. B. nachdem ein Agent das Icon geändert hat.
    static func refresh(_ path: String) { cache[path] = nil }

    private static func load(_ path: String) -> ProjectInfo {
        let root = URL(filePath: path)
        let folderName = root.lastPathComponent
        var appName: String?
        var iconSet: URL?
        var iconBundle: URL?
        var xcodeproj: URL?

        let skip: Set<String> = ["build", "DerivedData", ".build", "Pods", "node_modules", ".git", "Carthage", "fastlane"]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                if walker.level > 5 || skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                switch url.pathExtension {
                case "xcodeproj": if xcodeproj == nil { xcodeproj = url }
                case "appiconset" where url.lastPathComponent.hasPrefix("AppIcon"): if iconSet == nil { iconSet = url }
                case "icon": if iconBundle == nil { iconBundle = url }
                default: break
                }
            }
        }

        if let xcodeproj { appName = displayName(in: xcodeproj) ?? xcodeproj.deletingPathExtension().lastPathComponent }
        let icon = iconSet.flatMap(largestImage(in:)) ?? iconBundle.flatMap(firstImage(in:))
        return ProjectInfo(appName: appName ?? folderName, folderName: folderName, icon: icon)
    }

    /// Anzeigename der App: bevorzugt das Ziel, das ein App-Icon hat (nicht Erweiterungen oder Widgets).
    private static func displayName(in xcodeproj: URL) -> String? {
        guard let text = try? String(contentsOf: xcodeproj.appending(path: "project.pbxproj"), encoding: .utf8) else { return nil }
        let blocks = text.components(separatedBy: "buildSettings = {").dropFirst().map { $0.components(separatedBy: "};").first ?? "" }
        func value(_ key: String, in block: String) -> String? {
            guard let range = block.range(of: "\(key) = ") else { return nil }
            let rest = block[range.upperBound...]
            let raw = rest.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return cleaned.isEmpty || cleaned.contains("$(") ? nil : cleaned
        }
        let appBlocks = blocks.filter { $0.contains("ASSETCATALOG_COMPILER_APPICON_NAME") }
        for block in appBlocks + blocks {
            if let name = value("INFOPLIST_KEY_CFBundleDisplayName", in: block) ?? value("PRODUCT_NAME", in: block) { return name }
        }
        return nil
    }

    private static func largestImage(in iconSet: URL) -> NSImage? {
        let files = (try? FileManager.default.contentsOfDirectory(at: iconSet, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let images = files.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        let largest = images.max { size(of: $0) < size(of: $1) }
        return largest.flatMap(NSImage.init(contentsOf:))
    }

    /// Icon-Composer-Bündel (.icon): Das zusammengesetzte Bild gibt es erst nach dem Build – als Vorschau die erste Ebene.
    private static func firstImage(in bundle: URL) -> NSImage? {
        let assets = bundle.appending(path: "Assets")
        let files = (try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)) ?? []
        return files.first { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.flatMap(NSImage.init(contentsOf:))
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
