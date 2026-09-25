#!/bin/zsh
# Baut AppForge Companion und installiert die App auf dem eigenen iPhone –
# bereits mit dem Mac gekoppelt (kein QR-Code, kein Anmelden).
#
#   scripts/iphone-installieren.sh            → auf das angeschlossene iPhone
#   scripts/iphone-installieren.sh --nur-bauen → nur bauen (z. B. wenn das iPhone gerade nicht erreichbar ist)
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="$HOME/Library/Application Support/AppForge/companion.key"
KOPPLUNG="Companion/App/kopplung.txt"
BUILD="build/Companion"

if [[ ! -f "$KEY" ]]; then
    echo "✗ Kein Mac-Schlüssel gefunden. Starte AppForge einmal – der Schlüssel entsteht beim ersten Start."
    exit 1
fi

# Kopplung einbauen: dieselben Angaben wie im QR-Code unter Einstellungen → iPhone.
NAME=$(scutil --get ComputerName)
HOST=$(defaults read com.captureworks.AppForge companion.remoteHost 2>/dev/null || true)
python3 - "$KEY" "$NAME" "$HOST" > "$KOPPLUNG" <<'PY'
import base64, sys, urllib.parse
key = open(sys.argv[1], "rb").read()
query = {"key": base64.urlsafe_b64encode(key).decode().rstrip("="), "name": sys.argv[2], "port": "52819"}
if sys.argv[3]:
    query["host"] = sys.argv[3]
print("appforge-companion://pair?" + urllib.parse.urlencode(query, quote_via=urllib.parse.quote))
PY
chmod 600 "$KOPPLUNG"
echo "▸ Kopplung eingebaut für „$NAME“${HOST:+ (unterwegs: $HOST)}"

# Eigenes iPhone suchen
UDID=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
phones = [d for d in data.get("result", {}).get("devices", [])
          if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
          and d.get("hardwareProperties", {}).get("reality") == "physical"]
# Erreichbare iPhones zuerst (eingeschaltet und nicht „unavailable“)
phones.sort(key=lambda d: (d.get("connectionProperties", {}).get("tunnelState") == "unavailable",
                           d.get("deviceProperties", {}).get("bootState") != "booted"))
if phones:
    print(phones[0]["hardwareProperties"]["udid"])
' || true)

if [[ "${1:-}" == "--nur-bauen" || -z "$UDID" ]]; then
    [[ -z "$UDID" && "${1:-}" != "--nur-bauen" ]] && echo "▸ Kein iPhone gefunden – es wird nur gebaut."
    DEST="generic/platform=iOS"
else
    DEST="id=$UDID"
fi

echo "▸ Baue AppForge Companion …"
xcodebuild -project Companion/AppForgeCompanion.xcodeproj -scheme AppForgeCompanion -configuration Release \
    -destination "$DEST" -derivedDataPath "$BUILD" -allowProvisioningUpdates build -quiet

APP="$BUILD/Build/Products/Release-iphoneos/AppForgeCompanion.app"
if [[ "$DEST" == generic* ]]; then
    echo "✓ Gebaut: $APP"
    exit 0
fi

STATE=$(xcrun devicectl list devices 2>/dev/null | grep "$UDID" || true)
if [[ -z "$STATE" || "$STATE" == *unavailable* ]]; then
    echo "✓ Gebaut. Das iPhone ist gerade nicht erreichbar (entsperren, per Kabel oder im selben WLAN) – dann erneut ausführen."
    exit 0
fi

echo "▸ Installiere auf dem iPhone …"
xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null
xcrun devicectl device process launch --device "$UDID" com.captureworks.AppForge.Companion >/dev/null 2>&1 || true
echo "✓ Fertig: AppForge Companion ist auf dem iPhone und mit „$NAME“ verbunden."
