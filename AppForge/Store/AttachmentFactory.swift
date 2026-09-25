import AppKit
import Foundation
import UniformTypeIdentifiers

/// Erzeugt Anhänge aus Dateien, eingefügten Bildern und Screenshots.
enum AttachmentFactory {
    /// Bilder größer als das werden verkleinert, damit sie jedes Modell annimmt.
    private static let maxImageDimension: CGFloat = 2048

    static func from(url: URL) -> Attachment? {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image), let data = try? Data(contentsOf: url) {
            return image(data: data, filename: url.lastPathComponent)
        }
        if type.conforms(to: .pdf), let data = try? Data(contentsOf: url) {
            return Attachment(filename: url.lastPathComponent, mime: "application/pdf",
                              url: "data:application/pdf;base64,\(data.base64EncodedString())", thumbnail: nil)
        }
        // Text und Code: OpenCode liest die Datei selbst ein.
        return Attachment(filename: url.lastPathComponent, mime: type.preferredMIMEType ?? "text/plain",
                          url: url.absoluteString, thumbnail: nil)
    }

    static func image(data: Data, filename: String) -> Attachment? {
        guard let image = NSImage(data: data) else { return nil }
        var payload = data
        var mime = UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType ?? "image/png"
        let size = image.pixelSize
        if max(size.width, size.height) > maxImageDimension || data.count > 4_000_000 {
            if let jpeg = image.resized(maxDimension: maxImageDimension)?.jpegData(quality: 0.85) {
                payload = jpeg
                mime = "image/jpeg"
            }
        }
        return Attachment(
            filename: filename, mime: mime,
            url: "data:\(mime);base64,\(payload.base64EncodedString())",
            thumbnail: image.resized(maxDimension: 160)?.jpegData(quality: 0.8)
        )
    }

    /// Bild aus der Zwischenablage (⌘V).
    static func fromPasteboard() -> [Attachment] {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap(from(url:))
        }
        if let pasted = NSImage(pasteboard: pasteboard), let tiff = pasted.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [image(data: png, filename: "Eingefügtes Bild.png")].compactMap { $0 }
        }
        return []
    }
}

extension NSImage {
    var pixelSize: CGSize {
        guard let rep = representations.first else { return size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    func resized(maxDimension: CGFloat) -> NSImage? {
        let source = pixelSize
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(source.width, source.height))
        let target = CGSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: target)
        result.addRepresentation(rep)
        return result
    }

    func jpegData(quality: Double) -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
