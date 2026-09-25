import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Security

/// Kopplung mit dem iPhone: geheimer Schlüssel, QR-Code, Adresse für unterwegs.
enum CompanionPairing {
    private static var secretFile: URL { EngineConfig.supportDirectory.appending(path: "companion.key") }

    /// Der geteilte Schlüssel. Wird beim ersten Mal erzeugt und nur für den eigenen Benutzer lesbar gespeichert.
    static func secret() -> Data {
        if let data = try? Data(contentsOf: secretFile), data.count >= 32 { return data }
        return resetSecret()
    }

    /// Neuer Schlüssel – alle gekoppelten iPhones müssen neu koppeln.
    @discardableResult
    static func resetSecret() -> Data {
        let secret = CompanionTransport.newSecret()
        try? FileManager.default.createDirectory(at: EngineConfig.supportDirectory, withIntermediateDirectories: true)
        try? secret.write(to: secretFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFile.path)
        return secret
    }

    static var macName: String {
        Host.current().localizedName ?? "Mac"
    }

    static func info(remoteHost: String?) -> PairingInfo {
        PairingInfo(secret: secret(), macName: macName, port: CompanionProtocol.defaultPort, remoteHost: remoteHost)
    }

    static func qrCode(for url: URL, size: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Tailscale-Adresse dieses Macs (z. B. `mein-mac.tailnet.ts.net`), falls Tailscale installiert ist.
    static func detectTailscaleHost() async -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let result = await Shell.run([binary, "status", "--json"]), result.status == 0,
              let json = try? JSONDecoder().decode(JSONValue.self, from: result.output),
              var name = json["Self"]?["DNSName"]?.stringValue, !name.isEmpty
        else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// Team-ID, mit der AppForge signiert ist – für den Push-Schlüssel.
    static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
