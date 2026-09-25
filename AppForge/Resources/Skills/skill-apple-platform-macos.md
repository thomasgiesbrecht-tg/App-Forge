---
name: apple-platform-macos
description: Richtlinien für Mac-Apps (macOS) – Fenster, Menüs, Toolbars, Settings, Tastaturkürzel, Sandbox und Entitlements, AppKit-Bridging, MenuBarExtra. Verwenden bei Mac-spezifischer UI oder Funktionen.
---

# Mac (macOS)

## Struktur
- `WindowGroup` fürs Hauptfenster, `Settings { }` für die Einstellungen (⌘,), `Window` für Einzelfenster, `MenuBarExtra` für Menüleisten-Apps.
- `NavigationSplitView` mit Sidebar (`.listStyle(.sidebar)`).
- Menüs mit `.commands { CommandGroup / CommandMenu }` und Tastaturkürzeln für alle Hauptaktionen.
- Toolbar: `.toolbar` mit passenden `placement`s, Suche mit `.searchable`.

## Konventionen
- Mindestgröße der Fenster setzen (`.frame(minWidth:minHeight:)`).
- Rechtsklick-Kontextmenüs, Drag & Drop, Mehrfachauswahl in Listen.
- Dateien über `.fileImporter` / `.fileExporter` oder das DocumentGroup-Modell.
- Keine iOS-Muster wie Tab Bars am unteren Rand.

## Sandbox & Rechte
- App Sandbox ist für den Mac App Store Pflicht. Benötigte Entitlements gezielt setzen (Netzwerk-Client, benutzergewählte Dateien …).
- Prozesse starten oder beliebige Dateien lesen geht nur ohne Sandbox bzw. mit passenden Entitlements.

## AppKit
- `NSViewRepresentable` nur für fehlende Funktionen, `NSWorkspace` für Finder/URLs, `NSPasteboard` für die Zwischenablage.

## Prüfen
Mit `platform=macOS` bauen, App starten, Fenster verkleinern und vergrößern, Hell- und Dunkelmodus prüfen, Menüs und Kürzel testen.
