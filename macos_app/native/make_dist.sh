#!/bin/zsh
# Assembla la versione autosufficiente di Vault e ne produce un DMG.
#
# Il pacchetto contiene tutto il necessario: un Python portatile con le
# dipendenze di entrambi i progetti, il codice dell'app, i binari (ffmpeg,
# ffprobe, yt-dlp) e una copia pulita di VibraVid clonata da GitHub.
# Chi lo riceve non deve installare nulla.
#
# Uso:  ./make_dist.sh
# Richiede una connessione a internet.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROGETTO="$(cd "$HERE/../.." && pwd)"
STAGE="$HERE/dist"
APP="$STAGE/Vault.app"

PYVER="3.12.13"
PYTAG="20260718"
PYURL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTAG}/cpython-${PYVER}+${PYTAG}-aarch64-apple-darwin-install_only.tar.gz"
VIBRAVID_REPO="https://github.com/AstraeLabs/VibraVid.git"
MANGAWORLD_REPO="https://github.com/Lysagxra/MangaWorldDownloader.git"

echo "▸ Compilo l'app"
"$HERE/build_native.sh" >/dev/null

echo "▸ Preparo l'area di lavoro"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "/Applications/Vault.app" "$APP"
# La versione distribuibile non punta a un percorso di sviluppo.
rm -f "$APP/Contents/Resources/project_path.txt"
rm -rf "$APP/Contents/Resources/python" "$APP/Contents/Resources/app" \
       "$APP/Contents/Resources/vibravid" "$APP/Contents/Resources/mangaworld"

echo "▸ Incorporo il Python portatile"
CACHE="$HERE/../.python_cache.tar.gz"
[ -f "$CACHE" ] || curl -sL --max-time 300 -o "$CACHE" "$PYURL"
tar xzf "$CACHE" -C "$APP/Contents/Resources"
PY="$APP/Contents/Resources/python/bin/python3"

echo "▸ Copio il codice dell'app"
APPDIR="$APP/Contents/Resources/app"
mkdir -p "$APPDIR"
cp "$PROGETTO/gui.py" "$PROGETTO/gui_page.html" "$PROGETTO/anime_downloader.py" \
   "$PROGETTO/ytdlp_downloads.py" "$PROGETTO/vibravid_downloads.py" \
   "$PROGETTO/mangaworld_downloads.py" "$PROGETTO/mangaworld_driver.py" \
   "$PROGETTO/app_update.py" \
   "$PROGETTO/requirements.txt" "$PROGETTO/LICENSE" "$APPDIR/"
cp -R "$PROGETTO/src" "$APPDIR/src"
# ffmpeg, ffprobe e yt-dlp: VibraVid li cerca nel PATH e senza si rifiuta di partire.
cp -R "$PROGETTO/tools" "$APPDIR/tools"

echo "▸ Clono VibraVid da GitHub"
# Clone superficiale e senza cronologia: serve il codice, non il repository.
git clone --depth 1 --quiet "$VIBRAVID_REPO" "$STAGE/vibravid-tmp"
rm -rf "$STAGE/vibravid-tmp/.git" "$STAGE/vibravid-tmp/.github" \
       "$STAGE/vibravid-tmp/docker" "$STAGE/vibravid-tmp/Test"
# Le credenziali restano vuote: chi installa userà le proprie, se vorrà.
mv "$STAGE/vibravid-tmp" "$APP/Contents/Resources/vibravid"

echo "▸ Clono MangaWorld da GitHub"
git clone --depth 1 --quiet "$MANGAWORLD_REPO" "$STAGE/mangaworld-tmp"
rm -rf "$STAGE/mangaworld-tmp/.git" "$STAGE/mangaworld-tmp/.github" \
       "$STAGE/mangaworld-tmp/assets"
mv "$STAGE/mangaworld-tmp" "$APP/Contents/Resources/mangaworld"

echo "▸ Installo le dipendenze (progetto + VibraVid + MangaWorld) nello stesso Python"
# Un file alla volta, non tutti insieme. I tre progetti fissano versioni
# esatte e a volte discordi della stessa libreria — VibraVid vuole
# beautifulsoup4==4.14.3, MangaWorld ==4.15.0 — e pip, ricevendoli in un'unica
# invocazione, si ferma con "ResolutionImpossible" senza installare nulla.
# Risolvendoli uno per uno vince l'ultimo, e sono versioni compatibili fra
# loro: quel che conta è che il pacchetto venga prodotto.
#
# brotlicffi non è nei requirements di MangaWorld ma senza non funziona nulla:
# mangaworld.ac risponde in Brotli e aiohttp, col pacchetto Brotli di Google,
# chiama process(data, max_length) su un'API che accetta un argomento solo.
# Fallisce con "Can not decode content-encoding: br" a ogni download.
for REQ in "$PROGETTO/requirements.txt" \
           "$APP/Contents/Resources/vibravid/requirements.txt" \
           "$APP/Contents/Resources/mangaworld/requirements.txt"; do
  "$PY" -m pip install --quiet --disable-pip-version-check -r "$REQ"
done
"$PY" -m pip install --quiet --disable-pip-version-check brotlicffi

echo "▸ Alleggerisco il pacchetto"
find "$APP/Contents/Resources" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "$APP/Contents/Resources/python/lib/python3.12/test" 2>/dev/null || true
rm -rf "$APP/Contents/Resources/vibravid/Video" 2>/dev/null || true

echo "▸ Firmo il bundle"
codesign --force --deep -s - "$APP" 2>/dev/null

echo "▸ Creo il DMG"
DMG="$STAGE/Vault.dmg"
DMGROOT="$STAGE/dmgroot"
rm -rf "$DMGROOT"; mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
hdiutil create -quiet -volname "Vault" -srcfolder "$DMGROOT" -ov -format UDZO "$DMG"
rm -rf "$DMGROOT"

echo ""
echo "✅ Fatto."
echo "   App:  $APP"
echo "   DMG:  $DMG  ($(du -h "$DMG" | cut -f1))"
