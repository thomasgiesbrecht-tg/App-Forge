---
name: apple-platform-ios
description: Richtlinien für iPhone-Apps (iOS) – Human Interface Guidelines, Navigation, Tab Bars, Safe Areas, Gesten, Tastatur, Berechtigungen und Info.plist-Schlüssel. Verwenden bei iPhone-spezifischer UI oder Funktionen.
---

# iPhone (iOS)

## Layout & Navigation
- `TabView` für 2–5 Hauptbereiche, `NavigationStack` pro Tab.
- Safe Areas respektieren und Inhalte nicht unter die Dynamic Island oder den Home-Indikator legen.
- Touch-Ziele mindestens 44 × 44 pt.
- Hoch- und Querformat prüfen, wenn das Target beides erlaubt.

## Eingabe
- Tastatur: `.keyboardType`, `.textContentType`, `.submitLabel`, `@FocusState`.
- Wischgesten: `.swipeActions` in Listen, `.refreshable` für Pull-to-Refresh.

## System
- Berechtigungen (Kamera, Fotos, Standort, Mikrofon …) brauchen einen `NS…UsageDescription`-Eintrag in der Info.plist oder den Build Settings (`INFOPLIST_KEY_…`), sonst stürzt die App ab.
- Haptik: `.sensoryFeedback`.
- Hintergrundarbeit nur mit passendem Background Mode.

## Prüfen
Auf einem kleinen (iPhone SE/mini) und einem großen Simulator (Pro Max), im Hell- und Dunkelmodus und mit großer Schrift.
