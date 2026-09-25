# iPhone-Companion für AppForge – Recherche

Stand: September 2026. Grundlage: der AppForge-Code auf `main` und eine Web-Recherche (Quellen unten).

## 1. Ausgangslage im Code

- AppForge startet `opencode serve` auf `127.0.0.1` mit zufälligem Port und zufälligem Passwort (`EngineProcess`). Mit dem Server spricht die App über REST und den SSE-Stream `/event` (`OpenCodeClient`, `ServerEvent`).
- Folgende Logik steckt **in AppForge selbst**, nicht in OpenCode:
  - Zentrale, Aufträge, Budget- und Zeitgrenzen, Konfliktwarnungen (`Dispatcher`, `Mission`)
  - Berechtigungsmodus mit automatischer Freigabe (`PermissionMode`)
  - Live-Zusammenfassungen (`ActivityDigest`, `MissionInsights`)
  - Simulator-Bilder (`SimulatorService`, `simctl`)
  - `/foto` und `/video` (`MediaStudio`)
- **Folgerung:** Das iPhone darf nicht direkt mit OpenCode reden. Sonst würden Zentrale, Budget und Berechtigungsmodus umgangen. AppForge braucht eine eigene **Companion-Bridge**, und OpenCode bleibt auf localhost.
- App-Sandbox ist aus, Team-ID ist gesetzt. Ein eigener Netzwerk-Listener im Mac-Prozess ist also problemlos möglich.

## 2. Verbindung Mac ↔ iPhone

| Weg | Wofür | Bewertung |
|---|---|---|
| Network.framework: Bonjour + TLS-PSK (`NWListener`/`NWBrowser`, ab WWDC25 auch `NetworkListener`/`NetworkBrowser`) | Live-Verbindung im WLAN | **Basis.** Kein Server, verschlüsselt, Pairing per QR-Code |
| Tailscale (`tailscale serve`, HTTPS nur im eigenen Tailnet) | Live-Verbindung unterwegs | **Einfachster sicherer Weg nach draußen.** Tailscale muss auf dem iPhone aktiv sein |
| APNs direkt vom Mac (`.p8`-Key, JWT, HTTP/2) | Push „fertig“ / „braucht Freigabe“, Live-Activity-Updates | Kein eigener Server nötig. Braucht bezahlten Developer-Account |
| CloudKit (private DB + Subscriptions) | Postfach für Aufträge und Freigaben, wenn keine Live-Verbindung besteht | Kein Server. Stille Pushes werden gedrosselt, für Streaming ungeeignet |
| Eigener Relay mit Ende-zu-Ende-Verschlüsselung (wie Happy, Claude Remote Control) | Unterwegs ohne VPN | Lohnt erst bei mehreren Nutzern |
| MultipeerConnectivity, Wi-Fi Aware | – | Multipeer ist veraltet, Wi-Fi Aware gibt es nicht auf macOS |

**Hintergrund-Limits unter iOS:** Eine suspendierte App kann keine WebSocket- oder SSE-Verbindung offen halten. Deshalb läuft das Live-Streaming nur im Vordergrund, alles andere über Push.

## 3. Was vergleichbare Apps machen

- **Claude Code Remote Control, Codex in ChatGPT, Happy, Omnara:** QR-Pairing, zwei Push-Arten („fertig“, „braucht dich“), Freigabekarten mit Diff oder Befehl, kein Push, solange man am Rechner sitzt, eine Warteschlange bei Verbindungsabbruch. Der Rechner muss wach sein.
- **Fertige OpenCode-Clients** im App Store (OpenLens, OpenCody, OpenClient u. a.) sowie der Open-Source-Client [grapeot/opencode_ios_client](https://github.com/grapeot/opencode_ios_client) als SwiftUI-Referenz. Sie reden alle direkt mit OpenCode und kennen deshalb die AppForge-Zentrale nicht. Das ist der Grund für eine eigene App.
- **Lehre aus Happy:** Pairing-Codes nur einmal und kurz gültig machen.

## 4. Mögliche Funktionen der iPhone-App

**Kern (MVP)**
- Projekte und Chats ansehen, Live-Fortschritt (Streaming-Text, „bearbeitet Timeline.swift“ …).
- Auftrag an die Zentrale senden (Text oder Diktat), Vorschlag mit Modell und Kostenschätzung bestätigen.
- Laufende Aufträge mit Kosten, Zeit, Build- und Teststatus. Stoppen.
- Freigaben erteilen oder ablehnen, mit Befehl bzw. Diff.
- Simulator-Screenshot ansehen.

**Danach**
- Push mit den Aktionen „Freigeben“ und „Ablehnen“ direkt in der Benachrichtigung (`.authenticationRequired`).
- Live Activity bzw. Dynamic Island für laufende Aufträge. Buttons darin über `LiveActivityIntent`. Grenzen: höchstens 8 h aktiv, 4 KB Daten.
- Siri/Kurzbefehle („Auftrag an AppForge“), Widgets, Apple Watch.
- Gebaute App aufs iPhone: Der Mac führt `xcrun devicectl device install app` aus (WLAN oder Tailscale) oder bietet eine OTA-Installation per `itms-services` an. **Eine App kann andere Apps nicht selbst installieren** (Guideline 2.5.2).
- Simulator-Livestream über ScreenCaptureKit und H.264.

## 5. Sicherheit

- OpenCode nie ins LAN oder Internet binden. CVE-2026-22812 zeigt, was ein offener OpenCode-Server anrichtet: Remote Code Execution per Drive-by. AppForge sollte eine Mindestversion prüfen.
- Bridge: TLS-PSK mit einem zufälligen 256-Bit-Secret aus dem QR-Code (keine kurze PIN), gespeichert im Keychain, Geräte einzeln widerrufbar.
- Freigaben auf dem iPhone nur nach Face ID bzw. Entsperren.
- Den APNs-Key nur im Keychain des Macs aufbewahren, nie in die iPhone-App packen.

## 6. Accounts und Verteilung

- Für APNs, Live-Activity-Push, CloudKit, TestFlight und Ad-hoc ist ein bezahlter Developer-Account nötig. Mit kostenlosem Account laufen Profile nach 7 Tagen ab, und Push gibt es nicht.
- Für die persönliche Nutzung reicht die Installation per Xcode oder TestFlight. Der App Store wäre grundsätzlich möglich, denn Agenten-Companions sind dort zugelassen. Ein Simulator-Stream könnte allerdings unter 4.2.7 (Remote Desktop) fallen.

## 7. Empfohlener Stufenplan

1. **MVP im WLAN:** Companion-Bridge in AppForge (Bonjour + TLS-PSK + QR-Pairing, kleines JSON-Protokoll über WebSocket), iPhone-App mit Chats, Zentrale, Aufträgen, Freigaben und Screenshot.
2. **Push:** APNs direkt vom Mac mit Freigabe-Aktionen und Live Activity.
3. **Unterwegs:** Tailscale, optional CloudKit als Postfach.
4. **Extras:** Installation per `devicectl`/OTA, Simulator-Stream, Siri, Widgets, Watch.

## Quellen

- OpenCode Server: https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/server.mdx
- CVE-2026-22812: https://github.com/anomalyco/opencode/security/advisories/GHSA-vxw4-wv6m-9hhh
- Claude Code Remote Control: https://code.claude.com/docs/en/remote-control
- Happy: https://github.com/slopus/happy
- Codex Remote: https://developers.openai.com/codex/remote-connections
- SwiftUI-OpenCode-Client: https://github.com/grapeot/opencode_ios_client
- Apple P2P-Protokoll (TLS-PSK): https://developer.apple.com/documentation/Network/building-a-custom-peer-to-peer-protocol
- Local Network Privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- APNs mit Token: https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
- Live Activities: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- Live-Activity-Push: https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
- Tailscale Serve: https://tailscale.com/docs/features/tailscale-serve
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- Mitgliedschaften: https://developer.apple.com/support/compare-memberships/
