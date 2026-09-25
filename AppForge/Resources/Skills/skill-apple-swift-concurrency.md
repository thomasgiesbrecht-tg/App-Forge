---
name: apple-swift-concurrency
description: Swift 6 / 6.2+ Concurrency korrekt anwenden und Data-Race-Fehler beheben – MainActor, actors, Sendable, @concurrent, Tasks, Approachable Concurrency. Verwenden bei async/await-Code, Hintergrundarbeit oder Concurrency-Compilerfehlern.
---

# Swift Concurrency (Swift 6+)

## Zuerst prüfen
- Swift-Sprachversion (5 oder 6) und `SWIFT_STRICT_CONCURRENCY`.
- Ob `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` bzw. Approachable Concurrency aktiv ist. Dann ist Code standardmäßig auf dem MainActor, und `nonisolated async`-Funktionen laufen im Kontext des Aufrufers.

## Grundregeln
- UI-Typen (Views, ViewModels, `@Observable`-Stores): `@MainActor`.
- Geteilter veränderlicher Zustand: `actor` oder `@MainActor`, nie ungeschützte globale `var`.
- Teure Arbeit vom MainActor holen: `@concurrent func` (Swift 6.2+) oder eine Funktion in einem `actor`.
- Werte zwischen Isolationsbereichen: bevorzugt `struct`/`enum` mit `Sendable`. `@unchecked Sendable` nur mit Lock und Begründung.
- Strukturierte Concurrency (`async let`, `withTaskGroup`) vor losen `Task {}`.
- `Task.detached` vermeiden, außer es gibt einen klaren Grund.
- In SwiftUI `.task {}` statt `onAppear { Task {} }`: Er wird automatisch abgebrochen.

## Häufige Fehler → Lösung
| Fehler | Lösung |
|---|---|
| „Main actor-isolated property … from nonisolated context“ | Aufrufer `@MainActor` machen oder `await MainActor.run {}` |
| „Sending … risks causing data races“ | Wert kopieren/`Sendable` machen oder Isolation angleichen |
| „Static property … is not concurrency-safe“ | `let` statt `var`, `@MainActor` oder `nonisolated(unsafe)` nur als letzter Ausweg |
| Protokoll-Konformität auf MainActor-Typ | isolierte Konformität: `extension Foo: @MainActor Proto` |
| Delegates/Callbacks alter APIs | `@preconcurrency import` oder `MainActor.assumeIsolated` mit Bedacht |

## Vorgehen
Kleinste sichere Änderung → bauen → keine neuen Warnungen → Tests laufen lassen.
