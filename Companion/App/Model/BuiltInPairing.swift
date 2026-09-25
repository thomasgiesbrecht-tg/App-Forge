import Foundation

/// Eingebaute Kopplung: `scripts/iphone-installieren.sh` legt beim Bauen die Datei `kopplung.txt`
/// mit dem Schlüssel des eigenen Macs in die App. Dann ist die App ab dem ersten Start verbunden –
/// ohne QR-Code und ohne Anmelden. Die Datei ist von Git ausgeschlossen, der Schlüssel landet nie im Repo.
enum BuiltInPairing {
    static func load() -> PairingInfo? {
        guard let url = Bundle.main.url(forResource: "kopplung", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let link = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return PairingInfo(url: link)
    }
}
