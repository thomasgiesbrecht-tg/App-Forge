#!/bin/zsh
# Baut AppForge als Release und installiert es nach /Applications (Finder: „Programme“).
# Eine laufende AppForge wird sauber beendet und danach neu gestartet.
set -euo pipefail

PROJEKT="${0:A:h:h}"
ZIEL="/Applications/AppForge.app"
BUILD="$PROJEKT/build/Release"

echo "▸ Baue Release …"
xcodebuild -project "$PROJEKT/AppForge.xcodeproj" -scheme AppForge -configuration Release \
  -derivedDataPath "$BUILD" build -quiet

lief=0
if pgrep -f "AppForge.app/Contents/MacOS/AppForge" >/dev/null; then
  lief=1
  echo "▸ Beende laufende AppForge …"
  osascript -e 'tell application id "com.captureworks.AppForge" to quit' || true
  for i in {1..20}; do pgrep -f "AppForge.app/Contents/MacOS/AppForge" >/dev/null || break; sleep 0.5; done
fi

echo "▸ Installiere nach $ZIEL …"
rm -rf "$ZIEL.neu"
ditto "$BUILD/Build/Products/Release/AppForge.app" "$ZIEL.neu"
rm -rf "$ZIEL"
mv "$ZIEL.neu" "$ZIEL"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$ZIEL" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--starten" || $lief -eq 1 ]]; then
  echo "▸ Starte AppForge …"
  open "$ZIEL"
fi
echo "✓ Fertig: $ZIEL"
