---
name: apple-swiftui-patterns
description: Moderne SwiftUI-Architektur – @Observable, State-Management, Navigation, Listen, Formulare, SwiftData, Previews, Performance und Barrierefreiheit. Verwenden beim Bauen oder Umbauen von SwiftUI-Screens.
---

# SwiftUI-Muster

## State
- `@State` für lokalen View-Zustand, auch für `@Observable`-Objekte, die die View besitzt.
- `@Observable final class` für geteilte Modelle; über `.environment(model)` weitergeben, mit `@Environment(Model.self)` lesen.
- `@Bindable` für Bindings auf `@Observable`-Objekte.
- Kein `ObservableObject`/`@Published`/`@StateObject` in neuem Code.

## Navigation
- iPhone: `NavigationStack` mit `navigationDestination(for:)` und wertbasierten Pfaden.
- iPad/Mac: `NavigationSplitView` (Sidebar → Inhalt → Detail).
- Sheets über `.sheet(item:)` mit identifizierbarem Zustand statt vieler Bool-Flags.

## Daten
- SwiftData: `@Model`, `.modelContainer(for:)`, `@Query` in Views, `ModelContext` für Änderungen.
- Netzwerk: `async`-Funktionen, Aufruf in `.task(id:)`, Fehlerzustand sichtbar machen.

## Views
- Kleine, fokussierte Views, keine riesigen `body`.
- `ContentUnavailableView` für leere Zustände, `LabeledContent`, `Form` mit `.formStyle(.grouped)`.
- SF Symbols, semantische Farben (`.primary`, `.secondary`, `.tint`) und Dynamic Type statt fester Schriftgrößen.
- `#Preview` für jede wichtige View, mit Beispieldaten.

## Barrierefreiheit
- Bedeutungsvolle `accessibilityLabel`s für Icon-Buttons.
- Dynamic Type bis zu den Accessibility-Größen testen und Kontrast beachten.

## Performance
- `LazyVStack`/`List` für lange Listen, stabile `id`s.
- Teure Berechnungen nicht in `body`.
