---
name: motion-graphics
description: Motion Graphics und Animation – Titel, Logo-Reveals, Kinetic Typography, Erklärvideos, App-Promos, App-Store-Vorschauen, Social-Clips, Lower Thirds, Overlays mit Transparenz, Audio-Visualisierung, 3D-Titel und Animationen in SwiftUI-Apps. Mit Remotion (Code → Video), SwiftUI, Lottie, Blender und Simulator-Aufnahmen. Verwenden, sobald etwas animiert, gerendert oder als Video/GIF ausgegeben werden soll.
---

# Motion Graphics

## 1. Welches Werkzeug?

| Ziel | Werkzeug |
|---|---|
| Video (MP4, GIF), Titel, Intros, Promo, Erklärvideo, Social-Clip, App-Store-Vorschau | **Remotion** (React/TypeScript → Video). Standard. |
| Overlay für DaVinci Resolve / Final Cut (Lower Third, Titel, Logo-Bug) | Remotion mit **Transparenz** (ProRes 4444) |
| Animation *in* einer App (Übergänge, Buttons, Ladeanimation, Onboarding) | **SwiftUI** (nativ) – Lottie nur, wenn schon vorhanden |
| Echte App-Oberfläche zeigen | **Simulator-Aufnahme**, dann in Remotion einbauen (Gerät, Texte, Musik) |
| 3D-Titel, 3D-Logo, Produkt-Shot | **Blender** headless (falls installiert) oder `@remotion/three` |
| KI-Bild oder KI-Clip als Hintergrund | AppForge-Befehle `/foto` bzw. `/video` – die Nutzerin/der Nutzer ruft sie auf; schlage konkrete Prompts vor |

## 2. Gestaltung – das macht den Unterschied

**Timing**
- Video mit 30 fps (Social, Promo) oder 60 fps (UI-Demos, flüssige Bewegungen). 24 fps nur für den Filmlook.
- Text muss man lesen können: grob 3 Wörter pro Sekunde plus 1 Sekunde, mindestens 1,5 s stehen lassen.
- Einblenden 0,3–0,6 s, Szenenwechsel 0,3–0,5 s, Logo-Reveal 1–2 s. UI-Animationen in Apps 0,15–0,4 s.
- Rhythmus: Ereignisse auf Musik-Beats oder feste Raster legen (z. B. alle 15 Frames).

**Bewegung**
- Nichts bewegt sich linear. Hinein: *ease-out*, hinaus: *ease-in*, von A nach B: *ease-in-out* – oder Federn (`spring`).
- Federn als Tokens festlegen und überall gleich verwenden: *smooth* (ohne Überschwingen, für Text/UI), *snappy* (knackig), *bouncy* (verspielt, sparsam).
- **Staffelung** (stagger): Elemente mit 2–4 Frames Versatz statt gleichzeitig – wirkt sofort hochwertig.
- Animationsprinzipien: Antizipation (kurz ausholen), Nachschwingen (follow-through), Überlappen, eine Hauptbewegung pro Moment (staging), Nebenbewegungen leiser.
- Weniger ist mehr: pro Szene *eine* klare Aussage. Kamera-Drift (1–3 % Skalierung über die Szene) belebt Standbilder.
- Ausgänge nicht vergessen: Alles, was hereinkommt, verlässt die Bühne sauber (oder der Schnitt passiert auf Bewegung).

**Typografie & Layout**
- Höchstens zwei Schriften. Große Schrift, enges Laufweiten-Feintuning bei Headlines (−2 bis −4 %), genug Kontrast.
- Sicherheitsränder: 5 % rundum; bei 9:16-Social oben ~12 % und unten ~20 % frei (Bedienelemente der Apps).
- Raster und Ausrichtung konsequent; Werte relativ zur Bildbreite rechnen, dann funktionieren alle Formate.

**Marke**
- Farben, Schriften, Logo aus dem Projekt übernehmen (Asset-Katalog: AppIcon, AccentColor; Theme-Dateien) und in `theme.ts` zentral ablegen.

## 3. Formate

| Einsatz | Größe | Hinweise |
|---|---|---|
| YouTube, Präsentation | 1920×1080 (oder 3840×2160) | 16:9 |
| Reels, TikTok, Shorts, Story | 1080×1920 | 9:16, Sicherheitsränder beachten, meist ohne Ton gesehen → Untertitel |
| Instagram-Feed | 1080×1350 oder 1080×1080 | 4:5 bzw. 1:1 |
| App-Store-Vorschau iPhone | 886×1920 hochkant (6,9"/6,5") bzw. 1080×1920 (5,5") | 15–30 s, 30 fps. **Vor dem Hochladen die aktuellen Vorgaben in der App-Store-Connect-Hilfe prüfen.** |
| GIF für Readme/Chat | 480–800 px breit | `--codec=gif --every-nth-frame=2` |

Mehrere Formate = mehrere `<Composition>` mit derselben Szene; Layout aus `width`/`height` berechnen.

## 4. Remotion

Kostenlos für Einzelpersonen und Firmen bis 3 Personen, darüber Firmenlizenz (remotion.dev/license). Braucht Node.js ≥ 18; ffmpeg und Chrome bringt Remotion selbst mit.

### Projekt anlegen (getestet mit Remotion 4.0.529)
Ordner: in einem App-Projekt `Motion/` im Projektordner (nicht in einen Xcode-Zielordner legen); ohne Projekt `~/Movies/AppForge Motion/<name>/`.
Ist schon ein Motion-Projekt da, dort weitermachen (neue Kompositionen ergänzen).

`package.json` – **alle `@remotion/*`-Pakete exakt gleiche Version wie `remotion`**:
```json
{
  "name": "motion",
  "private": true,
  "type": "module",
  "scripts": { "studio": "remotion studio", "render": "remotion render", "still": "remotion still" },
  "dependencies": {
    "@remotion/cli": "4.0.529",
    "@remotion/google-fonts": "4.0.529",
    "@remotion/transitions": "4.0.529",
    "@remotion/paths": "4.0.529",
    "@remotion/shapes": "4.0.529",
    "react": "19.1.1",
    "react-dom": "19.1.1",
    "remotion": "4.0.529",
    "zod": "3.25.76"
  },
  "devDependencies": { "@types/react": "19.1.12", "typescript": "5.9.2" }
}
```
Zusatzpakete bei Bedarf in derselben Version: `@remotion/media-utils` (Audio-Visualisierung), `@remotion/noise`, `@remotion/layout-utils` (`fitText`), `@remotion/motion-blur`, `@remotion/lottie`, `@remotion/three` (+ `three`, `@react-three/fiber`), `@remotion/captions`.

`tsconfig.json`
```json
{ "compilerOptions": { "target": "ES2022", "module": "ESNext", "moduleResolution": "Bundler", "jsx": "react-jsx",
  "strict": true, "skipLibCheck": true, "noEmit": true }, "include": ["src"] }
```

`remotion.config.ts`
```ts
import { Config } from "@remotion/cli/config";
Config.setVideoImageFormat("jpeg");
Config.setOverwriteOutput(true);
Config.setEntryPoint("src/index.ts");
```

`src/index.ts`
```ts
import { registerRoot } from "remotion";
import { Root } from "./Root";
registerRoot(Root);
```

`src/theme.ts` – Marke und Bewegung an einer Stelle
```ts
import { loadFont } from "@remotion/google-fonts/Inter";
const { fontFamily } = loadFont("normal", { weights: ["400", "700", "800"], subsets: ["latin"] });

export const theme = {
  colors: { background: "#000000", surface: "#141414", text: "#F2F2F0", muted: "#8C8C8C", accent: "#4CD97B" },
  font: fontFamily,
  spring: {
    smooth: { damping: 200 },
    snappy: { damping: 20, stiffness: 200 },
    bouncy: { damping: 8 },
  },
} as const;
```

`src/Root.tsx` – Texte als Props (mit zod-Schema → im Studio bearbeitbar, per `--props` austauschbar)
```tsx
import { Composition } from "remotion";
import { Title, titleSchema } from "./scenes/Title";

export const Root: React.FC = () => (
  <>
    <Composition id="Title" component={Title} durationInFrames={120} fps={30} width={1920} height={1080}
      schema={titleSchema} defaultProps={{ title: "AppForge", subtitle: "Apps schmieden mit KI" }} />
    <Composition id="TitleVertical" component={Title} durationInFrames={120} fps={30} width={1080} height={1920}
      schema={titleSchema} defaultProps={{ title: "AppForge", subtitle: "Apps schmieden mit KI" }} />
  </>
);
```

`src/scenes/Title.tsx` – Beispiel: Linie zeichnet sich, Buchstaben federn gestaffelt herein, sauberer Ausgang
```tsx
import { AbsoluteFill, Easing, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { evolvePath } from "@remotion/paths";
import { z } from "zod";
import { theme } from "../theme";

export const titleSchema = z.object({ title: z.string(), subtitle: z.string() });

export const Title: React.FC<z.infer<typeof titleSchema>> = ({ title, subtitle }) => {
  const frame = useCurrentFrame();
  const { fps, width, durationInFrames } = useVideoConfig();
  const size = Math.round(width * 0.09);
  const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

  const line = evolvePath(interpolate(frame, [0, 24], [0, 1], { ...clamp, easing: Easing.out(Easing.cubic) }), "M 0 0 L 600 0");
  const subtitleIn = interpolate(frame, [30, 50], [0, 1], clamp);
  const out = interpolate(frame, [durationInFrames - 15, durationInFrames], [1, 0], { ...clamp, easing: Easing.in(Easing.cubic) });

  return (
    <AbsoluteFill style={{ backgroundColor: theme.colors.background, justifyContent: "center", alignItems: "center",
                           fontFamily: theme.font, opacity: out }}>
      <div style={{ display: "flex", fontSize: size, fontWeight: 800, color: theme.colors.text, letterSpacing: -size * 0.03 }}>
        {title.split("").map((char, i) => {
          const p = spring({ frame: frame - 6 - i * 2, fps, config: theme.spring.snappy });
          return <span key={i} style={{ display: "inline-block", opacity: p,
                   transform: `translateY(${(1 - p) * size * 0.6}px)` }}>{char === " " ? " " : char}</span>;
        })}
      </div>
      <svg width={600} height={8} viewBox="0 -4 600 8" style={{ marginTop: size * 0.2 }}>
        <path d="M 0 0 L 600 0" stroke={theme.colors.accent} strokeWidth={6} strokeLinecap="round"
              strokeDasharray={line.strokeDasharray} strokeDashoffset={line.strokeDashoffset} />
      </svg>
      <div style={{ marginTop: size * 0.25, fontSize: size * 0.32, color: theme.colors.muted, opacity: subtitleIn,
                    transform: `translateY(${(1 - subtitleIn) * 20}px)` }}>{subtitle}</div>
    </AbsoluteFill>
  );
};
```
Dann `npm install` und `npx tsc -p .` (Typprüfung) – erst danach rendern.

### Bausteine
- Zeit: `useCurrentFrame()`, `useVideoConfig()` (`fps`, `width`, `height`, `durationInFrames`). In Sekunden denken: `frame / fps`.
- Werte: `interpolate(frame, [a, b], [von, bis], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing })`,
  `interpolateColors(frame, [a, b], ["#000", "#4CD97B"])`, `Easing.bezier(0.2, 0, 0, 1)`.
- Federn: `spring({ frame: frame - delay, fps, config: { damping, stiffness, mass }, durationInFrames })` → 0…1.
- Ablauf: `<Sequence from={30} durationInFrames={60}>`, `<Series><Series.Sequence durationInFrames={90}>…`, `<Loop>`, `<Freeze frame={…}>`.
- Übergänge: `import { TransitionSeries, linearTiming, springTiming } from "@remotion/transitions"` plus
  `fade` aus `@remotion/transitions/fade`, `slide` aus `…/slide`, `wipe`, `flip`, `clockWipe`:
  `<TransitionSeries.Sequence durationInFrames={60}>…</TransitionSeries.Sequence><TransitionSeries.Transition presentation={slide({ direction: "from-right" })} timing={springTiming({ config: { damping: 200 } })} />`
  (Gesamtlänge = Summe der Szenen minus Übergänge).
- Medien: Dateien in `public/`, einbinden mit `staticFile("logo.png")` → `<Img>`, `<OffthreadVideo>`, `<Audio volume={(f) => …}>`.
- SVG: Pfad zeichnen mit `evolvePath` (`@remotion/paths`), Formen mit `@remotion/shapes`, organische Bewegung mit `noise2D` (`@remotion/noise`).
- Text einpassen: `fitText({ text, withinWidth, fontFamily, fontWeight })` aus `@remotion/layout-utils`.
- Musik-Sync: `useAudioData(src)` + `visualizeAudio({ fps, frame, audioData, numberOfSamples: 32 })` aus `@remotion/media-utils`.
- Bewegungsunschärfe: `<CameraMotionBlur shutterAngle={180} samples={8}>` aus `@remotion/motion-blur` – sparsam, kostet Renderzeit.
- Dynamische Länge (z. B. nach Audio): `calculateMetadata` an der `<Composition>`.
- Zufall immer deterministisch: `random("seed-" + i)` aus `remotion`, nie `Math.random()`.
- Transparenter Hintergrund: im Root keine Hintergrundfarbe setzen.

### Prüfen, bevor du fertig meldest
1. `npx tsc -p .` ohne Fehler.
2. Standbilder an den wichtigen Momenten: `npx remotion still <id> out/check-060.png --frame=60` (für jede Szene einen Frame, Anfang/Mitte/Ende).
3. Die Bilder **ansehen** (Datei lesen), wenn dein Modell Bilder versteht: Lesbarkeit, Ränder, Überlappungen, Abgeschnittenes, Kontrast. Sonst die Werte gegen die Regeln oben prüfen.
4. Für einen schnellen Blick auf den Ablauf: `npx remotion render <id> out/preview.gif --codec=gif --every-nth-frame=3 --scale=0.4`
   oder Einzelbilder `--sequence --image-format=jpeg --scale=0.25` (ergibt `element-000.jpeg` …).
   Hinweis: Das mitgelieferte `npx remotion ffmpeg` ist abgespeckt (kein `tile`/`fps`-Filter) – Kontaktbögen deshalb über Standbilder.

### Rendern
```bash
npx remotion render Title out/title.mp4                      # H.264, überall abspielbar
npx remotion render Title out/title.mp4 --crf=18             # höhere Qualität
npx remotion render Title out/title.mov --codec=prores --prores-profile=4444 \
  --pixel-format=yuva444p10le --image-format=png             # mit Transparenz → DaVinci / Final Cut
npx remotion render Title out/title.webm --codec=vp9 --pixel-format=yuva420p --image-format=png   # transparent fürs Web
npx remotion render Title out/title.gif --codec=gif --every-nth-frame=2 --scale=0.5
npx remotion render Title out/title-en.mp4 --props='{"title":"AppForge","subtitle":"Forge apps with AI"}'
npx remotion studio                                           # Vorschau und Feinschliff im Browser (am Mac)
```
Dateien in `out/` sprechend benennen (`<name>-<format>-<sprache>.mp4`). `node_modules/` und `out/` in `.gitignore`.

## 5. App-Store-Vorschau und Promo mit echter App
1. App im Simulator starten (Skill `apple-build-loop`), Statusleiste aufräumen:
   `xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3`
2. Aufnehmen: `xcrun simctl io booted recordVideo --codec=h264 --force Motion/public/aufnahme.mp4` (mit Ctrl-C bzw. Prozessende stoppen), dabei die Abläufe per XcodeBuildMCP-Tippen durchspielen.
3. In Remotion mit `<OffthreadVideo src={staticFile("aufnahme.mp4")} />` schneiden (`trimBefore`, `trimAfter` in Frames), Texte und Übergänge darüberlegen.
4. App-Store-Vorschauen dürfen nur echte App-Inhalte zeigen; Geräterahmen dort weglassen.

## 6. Animationen in SwiftUI-Apps
- Federn: `.spring(duration: 0.35, bounce: 0.15)`, Presets `.smooth`, `.snappy`, `.bouncy`; `withAnimation(.snappy) { … }`.
- Mehrstufig: `PhaseAnimator` (Phasen) und `KeyframeAnimator` (Keyframe-Spuren je Eigenschaft).
- Übergänge: `.transition(.push(from: .trailing))`, `.matchedGeometryEffect`, `.navigationTransition(.zoom(sourceID:in:))`.
- Zahlen/Text: `.contentTransition(.numericText())`; SF Symbols: `.symbolEffect(.bounce)`, `.pulse`, `.variableColor`, `.wiggle`, `.breathe`.
- Frei gezeichnet: `TimelineView(.animation)` + `Canvas` (Partikel, Wellen); `MeshGradient` für lebendige Hintergründe.
- Effekte: `.visualEffect { content, proxy in … }`, Metal-Shader über `.colorEffect`, `.distortionEffect`, `.layerEffect(ShaderLibrary.name(…))`.
- Immer `@Environment(\.accessibilityReduceMotion)` beachten: dann Überblenden statt Bewegung.
- Bewegungs-Tokens (Dauern, Federn) zentral im Theme der App, nicht verstreut.
- Lottie nur, wenn Animationen von außen kommen: Paket `https://github.com/airbnb/lottie-spm`, `LottieView(animation: .named("datei")).playing(loopMode: .loop)`.

## 7. 3D mit Blender (falls installiert)
- Programm: `/Applications/Blender.app/Contents/MacOS/Blender -b -P szene.py -- <argumente>` (ohne Oberfläche).
- Im Skript mit `bpy`: Szene leeren, Text (`bpy.ops.object.text_add`, `extrude`, `bevel_depth`), Materialien (Emission für Leuchten), Kamera und Licht anlegen,
  Keyframes mit `obj.keyframe_insert(data_path="location", frame=1)`, Interpolation auf Bezier.
- Renderer: `scene.render.engine` – verfügbare Namen mit `[e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items]` prüfen (EEVEE heißt je nach Version unterschiedlich).
- Transparenz: `scene.render.film_transparent = True`, PNG-Sequenz RGBA, danach in Remotion einbinden oder direkt ausgeben.
- Ist ein Blender-Konnektor (MCP) eingerichtet, kannst du stattdessen den benutzen.

## 8. Übergabe an Schnittprogramme
- DaVinci Resolve / Final Cut: ProRes 4444 mit Alpha (siehe Rendern) – einfach auf die Timeline ziehen.
- Ist ein DaVinci-Konnektor eingerichtet, kannst du Clips auch direkt ins Projekt legen.
- Ton: Remotion erzeugt keine Musik. Nutze Dateien der Nutzerin/des Nutzers aus `public/` oder rendere stumm (`--muted`) und sag, wo Ton hingehört. Lizenzen beachten.
