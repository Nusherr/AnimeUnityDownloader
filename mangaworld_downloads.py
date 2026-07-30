"""Download di manga da MangaWorld — funzione OPZIONALE e ISOLATA.

Usata solo dalla scheda "MangaWorld". Se il progetto non è installato,
``mangaworld_available()`` ritorna False e la scheda non compare: il resto di
Vault resta identico. Non importa nulla da gui.py, comunica via callback.

MangaWorld viene eseguito come sottoprocesso, non importato: il suo pacchetto
si chiama ``src`` esattamente come quello di AnimeUnity che sta già dentro
Vault, e importarli nello stesso processo significherebbe farne vincere uno a
caso. Il ponte è ``mangaworld_driver.py``, che sistema il percorso di ricerca e
corregge due difetti del loro entry point: gli intervalli di capitoli e la
cartella di destinazione.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
from pathlib import Path
from typing import Callable

PROJECT_DIR = Path(__file__).resolve().parent
DRIVER = PROJECT_DIR / "mangaworld_driver.py"

# Percorso predefinito dell'installazione di MangaWorld su questo Mac.
DEFAULT_MANGAWORLD_DIR = Path.home() / "MangaWorldDownloader"

# Sequenze ANSI di rich: l'avanzamento arriva dentro un pannello ridisegnato di
# continuo, e senza toglierle non si riconosce nulla.
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")

# Le due righe che interessano nel pannello:
#   Progress    ━━━━━━━━━━  62% • 0:01:12
#   Chapter 3/8 ━━━━━━━━━━  40% • 0:00:20
_AVANZAMENTO_RE = re.compile(r"Progress\b[^\d%]*?(\d+)%")
_CAPITOLO_RE = re.compile(r"Chapter\s+(\d+)\s*/\s*(\d+)\b[^\d%]*?(\d+)%")


class _Cancelled(Exception):
    """Segnala che l'utente ha annullato il download."""


def mangaworld_dir() -> Path:
    """Cartella di MangaWorldDownloader, cercata in ordine di priorità.

    Nel pacchetto distribuibile sta accanto al codice dell'app; in sviluppo in
    ``~/MangaWorldDownloader``. La variabile d'ambiente ha la precedenza.
    """
    env = os.environ.get("MANGAWORLD_DIR", "").strip()
    if env:
        return Path(env).expanduser()
    incluso = PROJECT_DIR.parent / "mangaworld"
    if (incluso / "manga_downloader.py").exists():
        return incluso
    return DEFAULT_MANGAWORLD_DIR


def _python(base: Path) -> str:
    """Interprete con cui eseguire MangaWorld.

    In sviluppo è il venv isolato del progetto, perché il Python di sistema non
    ha aiohttp, Pillow né brotlicffi. Nel pacchetto distribuibile non c'è alcun
    venv: le dipendenze di tutti i motori convivono nello stesso Python
    incorporato, quindi si riusa quello che sta già eseguendo la GUI.
    """
    venv = base / "env" / "bin" / "python"
    return str(venv) if venv.exists() else sys.executable


def mangaworld_available() -> bool:
    """True se MangaWorld è installato e il ponte è al suo posto."""
    try:
        return DRIVER.exists() and (mangaworld_dir() / "manga_downloader.py").exists()
    except OSError:
        return False


def conta_capitoli(url: str) -> dict:
    """Nome e numero di capitoli del manga. ``{"name", "count"}`` o ``{"error"}``.

    Una sola richiesta, meno di un secondo: serve a mostrare quanti capitoli
    ci sono prima di far scegliere l'intervallo, che altrimenti si indovina.
    """
    if not mangaworld_available():
        return {"error": "MangaWorld non è disponibile."}

    base = mangaworld_dir()
    argv = [_python(base), str(DRIVER), "--progetto", str(base),
            "--url", url, "--conta"]
    env = {k: v for k, v in os.environ.items()}
    env["PYTHONUNBUFFERED"] = "1"

    try:
        proc = subprocess.run(  # noqa: S603
            argv, stdin=subprocess.DEVNULL, capture_output=True,
            text=True, timeout=60, env=env, check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return {"error": "MangaWorld non ha risposto in tempo."}

    for riga in (proc.stdout or "").splitlines():
        riga = riga.strip()
        if riga.startswith("{"):
            try:
                dati = json.loads(riga)
            except ValueError:
                continue
            return {"name": dati.get("nome") or "", "count": int(dati.get("capitoli") or 0)}

    return {"error": "Non sono riuscito a leggere i capitoli di questo indirizzo."}


def _pulisci(riga: str) -> str:
    return _ANSI_RE.sub("", riga).replace("│", " ").strip()


def run_mangaworld_download(
    url: str,
    start: int | None,
    end: int | None,
    formato: str,
    destinazione: str,
    cancel: threading.Event,
    on_progress: Callable[[float], None],
    on_chapter: Callable[[int, int, float], None],
    on_log: Callable[[str], None],
) -> None:
    """Scarica un manga inoltrando l'avanzamento tramite callback."""
    base = mangaworld_dir()
    argv = [
        _python(base), str(DRIVER),
        "--progetto", str(base),
        "--url", url,
        "--destinazione", destinazione,
    ]
    if start is not None:
        argv += ["--start", str(start)]
    if end is not None:
        argv += ["--end", str(end)]
    if formato in ("pdf", "cbz"):
        argv += ["--formato", formato]

    env = {k: v for k, v in os.environ.items()}
    env["PYTHONUNBUFFERED"] = "1"
    # rich decide la larghezza dal terminale: senza, incolonna tutto a 80 e le
    # righe dell'avanzamento arrivano troncate a metà.
    env["COLUMNS"] = "150"
    env["TERM"] = "xterm"
    # Scrivendo su una pipe invece che su un terminale, rich considera inutile
    # animare e stampa il solo fotogramma finale: la barra restava immobile
    # fino alla fine del download. FORCE_COLOR gli fa credere di avere un
    # terminale davanti, e i fotogrammi intermedi tornano a passare.
    env["FORCE_COLOR"] = "1"

    # Lettura a blocchi, non per righe: con FORCE_COLOR rich anima il pannello
    # ridisegnandolo sul posto, spostando il cursore invece di andare a capo.
    # Iterando le righe ci si blocca fino alla fine del download, e la barra
    # resta immobile per tutto il tempo.
    proc = subprocess.Popen(  # noqa: S603
        argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, bufsize=0, env=env,
    )
    coda = ""              # ultimi caratteri letti, dove cercare i fotogrammi
    ultimo_cap: tuple | None = None
    ultima_pct: float | None = None
    gia_visto: set[str] = set()

    try:
        while True:
            if cancel.is_set():
                proc.terminate()
                raise _Cancelled

            blocco = os.read(proc.stdout.fileno(), 4096)
            if not blocco:
                break
            coda = (coda + blocco.decode("utf-8", "replace"))[-8192:]
            testo = _pulisci(coda)

            # Interessa sempre e solo l'ultimo fotogramma disegnato.
            cap = None
            for cap in _CAPITOLO_RE.finditer(testo):
                pass
            if cap:
                valori = (int(cap.group(1)), int(cap.group(2)), float(cap.group(3)))
                if valori != ultimo_cap:
                    ultimo_cap = valori
                    on_chapter(*valori)

            avz = None
            for avz in _AVANZAMENTO_RE.finditer(testo):
                pass
            if avz:
                pct = float(avz.group(1))
                if pct != ultima_pct:
                    ultima_pct = pct
                    on_progress(pct)

            # Diagnostica: solo righe nuove e senza percentuali, altrimenti il
            # log si riempirebbe di centinaia di ridisegni identici.
            for riga in testo.splitlines():
                pulita = riga.strip()
                if (pulita and "%" not in pulita and pulita.strip("╭╮╰╯─━│• ")
                        and pulita not in gia_visto):
                    gia_visto.add(pulita)
                    on_log(pulita[:300])
    finally:
        if proc.stdout:
            proc.stdout.close()
        proc.wait()

    if proc.returncode not in (0, None) and not cancel.is_set():
        msg = f"MangaWorld è uscito con codice {proc.returncode}."
        raise RuntimeError(msg)
