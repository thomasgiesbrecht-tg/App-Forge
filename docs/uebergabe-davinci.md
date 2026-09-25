# Übergabe: DaVinci-Agenten über die Scripting-API

Stand: 25.09.2026 · Branch `claude/gallant-wozniak-t6beuu` · entstanden in einer Cloud-Session (ohne Xcode, ohne Resolve – **nichts davon ist gebaut oder in Resolve getestet**).

## Ziel
AppForge bekommt zwei Agenten, die DaVinci Resolve Studio **direkt über die Scripting-API** steuern (Python im Terminal), nicht über einen MCP:
- `davinci-color` – Color-Page
- `davinci-fusion` – Fusion-Page

Resolve Studio läuft auf **demselben Mac** wie AppForge. Standard-Freigabemodus in AppForge bleibt **„Automatisch“**.

## Entscheidungen und Gründe
- **Nativer MCP (Resolve Studio 21.1, seit 08.09.2026, *File → Setup AI Assistants*)**: Blackmagic nennt Projekte, Media Pool, Timelines, Farbe, Fairlight, Render/Export – Fusion wird nicht als eigener Bereich genannt, wohl aber „Skripte erstellen und ausführen“. Der MCP baut auf der Scripting-API auf.
- **Deshalb Scripting-API statt MCP:**
  - günstiger: keine MCP-Werkzeugbeschreibungen in jedem Schritt, ein Skript erledigt Lesen, Ändern und Prüfen in einem Aufruf;
  - vollständiger: Fusion ist per API voll erreichbar;
  - funktioniert mit jedem Modell in AppForge.
- **Grenzen (gelten für API und MCP gleich):** Farbräder, Kurven, Qualifier und Windows lassen sich nicht einstellen, neue Nodes nicht frei anlegen. Ausweg: CDL, LUT/DCTL, PowerGrades (DRX). Seit 21.1 laufen Python und die externe API nur in Studio.

## Änderungen im Code
1. `AppForge/Engine/AgentLibrary.swift` – neue Vorlagen `Template.davinciColor` und `Template.davinciFusion` (unter *Neuer Agent*). Rechte: Dateien bearbeiten ✓, Befehle ausführen ✓, delegieren ✗, **kein** Konnektor. Die Anweisungen verweisen auf den Skill `davinci-scripting`. Die alte Vorlage `davinci` ist unverändert.
2. `AppForge/Resources/Skills/skill-davinci-scripting.md` – neuer Skill, wird von `EngineConfig.installBundledSkills()` nach `skills/davinci-scripting/SKILL.md` kopiert. Er enthält:
   - Voraussetzungen und Grundgerüst: `DaVinciResolveScript` per Heredoc, Umgebungsvariablen für macOS, optional `RESOLVE_HOST`;
   - Prüf-Rezepte, darunter die Sichtprüfung per `ExportCurrentFrameAsStill`;
   - Aufrufe für Color und Fusion;
   - die Grenzen der API und den Lua-Ausweg für die kostenlose Version;
   - Sicherheitsregeln.
3. `AppForge/Store/PermissionMode.swift` – `riskyPatterns` ergänzt:
   - der Marker `DAVINCI_FREIGABE=1`;
   - zerstörerische Resolve-Aufrufe (`Delete…`, `ResetAllGrades`, `StartRendering`, `CloseProject`).
   
   Damit fragt AppForge auch im Modus „Automatisch“ nach. Der Skill verpflichtet die Agenten, riskante Skripte mit `DAVINCI_FREIGABE=1 python3 - <<'PY'` zu starten.

## Offene Punkte – bitte lokal erledigen
1. **Bauen:** `xcodebuild -project AppForge.xcodeproj -scheme AppForge build` (oder `scripts/installieren.sh`) und alle Fehler und Warnungen beheben.
2. **API-Namen gegen die echte Doku prüfen:** `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/README.txt` (Resolve 21.1 bringt 20 neue Aufrufe). Im Skill besonders prüfen:
   - `ExportCurrentFrameAsStill`, `GetNodeGraph().SetLUT`, `SetCDL`-Format, `ExportStills(..., "drx")`;
   - die Settings-Schlüssel `colorScienceMode`, `colorSpaceTimeline`, `colorSpaceOutput`;
   - die Fusion-Aufrufe `AddTool("Blur", -32768, -32768)`, `ConnectInput`, `AddModifier` und `XBlurSize.SetExpression`.
   
   Abweichungen im Skill korrigieren.
3. **Verbindungstest:** In Resolve *Einstellungen → System → Allgemein → External scripting using* auf **Local** stellen, Projekt öffnen, dann das Grundgerüst aus dem Skill (Abschnitt 2) im Terminal ausführen. Erwartet wird JSON mit Version, Seite, Projekt und Timeline.
4. **Freigabe-Sicherung prüfen:** Klären, ob OpenCode bei `bash`-Freigaben den Heredoc-Inhalt in `patterns` mitschickt oder nur die erste Zeile (`python3 - <<'PY'`). Falls nur die erste Zeile: Die Namens-Muster greifen nicht, nur der Marker. Ggf. zusätzlich `request.metadata` auswerten (`AppStore.swift`, Fall `.permissionAsked`).
5. **Praxistest in AppForge:**
   - Beide Vorlagen anlegen.
   - `davinci-color` fragen: „Prüf, welches Projekt und welche Timeline offen sind und wie das Color Management eingestellt ist.“
   - `davinci-fusion`: „Lege auf dem aktuellen Clip eine Fusion-Comp mit Blur zwischen MediaIn und MediaOut an.“
   - Ein Lösch-Skript muss die Freigabe-Leiste zeigen.
6. Wenn alles läuft: Pull Request von `claude/gallant-wozniak-t6beuu` nach `main`.

## Prompt für den lokalen Chat
> Hol den Branch `claude/gallant-wozniak-t6beuu` (`git fetch && git checkout claude/gallant-wozniak-t6beuu`) und lies `docs/uebergabe-davinci.md`. Arbeite die offenen Punkte 1–5 ab: bauen, API-Namen im Skill gegen die README.txt der installierten Resolve-Version prüfen, Verbindung zu Resolve Studio testen, die Freigabe-Sicherung prüfen und die beiden DaVinci-Agenten in AppForge ausprobieren. Korrigiere, was nicht stimmt, committe auf denselben Branch und berichte, was funktioniert und was nicht.
