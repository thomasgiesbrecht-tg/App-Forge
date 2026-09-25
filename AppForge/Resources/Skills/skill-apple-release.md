---
name: apple-release
description: App für TestFlight und den App Store vorbereiten – Versionen, Build-Nummern, Archive, Export, Upload, App-Store-Connect-Metadaten, Datenschutz-Angaben. Verwenden beim Veröffentlichen oder Verteilen einer App.
---

# Veröffentlichung (TestFlight / App Store)

## Vorher prüfen
- `MARKETING_VERSION` (z. B. 1.2.0) und `CURRENT_PROJECT_VERSION` (Build-Nummer, muss pro Upload steigen).
- Bundle-ID, Team und Signing sind korrekt. **Nicht ohne Rückfrage ändern.**
- App-Icon vollständig, `PrivacyInfo.xcprivacy` vorhanden, wenn Required-Reason-APIs genutzt werden.
- Alle `NS…UsageDescription`-Texte sind verständlich formuliert.

## Archivieren & exportieren
```bash
xcodebuild archive -scheme "App" -destination 'generic/platform=iOS' -archivePath build/App.xcarchive
xcodebuild -exportArchive -archivePath build/App.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build/export
```
Für macOS `generic/platform=macOS`, außerhalb des App Stores zusätzlich notarisieren (`xcrun notarytool submit … --wait`, danach `xcrun stapler staple`).

## Upload
- `xcrun altool --upload-app` bzw. der Transporter oder fastlane (`pilot`).
- Zugangsdaten nie in Dateien schreiben oder ausgeben. Die Nutzerin bzw. der Nutzer richtet API-Schlüssel selbst ein.

## Regeln
Upload, Einreichung zur Prüfung und Veröffentlichung sind nicht umkehrbar. Vorher immer ausdrücklich nachfragen.
