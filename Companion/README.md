# AppForge Companion (iPhone)

Die iPhone-App zu AppForge: Ideen je App sammeln (Widget, Siri, Kontrollzentrum), in jeder App chatten,
die Zentrale beauftragen, Aufträge und Freigaben verfolgen – im WLAN und unterwegs.
Ist der Mac nicht erreichbar, wird alles gespeichert und später gesendet.

## Einmalige Einrichtung

### 1. AppForge auf dem Mac aktualisieren
`scripts/installieren.sh` ausführen. Neu in AppForge:
- **Einstellungen → iPhone**: QR-Code zum Koppeln, Adresse für unterwegs, „Mac wach halten“, Push-Schlüssel
- **Ideen**: Glühbirne oben rechts im Chat. Ideen landen in der Seitenleiste und werden vom Ideen-Agenten eingeordnet.

Beim ersten Start fragt macOS, ob AppForge Geräte im lokalen Netzwerk finden darf → **Erlauben**.

### 2. iPhone-App bauen
1. `Companion/AppForgeCompanion.xcodeproj` in Xcode öffnen.
2. Für beide Targets (AppForgeCompanion, AppForgeWidgets) unter *Signing & Capabilities* das Team prüfen.
   Signierung ist auf „Automatisch“ gestellt. Xcode legt App-IDs, App-Gruppe und Push-Berechtigung selbst an.
3. iPhone wählen → Run.
4. Auf dem iPhone erlauben: lokales Netzwerk, Mitteilungen, später Mikrofon und Spracherkennung.

### 3. Koppeln
Den QR-Code unter AppForge → Einstellungen → iPhone mit der **Kamera-App** scannen.
Alternativ „Kopplungs-Link kopieren“ und in der iPhone-App unter „Mac“ einfügen.

### 4. Benachrichtigungen & Live-Aktivitäten (einmalig)
Apple verlangt dafür einen Push-Schlüssel:
1. developer.apple.com → Certificates, Identifiers & Profiles → **Keys** → „+“
2. Namen vergeben, **Apple Push Notifications service (APNs)** anhaken, speichern, `AuthKey_XXXXXXXXXX.p8` laden.
3. In AppForge → Einstellungen → iPhone → „Push-Schlüssel (.p8) wählen …“.

Danach gilt: Wer im Chat oder bei der Zentrale „sag Bescheid, wenn fertig“ (o. Ä.) schreibt, bekommt:
- eine Mitteilung bei Rückfragen bzw. Freigaben, mit den Knöpfen **Freigeben / Immer / Ablehnen**,
- eine Mitteilung, wenn die Aufgabe fertig ist.

Jede Aufgabe vom iPhone erscheint außerdem als Live-Aktivität (Sperrbildschirm, Dynamic Island).

### 5. Unterwegs
Tailscale auf Mac und iPhone installieren und mit demselben Konto anmelden.
AppForge erkennt die Tailscale-Adresse selbst (Einstellungen → iPhone). **Danach einmal neu koppeln**, damit die Adresse im QR-Code steckt.
Den Mac am Strom und aufgeklappt lassen. „Mac wach halten“ verhindert den Ruhezustand, solange AppForge läuft.

## Widgets & Kurzbefehle
- **Ideen-Widget** (klein, mittel, groß, Sperrbildschirm): App antippen → Idee schreiben. Im großen Widget gibt es pro App ein 🎤 zum direkten Einsprechen.
  Bearbeiten → „Apps wählen“, sonst zeigt es die zuletzt benutzten Apps.
- **Kontrollzentrum / Aktionstaste**: Knopf „Idee notieren“ → App wählen → drücken und sprechen.
- **Siri**: „Neue Idee in AppForge“ oder „Idee für ‹App› in AppForge“.

## Aufbau
- `../Shared/`: Protokoll und verschlüsselte Verbindung (TLS mit Schlüssel aus dem QR-Code, WebSocket), gemeinsam mit dem Mac.
- `Common/`: App-Gruppe, App-Auswahl für Widgets und Siri, Live-Aktivität. Wird von App und Widgets gemeinsam genutzt.
- `App/`: die App (Modell, Sprache, Ansichten, Siri).
- `Widgets/`: Ideen-Widget, Kontrollzentrum-Knopf, Live-Aktivität.

Das iPhone spricht nie direkt mit der Engine, sondern immer mit der Companion-Bridge in AppForge.
Dadurch gelten Zentrale, Budgets und Berechtigungsmodus auch unterwegs.
Nachrichten vom iPhone bekommen einen Hinweis für den Agenten, dass niemand am Mac sitzt.
