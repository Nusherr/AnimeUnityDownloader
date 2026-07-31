"""Aggiornamento di Vault stessa — funzione OPZIONALE e ISOLATA.

Quando su GitHub compare una release con un tag più recente di quello inciso
nel pacchetto, l'app scarica il DMG, ne estrae la versione nuova e si fa
sostituire. Non si importa nulla da gui.py: si comunica per valori di ritorno.

Perché l'app si aggiorna da sola invece di aprire la pagina del browser
--------------------------------------------------------------------------
Gatekeeper blocca le app in quarantena, e la quarantena la mette chi scarica:
i browser sì, le altre applicazioni no — a meno che non la chiedano nel loro
Info.plist, e Vault non la chiede. Un DMG scaricato da qui non viene quindi
marchiato, e la versione nuova parte senza l'avviso "impossibile verificare lo
sviluppatore" che invece comparirebbe scaricandola a mano dal browser.

Perché non ci si sostituisce da soli mentre si è in esecuzione
--------------------------------------------------------------------------
Lo scambio lo fa uno script indipendente, che aspetta l'uscita dell'app prima
di toccare il bundle e poi la riavvia. Sostituire il proprio bundle mentre si
gira è il modo più rapido per ritrovarsi con metà applicazione.
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent
DATI_UTENTE = Path.home() / "Library" / "Application Support" / "Vault"
_MARCATORE = DATI_UTENTE / ".vault-controllo"

_API_RILASCIO = "https://api.github.com/repos/Nusherr/Vault/releases/latest"
_PAGINA = "https://github.com/Nusherr/Vault/releases/latest"

# Come per yt-dlp: una volta al giorno basta e avanza.
INTERVALLO_CONTROLLO = 24 * 3600


def bundle() -> Path | None:
    """Il pacchetto .app dentro cui gira il codice, o None fuori da un bundle.

    Nel pacchetto questo file sta in ``Vault.app/Contents/Resources/app/``:
    tre livelli sopra c'è il bundle. In sviluppo non c'è alcun bundle, e
    l'aggiornamento non ha senso.
    """
    candidato = PROJECT_DIR.parent.parent.parent
    return candidato if candidato.suffix == ".app" and candidato.is_dir() else None


def rilascio_installato() -> str:
    """Il tag inciso nel pacchetto al momento della costruzione."""
    b = bundle()
    if b is None:
        return ""
    try:
        with (b / "Contents" / "Info.plist").open("rb") as f:
            return str(plistlib.load(f).get("VaultRilascio") or "")
    except (OSError, ValueError):
        return ""


def _piu_recente(nuovo: str, attuale: str) -> bool:
    """True se ``nuovo`` viene dopo ``attuale``.

    I tag sono nella forma "v1.0.6": si confrontano i numeri uno a uno, così
    v1.0.10 risulta correttamente successivo a v1.0.9 — cosa che il confronto
    fra stringhe sbaglierebbe.
    """
    def pezzi(t: str) -> list[int]:
        numeri = []
        for p in t.lstrip("vV").split("."):
            cifre = "".join(c for c in p if c.isdigit())
            numeri.append(int(cifre) if cifre else 0)
        return numeri

    a, b = pezzi(nuovo), pezzi(attuale)
    lung = max(len(a), len(b))
    return a + [0] * (lung - len(a)) > b + [0] * (lung - len(b))


def serve_controllare() -> bool:
    try:
        return (time.time() - _MARCATORE.stat().st_mtime) > INTERVALLO_CONTROLLO
    except OSError:
        return True


def _segna_controllo() -> None:
    try:
        DATI_UTENTE.mkdir(parents=True, exist_ok=True)
        _MARCATORE.write_text(str(int(time.time())), encoding="utf-8")
    except OSError:
        pass


def controlla(*, forza: bool = False) -> dict:
    """Guarda se su GitHub c'è una release più recente.

    Ritorna ``{"nuova": bool, "tag", "note", "dmg", "attuale"}`` o
    ``{"error": …}``.
    """
    attuale = rilascio_installato()
    if not attuale:
        # Succede sulla copia di sviluppo: l'interfaccia sta in /Applications
        # ma il codice viene letto dalla cartella del progetto, quindi
        # sostituire il bundle non aggiornerebbe nulla — smonterebbe solo
        # l'ambiente di lavoro. Il messaggio dev'essere chiaro su questo:
        # dire "solo nell'app installata" a chi ce l'ha installata suona
        # semplicemente sbagliato.
        return {
            "error": "Questa è la copia di sviluppo di Vault, che legge il "
                     "codice dalla cartella del progetto. Si aggiorna "
                     "ricostruendola con build_native.sh, non da GitHub.",
            # Distingue il "qui non si applica" dal guasto vero: l'interfaccia
            # ci sceglie il titolo, e "Controllo non riuscito" su questo caso
            # farebbe pensare a un problema che non c'è.
            "sviluppo": True,
        }
    if not forza and not serve_controllare():
        return {"nuova": False, "attuale": attuale, "motivo": "controllato di recente"}

    try:
        with urllib.request.urlopen(_API_RILASCIO, timeout=25) as r:
            dati = json.loads(r.read())
    except Exception:  # noqa: BLE001
        return {"error": "Non sono riuscito a raggiungere GitHub."}
    _segna_controllo()

    tag = str(dati.get("tag_name") or "").strip()
    if not tag:
        return {"error": "Nessuna release pubblicata."}
    if not _piu_recente(tag, attuale):
        return {"nuova": False, "attuale": attuale, "tag": tag}

    dmg = next((a.get("browser_download_url") for a in dati.get("assets", [])
                if str(a.get("name", "")).lower().endswith(".dmg")), None)
    return {
        "nuova": True,
        "attuale": attuale,
        "tag": tag,
        "note": str(dati.get("body") or "").strip()[:1200],
        "dmg": dmg or "",
        "pagina": _PAGINA,
    }


def _puo_scrivere(percorso: Path) -> bool:
    """True se si può sostituire il bundle senza chiedere una password."""
    return os.access(percorso, os.W_OK) and os.access(percorso.parent, os.W_OK)


_SCRIPT = """#!/bin/sh
# Sostituisce Vault dopo che è uscita, poi la riavvia. Scritto da app_update.py.
while kill -0 {pid} 2>/dev/null; do sleep 0.4; done
sleep 1
VECCHIA="{destinazione}.da-rimuovere"
rm -rf "$VECCHIA"
mv "{destinazione}" "$VECCHIA" || exit 1
if ! /usr/bin/ditto "{nuova}" "{destinazione}"; then
    # Ripristino: meglio la versione di prima che nessuna applicazione.
    rm -rf "{destinazione}"
    mv "$VECCHIA" "{destinazione}"
    exit 1
fi
rm -rf "$VECCHIA" "{lavoro}"
/usr/bin/open "{destinazione}"
"""


def installa(tag_dmg: str) -> dict:
    """Scarica il DMG e prepara la sostituzione. Ritorna ``{"error": …}`` o
    ``{"pronto": True}``: in quel caso l'app deve chiudersi subito, e lo
    script farà il resto."""
    destinazione = bundle()
    if destinazione is None:
        return {"error": "Non sto girando da un'applicazione installata."}
    if not tag_dmg:
        return {"error": "La release non contiene un DMG."}
    if not _puo_scrivere(destinazione):
        return {"error": "Non ho i permessi per sostituire Vault. "
                         "Scaricala a mano dalla pagina delle release."}

    lavoro = Path(tempfile.mkdtemp(prefix="vault-aggiornamento-"))
    dmg = lavoro / "Vault.dmg"
    punto = lavoro / "montato"
    try:
        with urllib.request.urlopen(tag_dmg, timeout=900) as r, dmg.open("wb") as f:
            shutil.copyfileobj(r, f)

        punto.mkdir()
        subprocess.run(  # noqa: S603
            ["/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse",
             "-mountpoint", str(punto), str(dmg)], check=True, timeout=180)

        sorgente = next((p for p in punto.iterdir() if p.suffix == ".app"), None)
        if sorgente is None:
            msg = "Dentro il DMG non c'è nessuna applicazione."
            raise RuntimeError(msg)

        # Si copia fuori dal DMG prima di smontarlo: lo scambio avviene dopo
        # l'uscita dell'app, quando il volume non sarà più montato.
        nuova = lavoro / "Vault.app"
        subprocess.run(["/usr/bin/ditto", str(sorgente), str(nuova)],  # noqa: S603
                       check=True, timeout=600)
    except Exception as err:  # noqa: BLE001
        subprocess.run(["/usr/bin/hdiutil", "detach", "-quiet", str(punto)],  # noqa: S603
                       check=False)
        shutil.rmtree(lavoro, ignore_errors=True)
        return {"error": f"Aggiornamento non riuscito: {err}"}

    subprocess.run(["/usr/bin/hdiutil", "detach", "-quiet", str(punto)],  # noqa: S603
                   check=False)
    dmg.unlink(missing_ok=True)

    script = lavoro / "sostituisci.sh"
    script.write_text(_SCRIPT.format(
        pid=os.getppid() if os.getppid() > 1 else os.getpid(),
        destinazione=destinazione, nuova=nuova, lavoro=lavoro,
    ), encoding="utf-8")
    script.chmod(0o755)

    # start_new_session: lo script deve sopravvivere alla morte dell'app e del
    # server, altrimenti verrebbe ucciso proprio mentre fa il lavoro.
    subprocess.Popen(  # noqa: S603
        ["/bin/sh", str(script)], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return {"pronto": True}
