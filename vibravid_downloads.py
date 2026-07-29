"""Funzione opzionale "VibraVid" per la GUI di AnimeUnity Downloader.

Modulo completamente isolato: se VibraVid non è installato sul Mac, la scheda
non compare e AnimeUnity funziona esattamente come prima (stessa filosofia di
``ytdlp_downloads.py``).

VibraVid (https://github.com/AstraeLabs/VibraVid) è un downloader multi-sito
con una sua CLI pilotabile a flag e un suo ambiente Python isolato (``env/``).
Qui NON lo reimplementiamo: lo lanciamo come sottoprocesso usando il suo stesso
interprete, gli passiamo i flag e ne interpretiamo l'output.

Note ricavate osservando il comportamento reale della CLI:

- con ``--site``/``--search``/``--auto-first`` (o ``--item N``) e
  ``--season``/``--episode`` il download parte senza alcun prompt;
- l'avanzamento live viene emesso solo se ``TERM`` NON è "dumb": con un TERM
  vero rich ridisegna la barra e si ottengono gli stati intermedi, che qui
  vengono interpretati per alimentare la barra della GUI;
- le righe di avanzamento hanno la forma::

      Vid [H.264, AAC] 1920x1080 ---->--- | 56.9M / 77.5M · 24.89M/s · 00:01

- ``VIBRAVID_OUTPUT_ROOT`` sovrascrive la cartella di destinazione;
- se il file esiste già VibraVid stampa "File already exists." e non riscarica.

Posizione di VibraVid: variabile d'ambiente ``VIBRAVID_DIR`` se presente,
altrimenti il percorso predefinito qui sotto.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
from pathlib import Path
from typing import Callable

# Percorso predefinito dell'installazione di VibraVid su questo Mac.
DEFAULT_VIBRAVID_DIR = Path.home() / "VibraVid"

# Cartelle dentro services/ che NON sono siti selezionabili.
_NON_SITE_DIRS = {"_base", "__pycache__", "discovery"}

# Sequenze ANSI (colori/movimenti cursore di rich) da togliere dall'output.
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")

# Riga di avanzamento: "<etichetta> ---> | 56.9M / 77.5M · 24.89M/s · 00:01"
_PROGRESS_RE = re.compile(
    r"^(?P<label>.*?)\s*[-> ]*\|\s*"
    r"(?P<done>[\d.]+\s*[KMGT]?)\s*/\s*(?P<total>[\d.]+\s*[KMGT]?)\s*"
    r"·\s*(?P<speed>[^·]*?)\s*"
    r"(?:·\s*(?P<eta>[\d:]+))?\s*$"
)

_UNITS = {"": 1, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}

# Righe di rumore da non mostrare nel log della GUI.
_NOISE_RE = re.compile(r"^[\s_/\\|)(,.`'~^-]*$")

# Ridisegni della barra di avanzamento che _PROGRESS_RE non cattura perché
# privi del totale (tipico dei sottotitoli: "| 42K · 320K/s · 00:00").
# Senza questo filtro rich ne emette migliaia e il log diventa illeggibile,
# oltre a rallentare l'interfaccia che deve disegnarle tutte.
_REDRAW_RE = re.compile(r"\|\s*[\d.]+\s*[KMGT]?\s*(·|/s)")


class _Cancelled(Exception):
    """Segnala che l'utente ha annullato il download di VibraVid."""


# Variabili che l'interprete che ci ospita imposta per sé e che, ereditate,
# manderebbero in confusione il Python di VibraVid (che è un'altra versione).
# Senza questa pulizia VibraVid muore all'avvio quando la GUI è lanciata
# dall'app: __PYVENV_LAUNCHER__ punta all'interprete sbagliato.
_ENV_DA_RIMUOVERE = (
    "__PYVENV_LAUNCHER__",
    "PYTHONHOME",
    "PYTHONPATH",
    "PYTHONEXECUTABLE",
    "PYTHONSTARTUP",
    "VIRTUAL_ENV",
)


# VibraVid cerca ffmpeg/ffprobe nel PATH e si rifiuta di partire se non li
# trova. Lanciata dal Dock, l'app riceve da launchd un PATH minimo
# (/usr/bin:/bin:/usr/sbin:/sbin) che non include né Homebrew né i binari del
# progetto: senza questi percorsi VibraVid fallisce solo quando l'app è aperta
# con un doppio clic, e funziona invece da terminale.
_PATH_EXTRA = (
    "/opt/homebrew/bin",
    "/usr/local/bin",
    str(Path(__file__).resolve().parent / "tools"),
    str(DEFAULT_VIBRAVID_DIR / "tools"),
)


def _merged_path() -> str:
    """PATH ereditato più i percorsi dove vivono davvero ffmpeg e soci."""
    seen: list[str] = []
    for entry in list(_PATH_EXTRA) + os.environ.get("PATH", "").split(":"):
        if entry and entry not in seen and Path(entry).is_dir():
            seen.append(entry)
    return ":".join(seen)


def _clean_env(**extra: str) -> dict:
    """Ambiente per i sottoprocessi di VibraVid, ripulito e con PATH completo."""
    env = {
        k: v for k, v in os.environ.items()
        if k not in _ENV_DA_RIMUOVERE
    }
    env["PATH"] = _merged_path()
    env["PYTHONUNBUFFERED"] = "1"
    env["NO_COLOR"] = "1"
    env["TERM"] = "dumb"
    env.update(extra)
    return env


# ============================================================== rilevamento
def vibravid_dir() -> Path:
    """Cartella di VibraVid, cercata in ordine di priorità.

    Nel pacchetto distribuibile VibraVid è incluso accanto al codice dell'app;
    in sviluppo sta in ``~/VibraVid``. La variabile d'ambiente ha la precedenza
    su entrambi.
    """
    env = os.environ.get("VIBRAVID_DIR", "").strip()
    if env:
        return Path(env).expanduser()
    incluso = Path(__file__).resolve().parent.parent / "vibravid"
    if (incluso / "manual.py").exists():
        return incluso
    return DEFAULT_VIBRAVID_DIR


def _python(base: Path) -> Path:
    """Interprete con cui eseguire VibraVid.

    In sviluppo è il venv isolato di VibraVid. Nel pacchetto distribuibile non
    c'è alcun venv: le dipendenze dei due progetti convivono nello stesso
    Python incorporato, quindi si riusa quello che sta già eseguendo la GUI.
    """
    venv = base / "env" / "bin" / "python"
    return venv if venv.exists() else Path(sys.executable)


def vibravid_available() -> bool:
    """True se VibraVid è installato e lanciabile (cartella + venv + manual.py)."""
    base = vibravid_dir()
    try:
        return (
            base.is_dir()
            and _python(base).exists()
            and (base / "manual.py").exists()
        )
    except OSError:
        return False


def list_sites() -> list[str]:
    """Elenco dei siti supportati (nomi delle cartelle in ``services/``)."""
    base = vibravid_dir() / "VibraVid" / "services"
    try:
        return sorted(
            entry.name
            for entry in base.iterdir()
            if entry.is_dir()
            and entry.name not in _NON_SITE_DIRS
            and not entry.name.startswith("__")
        )
    except OSError:
        return []


def output_root(custom_path: str | None = None) -> Path:
    """Cartella dove VibraVid salva i video.

    Con una cartella scelta si usa quella e basta; senza, la Downloads
    dell'utente, come annuncia l'etichetta. Grazie alla configurazione privata
    non vengono creati livelli intermedi: dentro c'è direttamente la serie.
    """
    if custom_path:
        # Cartella scelta: usata così com'è, senza aggiungere altri livelli.
        return Path(custom_path).expanduser()
    return Path.home() / "Downloads"


# Configurazione privata: una copia di quella di VibraVid con i livelli di
# raggruppamento (Serie/Film/Anime) svuotati, così i download finiscono
# direttamente nella cartella scelta. L'originale di VibraVid resta intatto:
# usandolo da solo continua a organizzare i file come prima.
CONF_PRIVATA = Path(__file__).resolve().parent / "vibravid_conf"

_LIVELLI_DA_TOGLIERE = (
    "serie_folder_name", "movie_folder_name", "anime_folder_name",
    "music_folder_name", "live_folder_name",
)


def prepara_config() -> Path | None:
    """Prepara la configurazione privata. Ritorna la cartella base, o None."""
    sorgente = vibravid_dir() / "Conf"
    if not (sorgente / "config.json").exists():
        return None

    destinazione = CONF_PRIVATA / "Conf"
    try:
        destinazione.mkdir(parents=True, exist_ok=True)
        # Domini e credenziali vengono riallineati a ogni avvio: i domini dei
        # siti cambiano spesso e una copia vecchia farebbe fallire le ricerche.
        for nome in ("domains.json", "login.json"):
            originale = sorgente / nome
            if originale.exists():
                shutil.copy2(originale, destinazione / nome)

        dati = json.loads((sorgente / "config.json").read_text(encoding="utf-8"))
        uscita = dati.setdefault("OUTPUT", {})
        for chiave in _LIVELLI_DA_TOGLIERE:
            uscita[chiave] = ""
        (destinazione / "config.json").write_text(
            json.dumps(dati, indent=4, ensure_ascii=False), encoding="utf-8")
    except (OSError, ValueError):
        return None
    return CONF_PRIVATA


# ==================================================== riproduzione diretta
# Siti che consegnano il flusso cifrato (Widevine/PlayReady): VibraVid lo sa
# decifrare mentre scarica, ma un lettore esterno riceverebbe dati illeggibili.
# Su questi la riproduzione diretta non viene offerta.
SITI_PROTETTI = frozenset({
    "crunchyroll", "raiplay", "mediasetinfinity", "discoveryplus",
    "dmax", "nove", "realtime", "foodnetwork", "homegardentv",
})


def sito_riproducibile(site: str) -> bool:
    """True se il sito consegna un flusso in chiaro, apribile da un lettore."""
    return site.strip().lower() not in SITI_PROTETTI


def lettore_disponibile() -> bool:
    """True se IINA è installato."""
    return Path("/Applications/IINA.app").is_dir()


def _coda_privata() -> Path:
    return CONF_PRIVATA / ".cache" / "queue"


_VIDEO_EXT = (".mkv", ".mp4", ".m4v", ".avi")


def _cerca_file_locale(radice: Path, codice: str, titolo: str = "") -> Path | None:
    """File già scaricato di QUESTA serie con QUESTO codice episodio.

    Il titolo è indispensabile: cercando il solo "S01E01" si trovava il primo
    episodio di una serie qualsiasi (chiedendo House of Cards usciva House of
    the Dragon). Vengono ignorate le cartelle nascoste, dove stanno i file
    parziali dei download interrotti: aprirli darebbe errore.
    """
    partenza = radice
    if titolo:
        # La cartella della serie ha il titolo, a meno di caratteri sostituiti.
        candidate = [d for d in radice.glob("*")
                     if d.is_dir() and not d.name.startswith(".")
                     and _somiglia(d.name, titolo)]
        if candidate:
            partenza = candidate[0]
        elif any(radice.glob("*")):
            return None      # la serie non è stata scaricata qui

    try:
        for f in partenza.rglob("*"):
            if any(p.startswith(".") for p in f.parts):
                continue     # dentro una cartella temporanea: file parziale
            if (f.is_file() and f.suffix.lower() in _VIDEO_EXT
                    and codice.lower() in f.name.lower().replace(" ", "")):
                return f
    except OSError:
        return None
    return None


def _somiglia(a: str, b: str) -> bool:
    """Confronto tollerante fra nomi di cartella e titoli."""
    pulisci = lambda s: "".join(c for c in s.lower() if c.isalnum())  # noqa: E731
    x, y = pulisci(a), pulisci(b)
    return bool(x) and bool(y) and (x in y or y in x)


def risolvi_flusso(params: dict) -> dict:
    """Ottiene l'indirizzo riproducibile senza scaricare.

    Ritorna ``{"url": …}`` per il flusso remoto, ``{"file": …}`` se l'episodio
    è già sul disco (meglio aprire quello), oppure ``{"error": …}``.
    """
    if not vibravid_available():
        return {"error": "VibraVid non è disponibile."}
    site = str(params.get("site", "")).strip()
    if not sito_riproducibile(site):
        return {"error": f"Il sito {site} consegna un flusso protetto: "
                         "si può solo scaricare."}

    base = vibravid_dir()
    argv = [str(_python(base)), "manual.py", "--site", site,
            "--search", str(params.get("query", ""))]
    item = str(params.get("item", "")).strip()
    argv += ["--item", str(int(item))] if item.isdigit() else ["--auto-first"]
    for chiave, flag in (("season", "--season"), ("episode", "--episode"),
                         ("audio", "-sa"), ("subtitle", "-ss")):
        valore = str(params.get(chiave, "")).strip()
        if valore:
            argv += [flag, valore]
    argv += ["--resolve-only", "--no-log"]

    env = _clean_env(COLUMNS="150")
    base_conf = prepara_config()
    if base_conf is not None:
        env["VIBRAVID_BASE_PATH"] = str(base_conf)
    destinazione = output_root(str(params.get("path", "")).strip() or None)
    env["VIBRAVID_OUTPUT_ROOT"] = str(destinazione)

    coda = _coda_privata()
    prima = set(coda.glob("*.json")) if coda.is_dir() else set()

    try:
        proc = subprocess.run(  # noqa: S603
            argv, cwd=str(base), stdin=subprocess.DEVNULL, capture_output=True,
            text=True, timeout=240, env=env, check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return {"error": "La risoluzione del flusso non ha risposto in tempo."}

    uscita = (proc.stdout or "") + (proc.stderr or "")

    # Nuovo file di coda: dentro c'è l'indirizzo del flusso.
    nuovi = (set(coda.glob("*.json")) - prima) if coda.is_dir() else set()
    for f in sorted(nuovi, key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            dati = json.loads(f.read_text(encoding="utf-8"))
            for voce in dati.get("items", []):
                a = voce.get("argv", [])
                if "--down" in a:
                    indirizzo = a[a.index("--down") + 1]
                    # La voce va tolta: serviva solo a trasportare l'indirizzo,
                    # altrimenti resterebbe in attesa di essere scaricata.
                    f.unlink(missing_ok=True)
                    return {"url": indirizzo}
        except (OSError, ValueError, IndexError):
            continue

    # Già scaricato: VibraVid non risolve nulla, ma il file c'è.
    if "already exists" in uscita.lower():
        stagione = str(params.get("season", "")).strip()
        episodio = str(params.get("episode", "")).strip()
        if stagione.isdigit() and episodio.isdigit():
            codice = f"S{int(stagione):02d}E{int(episodio):02d}"
            titolo = str(params.get("title") or params.get("query") or "")
            trovato = _cerca_file_locale(destinazione, codice, titolo)
            if trovato:
                return {"file": str(trovato)}
        return {"error": "L'episodio risulta già scaricato ma non l'ho trovato."}

    return {"error": "Non sono riuscito a ottenere il flusso da questo sito."}


def apri_nel_lettore(indirizzo: str) -> str | None:
    """Apre indirizzo o file in IINA. Ritorna un messaggio d'errore o None."""
    if not lettore_disponibile():
        return "IINA non è installato."
    # "open -a" e non iina-cli: quest'ultimo non digerisce gli indirizzi con
    # parametri di query (token, expires…) e risponde "Impossibile aprire il
    # file o lo stream", mentre lo stesso indirizzo passato così si riproduce.
    comando = ["open", "-a", "IINA", indirizzo]
    try:
        subprocess.Popen(  # noqa: S603
            comando, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except OSError as err:
        return f"Non riesco ad aprire IINA: {err}"
    return None


def pulisci_temporanei(radice: Path) -> int:
    """Elimina le cartelle temporanee lasciate da download interrotti.

    Annullando un download, VibraVid lascia accanto ai file finiti una cartella
    nascosta tipo ``.Episodio 3 S03E03_hls_temp`` con i segmenti già scaricati:
    invisibile nel Finder e facilmente di parecchi GB. Qui si rimuovono prima
    di iniziarne uno nuovo.

    Ritorna quante cartelle sono state rimosse.
    """
    rimosse = 0
    try:
        candidate = list(radice.rglob("*_temp"))
    except (OSError, ValueError):
        return 0

    for voce in candidate:
        # Solo cartelle nascoste con il suffisso dei temporanei: nulla che
        # possa assomigliare a un file dell'utente.
        if not voce.is_dir() or not voce.name.startswith("."):
            continue
        if not voce.name.endswith(("_hls_temp", "_dash_temp", "_ism_temp", "_temp")):
            continue
        try:
            shutil.rmtree(voce)
            rimosse += 1
        except OSError:
            continue
    return rimosse


# ============================================================ testo e numeri
def _strip(line: str) -> str:
    """Toglie sequenze ANSI e spazi di troppo dalla riga."""
    return _ANSI_RE.sub("", line).replace("\r", "").rstrip()


def _to_bytes(text: str) -> float:
    """Converte "56.9M" in byte. Ritorna 0 se non interpretabile."""
    text = text.strip().replace(" ", "")
    if not text:
        return 0.0
    unit = text[-1].upper()
    if unit in _UNITS and unit != "":
        try:
            return float(text[:-1]) * _UNITS[unit]
        except ValueError:
            return 0.0
    try:
        return float(text)
    except ValueError:
        return 0.0


def parse_progress(line: str) -> dict | None:
    """Interpreta una riga di avanzamento di VibraVid.

    Ritorna ``{"label", "done", "total", "pct", "speed_bps", "status"}``
    oppure None se la riga non è un avanzamento.
    """
    match = _PROGRESS_RE.match(line)
    if not match:
        return None
    done = _to_bytes(match.group("done"))
    total = _to_bytes(match.group("total"))
    if total <= 0:
        return None

    raw_speed = (match.group("speed") or "").strip()
    speed_bps = 0.0
    status = ""
    if raw_speed.endswith("/s"):
        speed_bps = _to_bytes(raw_speed[:-2])
    elif raw_speed:
        status = raw_speed  # es. "Merge"

    label = re.sub(r"[-> ]+$", "", match.group("label") or "").strip()
    return {
        "label": label,
        "done": done,
        "total": total,
        "pct": max(0.0, min(100.0 * done / total, 100.0)),
        "speed_bps": speed_bps,
        "status": status,
    }


# ================================================================== ricerca
_SEARCH_SNIPPET = r"""
import io, json, contextlib, sys
from VibraVid.services._base import load_search_functions
try:
    funcs = load_search_functions()
    mapping = {f.module_name.lower(): f for f in funcs.values()}
    func = mapping.get(SITE)
    if func is None:
        print(json.dumps({"error": "sito sconosciuto"})); sys.exit(0)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        db = func(QUERY, get_onlyDatabase=True)
    out = []
    for el in (getattr(db, "media_list", None) or [])[:LIMIT]:
        d = getattr(el, "__dict__", {}) or {}
        out.append({
            "name": str(d.get("name") or ""),
            "type": str(d.get("type") or ""),
            "year": str(d.get("year") or ""),
        })
    print(json.dumps({"results": out}))
except Exception as exc:
    print(json.dumps({"error": str(exc)[:200]}))
"""


def search_titles(site: str, query: str, limit: int = 40) -> dict:
    """Cerca i titoli su un sito SENZA scaricare nulla.

    Usa la stessa API interna che la CLI usa per ``--item``: l'indice di ogni
    risultato corrisponde quindi esattamente al valore da passare a ``--item``.
    Ritorna ``{"results": [...]}`` oppure ``{"error": "..."}``.
    """
    base = vibravid_dir()
    if not vibravid_available():
        return {"error": "VibraVid non è disponibile."}

    code = (
        f"SITE = {site.strip().lower()!r}\n"
        f"QUERY = {query.strip()!r}\n"
        f"LIMIT = {int(limit)}\n"
        + _SEARCH_SNIPPET
    )
    env = _clean_env(PYTHONPATH=str(base))  # qui non serve avanzamento

    try:
        proc = subprocess.run(  # noqa: S603
            [str(_python(base)), "-c", code],
            cwd=str(base),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=180,
            env=env,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {"error": "La ricerca ha impiegato troppo tempo."}
    except OSError as exc:
        return {"error": f"Impossibile avviare VibraVid: {exc}"}

    for line in reversed((proc.stdout or "").splitlines()):
        line = _strip(line).strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return {"error": "Nessun risultato interpretabile da VibraVid."}


# ==================================================== ricerca dei titoli
# Gira dentro l'interprete di VibraVid (il nostro non può importarlo: altro
# ambiente e altra versione di Python) e restituisce i risultati in JSON.
_SEARCH_SCRIPT = r"""
import io, json, sys, contextlib
from VibraVid.services._base import load_search_functions

site, query = sys.argv[1], sys.argv[2]
funcs = load_search_functions()
mapping = {f.module_name.lower(): f for f in funcs.values()}
func = mapping.get(site.lower())
out = []
if func is not None:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        db = func(query, get_onlyDatabase=True)
    for el in (getattr(db, "media_list", None) or []):
        d = getattr(el, "__dict__", {})
        out.append({
            "name": str(d.get("name") or ""),
            "type": str(d.get("type") or ""),
            "year": str(d.get("year") or ""),
        })
print("<<<JSON>>>" + json.dumps(out, ensure_ascii=False))
"""


def search_titles(site: str, query: str, limit: int = 40) -> dict:
    """Cerca i titoli su un sito. ``{"results": [...]}`` oppure ``{"error": ...}``."""
    if not vibravid_available():
        return {"error": "VibraVid non è disponibile."}

    base = vibravid_dir()
    env = _clean_env(PYTHONPATH=str(base))

    try:
        proc = subprocess.run(  # noqa: S603
            [str(_python(base)), "-c", _SEARCH_SCRIPT, site, query],
            cwd=str(base), stdin=subprocess.DEVNULL, capture_output=True,
            text=True, timeout=180, env=env, check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return {"error": "La ricerca non ha risposto in tempo."}

    marker = "<<<JSON>>>"
    text = proc.stdout or ""
    if marker not in text:
        return {"error": "Nessun risultato leggibile da questo sito."}
    try:
        results = json.loads(text.split(marker, 1)[1].splitlines()[0])
    except (ValueError, IndexError):
        return {"error": "Risposta della ricerca non interpretabile."}
    return {"results": results[:limit]}


# ================================================== struttura di una serie
# VibraVid, quando non gli si dice quale stagione/episodio, stampa la tabella
# di ciò che ha trovato e poi chiede all'utente. Qui gliela facciamo stampare
# con stdin chiuso: la tabella si legge, il prompt fallisce e va bene così.
# Passa dal codice comune a tutti i siti, quindi funziona ovunque.

_CACHE: dict[tuple, list[dict]] = {}


def _parse_table(text: str) -> list[list[str]]:
    """Estrae le righe dati da una tabella disegnata con i caratteri di box."""
    rows: list[list[str]] = []
    for raw in text.splitlines():
        line = _strip(raw).strip()
        if not line.startswith("│"):
            continue
        cells = [c.strip() for c in line.strip("│").split("│")]
        if len(cells) >= 2 and cells[0].isdigit():
            rows.append(cells)
    return rows


def _probe(site: str, query: str, item: str, season: str | None) -> str:
    """Lancia VibraVid fino alla domanda su stagione/episodio e ne cattura l'output."""
    base = vibravid_dir()
    argv = [str(_python(base)), "manual.py", "--site", site, "--search", query]
    argv += ["--item", str(int(item))] if str(item).strip().isdigit() else ["--auto-first"]
    if season:
        argv += ["--season", str(season)]
    argv += ["--no-log"]

    env = _clean_env(COLUMNS="150")

    try:
        proc = subprocess.run(  # noqa: S603
            argv, cwd=str(base), stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=240, env=env, check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return ""
    return (proc.stdout or "") + (proc.stderr or "")


def list_seasons(site: str, query: str, item: str) -> dict:
    """Elenco delle stagioni di un titolo. ``{"seasons": [...]}`` o ``{"error": ...}``."""
    if not vibravid_available():
        return {"error": "VibraVid non è disponibile."}
    key = ("s", site, query, str(item))
    if key in _CACHE:
        return {"seasons": _CACHE[key]}

    output = _probe(site, query, item, None)
    if not output:
        return {"error": "Non sono riuscito a leggere le stagioni."}

    seasons = [
        {"index": int(r[0]), "name": r[1]}
        for r in _parse_table(output)
        # la tabella delle stagioni ha 3 colonne: indice, nome, id
        if len(r) >= 2
    ]
    if not seasons:
        # Nessuna tabella: con ogni probabilità è un film, non una serie.
        return {"seasons": [], "movie": True}
    _CACHE[key] = seasons
    return {"seasons": seasons}


def list_episodes(site: str, query: str, item: str, season: str) -> dict:
    """Elenco degli episodi di una stagione, con durata se disponibile."""
    if not vibravid_available():
        return {"error": "VibraVid non è disponibile."}
    key = ("e", site, query, str(item), str(season))
    if key in _CACHE:
        return {"episodes": _CACHE[key]}

    output = _probe(site, query, item, season)
    if not output:
        return {"error": "Non sono riuscito a leggere gli episodi."}

    episodes = []
    for r in _parse_table(output):
        entry = {"index": int(r[0]), "name": r[1]}
        if len(r) >= 3 and r[2].isdigit():
            entry["duration"] = int(r[2])
        episodes.append(entry)
    if not episodes:
        return {"error": "Nessun episodio trovato per questa stagione."}
    _CACHE[key] = episodes
    return {"episodes": episodes}


# ================================================================= download
def _build_argv(base: Path, params: dict) -> list[str]:
    """Costruisce gli argomenti della CLI di VibraVid dai parametri della GUI."""
    argv: list[str] = [str(_python(base)), "manual.py"]
    argv += ["--site", params["site"], "--search", params["query"]]

    # Selezione del risultato: indice specifico oppure il primo.
    item = str(params.get("item", "")).strip()
    if item.isdigit():
        argv += ["--item", str(int(item))]
    else:
        argv += ["--auto-first"]

    for key, flag in (
        ("season", "--season"), ("episode", "--episode"), ("year", "--year"),
        ("video", "-sv"), ("audio", "-sa"), ("subtitle", "-ss"),
    ):
        value = str(params.get(key, "")).strip()
        if value:
            argv += [flag, value]

    # Esce a fine download; il log su file non serve (lo cattura la GUI).
    argv += ["--close-console", "true", "--no-log"]
    return argv


def _iter_output(stream) -> "object":
    """Legge lo stream a blocchi e restituisce righe divise su \\r e \\n.

    Necessario perché rich aggiorna la barra con ritorni-carrello: iterando
    solo sulle righe terminate da \\n si perderebbero gli stati intermedi.
    """
    buffer = ""
    while True:
        chunk = stream.read(256)
        if not chunk:
            break
        buffer += chunk
        parts = re.split(r"[\r\n]", buffer)
        buffer = parts.pop()
        for part in parts:
            yield part
    if buffer:
        yield buffer


def run_vibravid_search(
    params: dict,
    cancel: threading.Event,
    on_line: Callable[[str], None],
    on_progress: Callable[[dict], None],
    on_stage: Callable[[str], None],
) -> None:
    """Esegue ricerca+download con VibraVid come sottoprocesso.

    ``on_line`` riceve le righe di testo (log della GUI), ``on_progress`` i
    dati di avanzamento già interpretati e ``on_stage`` un testo breve di stato.
    Solleva ``_Cancelled`` se l'utente annulla, ``RuntimeError`` se VibraVid
    termina con errore.
    """
    base = vibravid_dir()
    argv = _build_argv(base, params)

    env = _clean_env(COLUMNS="140")
    # TERM "vero": senza di esso rich non emette gli stati intermedi della barra.
    if os.environ.get("TERM", "") in ("", "dumb", "unknown"):
        env["TERM"] = "xterm-256color"
    else:
        env["TERM"] = os.environ["TERM"]
    env.pop("NO_COLOR", None)
    # Sempre, anche senza cartella scelta: altrimenti VibraVid userebbe la
    # propria cartella interna mentre l'interfaccia annuncia "Downloads".
    custom = str(params.get("path", "")).strip()
    destinazione = output_root(custom or None)
    destinazione.mkdir(parents=True, exist_ok=True)
    env["VIBRAVID_OUTPUT_ROOT"] = str(destinazione)

    # Configurazione privata: elimina i livelli Serie/Film/Anime senza toccare
    # quella di VibraVid. Se non si riesce a prepararla, si prosegue comunque
    # con la sua (i file finiranno in una sottocartella, ma il download parte).
    base_conf = prepara_config()
    if base_conf is not None:
        env["VIBRAVID_BASE_PATH"] = str(base_conf)

    rimosse = pulisci_temporanei(destinazione)
    if rimosse:
        on_line(f"🧹 Rimossi {rimosse} residui di download interrotti.")
    on_line(f"Cartella di destinazione: {destinazione}")

    on_line(f"$ {' '.join(argv[1:])}")

    proc = subprocess.Popen(  # noqa: S603 - argomenti costruiti internamente
        argv,
        cwd=str(base),
        stdin=subprocess.DEVNULL,  # niente input: eventuali prompt ricevono EOF
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        text=True,
        bufsize=1,
        start_new_session=True,    # gruppo di processi separato: killabile in blocco
    )

    stop_watch = threading.Event()

    def watchdog() -> None:
        while not stop_watch.wait(0.3):
            if cancel.is_set():
                _terminate(proc)
                return

    threading.Thread(target=watchdog, daemon=True).start()

    already_existed = False
    try:
        for raw in _iter_output(proc.stdout):
            line = _strip(raw).strip()
            if not line or _NOISE_RE.match(line):
                continue

            info = parse_progress(line)
            if info:
                on_progress(info)
                continue

            # Ridisegno della barra senza totale: aggiorna lo stato ma non
            # finisce nel log, altrimenti lo riempie di migliaia di righe.
            if _REDRAW_RE.search(line):
                continue

            on_line(line)
            if "already exists" in line.lower():
                already_existed = True
            if len(line) <= 100:
                on_stage(line)
    finally:
        stop_watch.set()
        code = proc.wait()

    if cancel.is_set():
        raise _Cancelled
    if code != 0:
        raise RuntimeError(
            f"VibraVid è terminato con codice {code}. "
            "Apri \"Mostra dettagli\" per l'output completo."
        )
    if already_existed:
        on_line("ℹ️ Il file era già presente: nessun nuovo download.")


def _terminate(proc: subprocess.Popen) -> None:
    """Termina il sottoprocesso e l'intero gruppo (SIGTERM, poi SIGKILL)."""
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except OSError:
            pass
