---
name: davinci-scripting
description: DaVinci Resolve Studio direkt über die Scripting-API steuern (Python im Terminal) – Verbindung, Prüfen, Color-Page, Fusion, Stills und die Grenzen der API. Verwenden, sobald ein Agent in Resolve etwas lesen, prüfen oder ändern soll.
---

# DaVinci Resolve über die Scripting-API

Alles läuft über kurze Python-Skripte im Terminal – kein MCP nötig. Das spart Tokens: Es gibt keine Werkzeugbeschreibungen im Kontext, und ein Skript erledigt viele Schritte in einem einzigen Aufruf.

## 1. Voraussetzungen
- **DaVinci Resolve Studio** läuft. Seit 21.1 sind die externe Scripting-API und Python nur noch in Studio verfügbar.
- Resolve → Einstellungen → System → Allgemein → „External scripting using“ (deutsch sinngemäß „Externes Scripting“) auf **Local/Lokal**.
- `python3` (kommt mit Xcode bzw. den Command Line Tools).
- Liefert `scriptapp` den Wert `None`, liegt es fast immer an einem der drei Punkte – sag dem Nutzer, welcher es ist.

### Resolve auf einem anderen Rechner
Läuft Resolve nicht auf dem Mac mit AppForge (z. B. auf einem PC, den der Nutzer fernsteuert):
- Auf dem Resolve-Rechner „External scripting using“ auf **Network** stellen und Resolve in dessen Firewall fürs lokale Netz freigeben.
- Auf dem Mac braucht Python trotzdem `fusionscript.so` – das kommt mit einer Resolve-Installation auf dem Mac (die kostenlose Version genügt vermutlich; beim ersten Mal prüfen).
- IP-Adresse beim Nutzer erfragen und als `export RESOLVE_HOST=…` vor das Skript setzen – das Grundgerüst verbindet sich dann dorthin.
- **Alle Pfade gelten auf dem Resolve-Rechner:** LUTs, exportierte Stills, Comp-Exporte und Einzelbilder landen dort, nicht auf dem Mac. Für die Sichtprüfung einen freigegebenen Ordner nutzen, den beide Rechner erreichen.

## 2. Grundgerüst
Führe Skripte als Heredoc aus: Der Nutzer sieht den ganzen Code in der Freigabe, und es bleiben keine Dateien liegen.

```bash
export RESOLVE_SCRIPT_API="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
export RESOLVE_SCRIPT_LIB="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
export PYTHONPATH="$PYTHONPATH:$RESOLVE_SCRIPT_API/Modules/"
python3 - <<'PY'
import json, os, sys
import DaVinciResolveScript as dvr
host = os.environ.get("RESOLVE_HOST")  # nur bei Resolve auf einem anderen Rechner
resolve = dvr.scriptapp("Resolve", host) if host else dvr.scriptapp("Resolve")
if not resolve:
    sys.exit("Keine Verbindung: Läuft Resolve Studio, und steht External scripting auf Local (bzw. Network)?")
project = resolve.GetProjectManager().GetCurrentProject()
timeline = project.GetCurrentTimeline() if project else None
out = {"version": resolve.GetVersionString(), "seite": resolve.GetCurrentPage(),
       "projekt": project.GetName() if project else None,
       "timeline": timeline.GetName() if timeline else None}
# … eigentliche Arbeit …
print(json.dumps(out, ensure_ascii=False))
PY
```

Regeln:
- **Viele Schritte in ein Skript.** Lesen, ändern und nachprüfen im selben Aufruf statt zehn einzelner Aufrufe.
- **Knapp ausgeben.** Nur das nötige JSON, keine kompletten Objekte oder Einstellungslisten.
- **Rückgabewerte prüfen.** Viele Aufrufe scheitern still und geben `None` oder `False` zurück – jedes Ergebnis auswerten und melden.
- Indizes sind **1-basiert** (Timelines, Spuren, Nodes, Fusion-Comps).
- Die Doku nicht komplett lesen, sondern gezielt durchsuchen: `grep -n -i "SetCDL" "$RESOLVE_SCRIPT_API/README.txt"`. Resolve 21.1 bringt 20 neue API-Aufrufe – bei Bedarf dort nachsehen.

## 3. Prüfen (nur lesen)
- Projekt und Timelines: `project.GetTimelineCount()`, `project.GetTimelineByIndex(i)`, `timeline.GetTrackCount("video")`, `timeline.GetItemListInTrack("video", n)`, `timeline.GetCurrentVideoItem()`, `timeline.GetCurrentTimecode()`.
- Einstellungen: `project.GetSetting("colorScienceMode")`, `project.GetSetting("colorSpaceTimeline")`, `project.GetSetting("colorSpaceOutput")` – Schlüssel ohne Treffer mit `grep` in der README suchen.
- Grade eines Clips: `item.GetNodeGraph()` → `GetNumNodes()`, `GetNodeLabel(i)`, `GetLUT(i)`, `GetToolsInNode(i)`; `item.GetVersionNameList(0)`, `item.GetColorGroup()`.
- Fusion: `item.GetFusionCompCount()`, `item.GetFusionCompNameList()`; in der Comp `comp.GetToolList(False)` und je Node `tool.GetAttrs("TOOLS_Name")` bzw. `tool.GetAttrs("TOOLS_RegID")`.
- **Sichtprüfung:** `project.ExportCurrentFrameAsStill(pfad + ".png")` legt ein Bild des aktuellen Frames ab, das du anschließend ansehen kannst. Nimm dafür einen Ordner im Projekt wie `.davinci/` (in `.gitignore` eintragen).

## 4. Color-Page
- Seite wechseln: `resolve.OpenPage("color")`.
- **Vorher sichern:** `item.AddVersion("vorher-<kurz>", 0)` oder `timeline.GrabStill()`.
- CDL: `item.SetCDL({"NodeIndex": "1", "Slope": "1.0 1.0 1.0", "Offset": "0 0 0", "Power": "1.0 1.0 1.0", "Saturation": "1.0"})`.
- LUT/DCTL: Datei in den LUT-Ordner legen, `project.RefreshLUTList()`, dann `item.GetNodeGraph().SetLUT(nodeIndex, pfad)`. Ob ein DCTL per `SetLUT` greift, erst an einem Test-Node prüfen.
- Übertragen: `quelle.CopyGrades([ziel1, ziel2])`; `timeline.ApplyGradeFromDRX(pfad, modus, [items])` (Modus 0 = ohne Keyframes, 1 = nach Quell-Timecode, 2 = nach Startframe).
- Export: `item.ExportLUT(resolve.EXPORT_LUT_33PTCUBE, pfad)`.
- Gruppen: `project.GetColorGroupsList()`, `project.AddColorGroup(name)`, `item.AssignToColorGroup(gruppe)`, `gruppe.GetPreClutNodeGraph()`, `gruppe.GetPostClutNodeGraph()`.
- Gallery: `project.GetGallery()` → `GetGalleryStillAlbums()`, `GetGalleryPowerGradeAlbums()`; Album `GetStills()`, `ExportStills(stills, ordner, präfix, "drx")`, `ImportStills([pfade])`.
- Weitere Aufrufe: `graph.SetNodeEnabled(i, True)`, `graph.ResetAllGrades()`, `item.CreateMagicMask("F")`.

**Grenzen:** Farbräder, Kurven, Qualifier und Windows lassen sich per API nicht einstellen, und neue Nodes lassen sich nicht frei anlegen. Das gilt genauso für den nativen MCP, denn der baut auf derselben API auf. Ausweichen auf CDL, LUT/DCTL und vorbereitete PowerGrades (DRX) – oder den Handgriff für den Nutzer genau beschreiben.

## 5. Fusion
```python
item = timeline.GetCurrentVideoItem()
comp = item.GetFusionCompByIndex(1) if item.GetFusionCompCount() > 0 else item.AddFusionComp()
comp.Lock(); comp.StartUndo("AppForge")
try:
    media_in = comp.FindTool("MediaIn1")
    media_out = comp.FindTool("MediaOut1")
    blur = comp.AddTool("Blur", -32768, -32768)   # -32768 = automatisch platzieren
    blur.SetAttrs({"TOOLS_Name": "Weichzeichner"})
    blur.ConnectInput("Input", media_in)
    blur.SetInput("XBlurSize", 4.0)
    media_out.ConnectInput("Input", blur)
    blur.AddModifier("XBlurSize", "BezierSpline")  # animieren:
    blur.SetInput("XBlurSize", 0.0, 0)
    blur.SetInput("XBlurSize", 8.0, 24)
finally:
    comp.EndUndo(True); comp.Unlock()
```
- Namen der Eingänge herausfinden: `[i.GetAttrs("INPS_ID") for i in tool.GetInputList().values()]`.
- Ausdrücke: `tool.<Eingang>.SetExpression("…")`, z. B. `blur.XBlurSize.SetExpression("time / 10")`; sparsam einsetzen.
- Neue Clips in der Timeline: `timeline.InsertFusionCompositionIntoTimeline()`, `timeline.InsertFusionTitleIntoTimeline("Text+")`, `timeline.InsertFusionGeneratorIntoTimeline(name)`, `timeline.CreateFusionClip([items])`.
- Größere Node-Bäume: als `.comp`-Datei schreiben und mit `item.ImportFusionComp(pfad)` laden.
- **Sichern:** vor Umbauten `item.ExportFusionComp(pfad, 1)`.
- Aktive Comp auf der Fusion-Page: `resolve.Fusion().GetCurrentComp()`.

## 6. Kostenlose Resolve-Version
Ohne Studio ist keine Verbindung von außen möglich. Dann bleibt nur Lua innerhalb von Resolve: Das Skript nach `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/<name>.lua` schreiben – der Nutzer startet es über Workspace → Scripts. Dort ist `resolve` direkt verfügbar (sonst `Resolve()`), Fusion über `resolve:Fusion()`.

## 7. Sicherheit
AppForge läuft meist im Modus „Automatisch“: Normale Skripte laufen ohne Rückfrage. Skripte mit riskanten Schritten beginnst du deshalb **immer** mit `DAVINCI_FREIGABE=1`, z. B. `DAVINCI_FREIGABE=1 python3 - <<'PY'` – dann zeigt AppForge dem Nutzer vorher die Freigabe. Trenne solche Schritte vom Rest, damit nur sie eine Freigabe brauchen.

Riskant sind: Löschen (Timelines, Clips, Versionen, Stills, Color-Gruppen, Comps, Nodes), Grades zurücksetzen oder auf viele Clips übertragen, Projekteinstellungen ändern, Projekte schließen und Renderaufträge starten. Vor größeren Änderungen `timeline.DuplicateTimeline(name)`, eine neue Grade-Version oder einen Comp-Export als Sicherung anlegen.
