#!/bin/zsh
# Assembla la versione autosufficiente di "AnimeUnity Downloader.app":
# incorpora un Python portatile, le dipendenze e il codice del progetto,
# poi produce un DMG pronto da distribuire. Chi la riceve non deve
# installare Python né altro.
#
# Uso:  ./make_dist.sh
# Richiede una connessione a internet (scarica il Python portatile).
set -e

PROJECT="/Users/lorenzopecorale/Library/Application Support/AnimeUnityDownloader"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$HERE/dist"
APP="$STAGE/AnimeUnity Downloader.app"
PYVER="3.12.13"
PYTAG="20260718"
PYURL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTAG}/cpython-${PYVER}+${PYTAG}-aarch64-apple-darwin-install_only.tar.gz"

echo "▸ Pulizia area di lavoro"
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "▸ Copio la struttura dell'app"
cp -R "/Applications/AnimeUnity Downloader.app" "$APP"
# La versione distribuibile non usa un percorso di sviluppo salvato
rm -f "$APP/Contents/Resources/project_path.txt"
rm -rf "$APP/Contents/Resources/python" "$APP/Contents/Resources/app"

echo "▸ Scarico il Python portatile (se non in cache)"
CACHE="$HERE/.python_cache.tar.gz"
if [ ! -f "$CACHE" ]; then
  curl -sL --max-time 240 -o "$CACHE" "$PYURL"
fi
mkdir -p "$APP/Contents/Resources"
tar xzf "$CACHE" -C "$APP/Contents/Resources"
# rinomina cpython.../ → python/
mv "$APP/Contents/Resources/python" "$APP/Contents/Resources/python" 2>/dev/null || true

PY="$APP/Contents/Resources/python/bin/python3"

echo "▸ Installo le dipendenze nel Python incorporato"
"$PY" -m pip install --quiet --disable-pip-version-check \
  -r "$PROJECT/requirements.txt"

echo "▸ Copio il codice del progetto nel bundle"
APPDIR="$APP/Contents/Resources/app"
mkdir -p "$APPDIR"
cp "$PROJECT/gui.py" "$PROJECT/gui_page.html" "$PROJECT/anime_downloader.py" \
   "$PROJECT/requirements.txt" "$PROJECT/README.md" "$PROJECT/LICENSE" "$APPDIR/"
cp -R "$PROJECT/src" "$APPDIR/src"
# pulizia cache Python del progetto
find "$APPDIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

echo "▸ Alleggerisco (test e cache non necessari)"
find "$APP/Contents/Resources/python" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "$APP/Contents/Resources/python/lib/python3.12/test" 2>/dev/null || true

echo "▸ Firmo il bundle completo (ad-hoc)"
codesign --force --deep -s - "$APP" 2>/dev/null

echo "▸ Creo il DMG"
DMG="$STAGE/AnimeUnity-Downloader.dmg"
rm -f "$DMG"
DMGROOT="$STAGE/dmgroot"
rm -rf "$DMGROOT"; mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
hdiutil create -quiet -volname "AnimeUnity Downloader" \
  -srcfolder "$DMGROOT" -ov -format UDZO "$DMG"
rm -rf "$DMGROOT"

echo ""
echo "✅ Fatto."
echo "   App:  $APP"
echo "   DMG:  $DMG  ($(du -h "$DMG" | cut -f1))"
