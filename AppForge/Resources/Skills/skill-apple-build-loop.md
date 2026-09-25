---
name: apple-build-loop
description: Build-, Run- und Test-Schleife für Xcode-Projekte und Swift Packages (iOS, iPadOS, macOS) mit XcodeBuildMCP, Xcode-MCP oder xcodebuild. Verwenden, sobald Code gebaut, gestartet, getestet oder ein Build-Fehler behoben werden soll.
---

# Build-Schleife für Apple-Plattformen

## 1. Projekt erkennen
- `.xcworkspace` vor `.xcodeproj` bevorzugen, sonst `Package.swift`.
- Schemes auflisten (XcodeBuildMCP `list_schemes` oder `xcodebuild -list`).
- Deployment Target und Swift-Version aus den Build Settings lesen, bevor du APIs wählst.

## 2. Ziel wählen
| Plattform | Ziel |
|---|---|
| iPhone | aktueller iPhone-Simulator (`list_sims`, gebooteten bevorzugen) |
| iPad | aktueller iPad-Simulator (z. B. iPad Pro 13") |
| Mac | `platform=macOS` |

Mit XcodeBuildMCP zuerst `session-set-defaults` (projectPath/workspacePath, scheme, simulatorId) setzen.

## 3. Bauen und Fehler beheben
1. Bauen (`build_sim`, `build_macos` bzw. `xcodebuild build -scheme S -destination '...' -quiet`).
2. Nur die **ersten** Fehler lesen: Folgefehler verschwinden oft mit dem ersten Fix.
3. Ursache beheben, erneut bauen. Wiederholen, bis 0 Fehler.
4. Warnungen zu Concurrency ernst nehmen (Skill `apple-swift-concurrency`).

Terminal-Rückfall:
```bash
xcodebuild -scheme "App" -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -E "error:|warning:" | head -30
```

## 4. Starten und prüfen
- `build_run_sim` / `build_run_macos`, danach `screenshot` oder `describe_ui`.
- Logs: `start_sim_log_cap` → Aktion → `stop_sim_log_cap`.
- UI-Interaktion: erst `describe_ui`, dann `tap` über Label/ID, Koordinaten nur als Notlösung.

## 5. Testen
- `test_sim` / `test_macos` bzw. `xcodebuild test`; Swift Packages: `swift test`.
- Neue Tests mit Swift Testing (`import Testing`, `@Test`, `#expect`).

## Regeln
- Nach jeder Änderung bauen, bevor du „fertig“ sagst.
- Keine Simulatoren löschen oder zurücksetzen und nichts an Signing ändern, ohne zu fragen.
