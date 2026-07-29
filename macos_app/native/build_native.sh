#!/bin/zsh
# Compila l'interfaccia nativa SwiftUI (Liquid Glass) e la installa in
# /Applications come "Vault.app", accanto — non al posto —
# dell'app storica "AnimeUnity Downloader.app".
#
# Richiede macOS 26 e i Command Line Tools (non serve Xcode).
# Uso:  ./build_native.sh

set -e
cd "$(dirname "$0")"

PROGETTO="$(cd ../.. && pwd)"          # cartella che contiene gui.py
APP="/Applications/Vault.app"

echo "Compilo…"
swiftc -O -parse-as-library -o GlassApp GlassApp.swift

echo "Impacchetto…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp GlassApp "$APP/Contents/MacOS/GlassApp"

# Dice all'app dove trovare gui.py (l'app è in /Applications, il progetto no).
printf '%s' "$PROGETTO" > "$APP/Contents/Resources/project_path.txt"

# Icona di Vault (sorgente in assets/Icona.swift, rigenerabile).
ICONA="assets/AppIcon.icns"
[ -f "$ICONA" ] && cp "$ICONA" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Vault</string>
  <key>CFBundleDisplayName</key><string>Vault</string>
  <key>CFBundleIdentifier</key><string>local.vault.app</string>
  <key>CFBundleExecutable</key><string>GlassApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST

# La firma ad-hoc serve perché macOS accetti l'app senza avvisi ripetuti.
codesign --force --deep -s - "$APP"

echo "Fatto: $APP"
echo "Motore di download atteso in: $PROGETTO"
