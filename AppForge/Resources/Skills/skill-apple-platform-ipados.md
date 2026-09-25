---
name: apple-platform-ipados
description: Richtlinien für iPad-Apps (iPadOS) – NavigationSplitView, Size Classes, Multitasking, Stage Manager, Fenster/Szenen, Tastatur, Trackpad und Apple Pencil. Verwenden bei iPad-spezifischer UI oder beim Anpassen einer iPhone-App ans iPad.
---

# iPad (iPadOS)

## Layout
- `NavigationSplitView` statt einer gestreckten iPhone-Oberfläche.
- Auf `horizontalSizeClass` reagieren: Im Split View oder in schmalen Fenstern ist sie `.compact`.
- Frei skalierbare Fenster (Stage Manager, neue iPadOS-Fenster): keine festen Breiten, Inhalte fließend anordnen.
- Maximale Lesebreite für Text begrenzen.

## Eingabe
- Tastaturkürzel mit `.keyboardShortcut` und Menüs über `.commands`.
- Trackpad/Pointer: `.hoverEffect`, Kontextmenüs mit `.contextMenu`.
- Drag & Drop: `.draggable` / `.dropDestination`.
- Apple Pencil: PencilKit bzw. `.onPencilSqueeze`, wo sinnvoll.

## Szenen
- Mehrere Fenster: `WindowGroup` mit Werten, `openWindow`.
- Zustand pro Szene mit `@SceneStorage`.

## Prüfen
iPad-Simulator in voller Größe, Split View (⅓ und ½), Hoch- und Querformat.
