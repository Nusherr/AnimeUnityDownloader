"""Interfaccia grafica per AnimeUnityDownloader.

Avvio:
    python3 gui.py

Avvia un piccolo server locale (solo su 127.0.0.1) con l'interfaccia web.
Normalmente viene mostrata dentro l'app nativa "AnimeUnity Downloader.app"
(vedi macos_app/main.swift); aperta da terminale usa il browser predefinito.

Funzionalità:
- download di un singolo anime (tutti gli episodi, un intervallo o una lista);
- download in batch di più URL (collegato a URLs.txt);
- scelta della cartella di destinazione;
- avanzamento con velocità e tempo rimanente, annullamento;
- notifica di sistema a download completato.

Non richiede dipendenze extra oltre a quelle del progetto.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
import threading
import time
import traceback
import webbrowser
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import requests

from anime_downloader import parse_episodes_list
from src.config import DOWNLOAD_WORKERS, URLS_FILE, prepare_headers
from src.crawler.crawler import Crawler
from src.crawler.crawler_utils import extract_download_link
from src.download_utils import get_chunk_size, get_episode_filename
from src.file_utils import create_download_directory
from src.general_utils import fetch_page, fetch_page_httpx

# --- Funzione opzionale "Altri siti" (yt-dlp), completamente isolata ---
# Se il modulo o i binari non ci sono, la scheda non compare e AnimeUnity
# funziona esattamente come prima.
try:
    from ytdlp_downloads import (
        QUALITY_LABELS,
        fetch_title,
        list_formats,
        run_ytdlp_download,
        ytdlp_available,
    )
    from ytdlp_downloads import _Cancelled as YtdlpCancelled
except Exception:  # noqa: BLE001
    QUALITY_LABELS = {}

    def ytdlp_available() -> bool:
        return False

    def list_formats(url: str) -> str:  # noqa: ARG001
        return ""

    class YtdlpCancelled(Exception):
        pass

# --- Funzione opzionale "VibraVid", anch'essa completamente isolata ---
# Se VibraVid non è installato sul Mac, la scheda non compare.
try:
    from vibravid_downloads import (
        apri_nel_lettore as vibravid_apri_lettore,
        etichetta_media as vibravid_etichetta,
        lettore_disponibile as vibravid_lettore,
        risolvi_flusso as vibravid_risolvi,
        sito_riproducibile as vibravid_riproducibile,
        list_episodes as vibravid_episodes,
        list_seasons as vibravid_seasons,
        list_sites as vibravid_sites,
        output_root as vibravid_output_root,
        run_vibravid_search,
        search_titles as vibravid_search_titles,
        vibravid_available,
    )
    from vibravid_downloads import _Cancelled as VibravidCancelled
except Exception:  # noqa: BLE001
    def vibravid_available() -> bool:
        return False

    def vibravid_sites() -> list:
        return []

    def vibravid_output_root(custom_path=None):  # noqa: ARG001
        return Path.home()

    def vibravid_search_titles(site: str, query: str) -> dict:  # noqa: ARG001
        return {"error": "Funzione non disponibile."}

    def vibravid_seasons(site: str, query: str, item: str) -> dict:  # noqa: ARG001
        return {"error": "Funzione non disponibile."}

    def vibravid_episodes(site: str, query: str, item: str, season: str) -> dict:  # noqa: ARG001
        return {"error": "Funzione non disponibile."}

    def vibravid_lettore() -> bool:
        return False

    def vibravid_riproducibile(site: str) -> bool:  # noqa: ARG001
        return False

    def vibravid_risolvi(params: dict) -> dict:  # noqa: ARG001
        return {"error": "Funzione non disponibile."}

    def vibravid_etichetta(params: dict) -> str:  # noqa: ARG001
        return ""

    def vibravid_apri_lettore(indirizzo: str, titolo: str = "") -> str | None:  # noqa: ARG001
        return "Funzione non disponibile."

    class VibravidCancelled(Exception):
        pass

PROJECT_DIR = Path(__file__).resolve().parent

# Dove si scrive ciò che l'utente produce: la lista di URL del download in
# elenco, la configurazione privata di VibraVid, la coda.
#
# Non accanto al codice, che nel pacchetto distribuibile sta dentro Vault.app:
# scriverci fallisce ogni volta che il bundle è in sola lettura — succede a chi
# apre l'app direttamente dal DMG invece di trascinarla in Applicazioni, e a
# chiunque non sia amministratore. In sviluppo il percorso coincide con quello
# di prima, quindi non cambia nulla.
DATI_UTENTE = Path.home() / "Library" / "Application Support" / "Vault"

# I video finiscono di default in ~/Downloads (il tool aggiunge "Downloads/<anime>")
DEFAULT_BASE = str(Path.home())
HOST = "127.0.0.1"
PORT = 8765
IDLE_EXIT_SECONDS = 300  # esce se nessuna pagina è aperta e non ci sono download


class DownloadCancelled(Exception):
    """Segnala che l'utente ha annullato il download."""


# ============================================================ stato condiviso
class AppState:
    """Stato condiviso tra il server HTTP e il thread di download."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.log_lines: list[str] = []
        self.running = False
        self.worker: threading.Thread | None = None
        self.cancel = threading.Event()
        self.overall = {"label": "In attesa…", "total": 0, "done": 0}
        self.tasks: dict[int, dict] = {}
        self.completed: list[dict] = []
        self.download_path: str | None = None
        self.speed_bps = 0.0
        self.bytes_now = 0
        # Totale reale in byte, quando il motore lo dichiara (VibraVid somma
        # le sue tracce). Se resta 0 si ricade sulla stima per estrapolazione.
        self.bytes_total = 0
        # Download in attesa: si svuota da sola quando il precedente finisce.
        self.queue: list[dict] = []
        self.queue_seq = 0
        self.last_error: str | None = None
        self.error_seq = 0
        self.manual_progress = False  # True quando l'avanzamento lo gestisce yt-dlp
        self.last_poll = time.time()

    def log(self, message: str) -> None:
        with self.lock:
            self.log_lines.append(message)
            del self.log_lines[:-500]

    def reset_progress(self, label: str = "In attesa…") -> None:
        with self.lock:
            self.overall = {"label": label, "total": 0, "done": 0}
            self.tasks = {}

    def snapshot(self) -> dict:
        with self.lock:
            episodes = [
                {"desc": task["desc"], "pct": task["pct"]}
                for task in self.tasks.values()
                if task["visible"]
            ]
            total = self.overall["total"]
            done = self.overall["done"]
            eff = done + sum(
                task["pct"] for task in self.tasks.values() if task["visible"]
            ) / 100
            eta = est = None
            if self.bytes_total > self.bytes_now:
                # Totale dichiarato dal motore: preciso, niente estrapolazioni.
                est = float(self.bytes_total)
                if self.speed_bps > 100_000:
                    eta = max((est - self.bytes_now) / self.speed_bps, 0)
            elif (
                self.running
                and total > 0
                and self.bytes_now > 1_000_000
                and self.speed_bps > 100_000
                and eff / total > 0.04
            ):
                # Stima per estrapolazione: usata solo se il totale non si sa.
                # Può risultare più piccola di quanto già scaricato, perciò
                # viene mostrata solo finché resta plausibile.
                stima = self.bytes_now / (eff / total)
                if stima >= self.bytes_now:
                    est = stima
                    eta = max((est - self.bytes_now) / self.speed_bps, 0)
            return {
                "running": self.running,
                "log": self.log_lines[:],
                "overall": dict(self.overall),
                "episodes": episodes,
                "completed": self.completed[:],
                "speed_bps": self.speed_bps,
                "bytes_now": self.bytes_now,
                "bytes_total_est": est,
                "eta_s": eta,
                "last_error": self.last_error,
                "error_seq": self.error_seq,
                # La voce porta con sé la funzione da eseguire, che non è
                # serializzabile: all'interfaccia servono solo le etichette.
                "queue": [
                    {"id": v["id"], "label": v["label"], "detail": v["detail"]}
                    for v in self.queue
                ],
                "ytdlp": ytdlp_available(),
                "vibravid": vibravid_available(),
                "stage": self.overall.get("stage"),
            }


STATE = AppState()


class GuiProgress:
    """Sostituto della Progress di rich: aggiorna lo stato condiviso.

    Implementa la stessa interfaccia usata da save_file_with_progress
    (add_task / update / advance), quindi il codice del progetto funziona
    senza modifiche.
    """

    def __init__(self, state: AppState, cancel: threading.Event) -> None:
        self.state = state
        self.cancel = cancel
        self._counter = 0
        self.overall_task = None

    def add_task(self, description: str, total: float = 100, visible: bool = False):
        task_id = self._counter
        self._counter += 1
        desc = re.sub(r"\[[^\]]*\]", "", str(description))
        with self.state.lock:
            if self.overall_task is None:
                self.overall_task = task_id
                self.state.overall["total"] = total
                self.state.overall["done"] = 0
            else:
                self.state.tasks[task_id] = {
                    "desc": desc, "pct": 0, "visible": visible,
                }
        return task_id

    def update(self, task, completed=None, visible=None, **_kwargs) -> None:
        if self.cancel.is_set():
            raise DownloadCancelled
        with self.state.lock:
            row = self.state.tasks.get(task)
            if row is None:
                return
            if completed is not None:
                row["pct"] = min(float(completed), 100.0)
            if visible is not None:
                row["visible"] = visible

    def advance(self, task, advance: float = 1) -> None:
        with self.state.lock:
            if task == self.overall_task:
                self.state.overall["done"] += advance


def notify(anime_name: str) -> None:
    """Mostra una notifica di sistema a download completato."""
    script = (
        'display notification "Download completato" '
        f"with title \"Vault\" subtitle {json.dumps(anime_name)}"
    )
    subprocess.run(["osascript", "-e", script], check=False)


def folder_size(path: str) -> int:
    """Somma le dimensioni dei file nella cartella."""
    try:
        return sum(f.stat().st_size for f in Path(path).iterdir() if f.is_file())
    except OSError:
        return 0


def speed_sampler() -> None:
    """Campiona la cartella di download per calcolare la velocità reale."""
    samples: deque = deque()
    last_path = None
    while True:
        time.sleep(1.5)
        with STATE.lock:
            if STATE.manual_progress:
                continue  # durante yt-dlp l'avanzamento arriva già pronto
            path = STATE.download_path
            running = STATE.running
        if not running or not path:
            samples.clear()
            last_path = None
            with STATE.lock:
                STATE.speed_bps = 0.0
                STATE.bytes_now = 0
            continue
        if path != last_path:
            samples.clear()
            last_path = path
        size = folder_size(path)
        now = time.time()
        samples.append((now, size))
        while samples and now - samples[0][0] > 12:
            samples.popleft()
        speed = 0.0
        if len(samples) >= 2:
            dt = samples[-1][0] - samples[0][0]
            db = samples[-1][1] - samples[0][1]
            if dt > 0:
                speed = max(db / dt, 0.0)
        with STATE.lock:
            STATE.speed_bps = speed
            STATE.bytes_now = size


# ================================================================= download
RESUME_MAX_RETRIES = 240   # con attese fino a 30s ≈ 2 ore di pazienza
RESUME_WAIT_MAX = 30       # secondi di attesa massima tra i tentativi


def download_episode_resumable(
    video_url: str,
    download_path: str,
    task_info: tuple,
    cancel: threading.Event,
    state: AppState,
    episode_number: int,
) -> None:
    """Scarica un episodio riprendendo da dove si era interrotto.

    Sostituisce process_video_url/download_episode del progetto originale:
    usa richieste HTTP Range per non perdere i progressi quando cade la
    connessione, riprova finché la rete non torna, rigenera il link se
    scaduto e salta i file già completi.
    """
    job_progress, task, overall_task = task_info
    link = None
    final_path = None
    offline_logged = False

    for attempt in range(RESUME_MAX_RETRIES):
        if cancel.is_set():
            raise DownloadCancelled
        try:
            if link is None:
                soup = fetch_page(video_url)
                link = extract_download_link(soup.find_all("script"), video_url)
                if not link:
                    state.log(f"⚠️ Episodio {episode_number}: link di download non trovato.")
                    return
                filename = get_episode_filename(link)
                final_path = Path(download_path) / filename

            existing = final_path.stat().st_size if final_path.exists() else 0
            headers = prepare_headers()
            if existing:
                headers["Range"] = f"bytes={existing}-"

            response = requests.get(link, stream=True, headers=headers, timeout=15)

            if response.status_code == 416:
                # Il file locale copre già l'intera dimensione: episodio completo
                response.close()
                job_progress.update(task, completed=100, visible=False)
                job_progress.advance(overall_task)
                state.log(f"✔ Episodio {episode_number}: già completo, saltato.")
                return
            if response.status_code in (401, 403, 410):
                response.close()
                link = None  # link scaduto: al prossimo giro se ne estrae uno nuovo
                raise requests.RequestException(f"link scaduto (HTTP {response.status_code})")
            response.raise_for_status()

            if existing and response.status_code != 206:
                existing = 0  # il server non supporta la ripresa: si riparte da zero

            content_length = int(response.headers.get("Content-Length", -1))
            total_size = existing + content_length if content_length > 0 else -1

            if offline_logged:
                resumed_pct = 100 * existing / total_size if total_size > 0 else 0
                state.log(
                    f"▶ Episodio {episode_number}: connessione ristabilita, "
                    f"riprendo dal {resumed_pct:.0f}%.")
                offline_logged = False

            chunk_size = get_chunk_size(total_size if total_size > 0 else 0)
            downloaded = existing
            with final_path.open("ab" if existing else "wb") as file:
                for chunk in response.iter_content(chunk_size=chunk_size):
                    if cancel.is_set():
                        raise DownloadCancelled
                    if chunk:
                        file.write(chunk)
                        downloaded += len(chunk)
                        if total_size > 0:
                            job_progress.update(
                                task, completed=100 * downloaded / total_size)

            if total_size > 0 and downloaded < total_size:
                # Il server ha chiuso in anticipo senza errore: si riprende
                raise requests.RequestException("trasferimento incompleto")

            job_progress.update(task, completed=100, visible=False)
            job_progress.advance(overall_task)
            return

        except DownloadCancelled:
            raise
        except (requests.RequestException, OSError):
            if not offline_logged:
                state.log(
                    f"⏸ Episodio {episode_number}: connessione interrotta — "
                    "i progressi sono al sicuro, riprovo in automatico…")
                offline_logged = True
            delay = min(5 * (attempt + 1), RESUME_WAIT_MAX)
            if cancel.wait(delay):
                raise DownloadCancelled

    state.log(
        f"⚠️ Episodio {episode_number}: connessione assente da troppo tempo, "
        "mi fermo. Rilancia il download per riprendere da dove eri rimasto.")


def run_downloads(
    video_urls: list,
    progress: GuiProgress,
    download_path: str,
    cancel: threading.Event,
    state: AppState,
) -> None:
    """Scarica gli episodi in parallelo aggiornando lo stato.

    Variante di src.download_utils.run_in_parallel senza il polling bloccante,
    con supporto all'annullamento.
    """
    num_items = len(video_urls)
    progress.add_task("Totale", total=num_items, visible=True)
    overall = progress.overall_task

    def worker(video_url: str, task, episode_number: int) -> None:
        if cancel.is_set():
            raise DownloadCancelled
        progress.update(task, visible=True)
        download_episode_resumable(
            video_url, download_path, (progress, task, overall),
            cancel, state, episode_number,
        )

    with ThreadPoolExecutor(max_workers=DOWNLOAD_WORKERS) as executor:
        futures = []
        for indx, video_url in enumerate(video_urls):
            task = progress.add_task(
                f"Episodio {indx + 1}/{num_items}", total=100, visible=False,
            )
            futures.append(
                (indx + 1, executor.submit(worker, video_url, task, indx + 1)))

        for episode_number, future in futures:
            try:
                future.result()
            except DownloadCancelled:
                pass
            except Exception as err:  # noqa: BLE001 - un episodio non ferma gli altri
                state.log(f"⚠️ Errore sull'episodio {episode_number}: {err}")

    if cancel.is_set():
        raise DownloadCancelled


def download_one_anime(
    url: str,
    state: AppState,
    cancel: threading.Event,
    start: int | None = None,
    end: int | None = None,
    episodes: list[int] | None = None,
    custom_path: str | None = None,
) -> None:
    """Replica process_anime_download usando la progress della GUI."""
    state.log(f"Recupero informazioni da {url} ...")
    soup = fetch_page_httpx(url)

    # Python 3.9: asyncio.Semaphore (creato in Crawler.__init__) richiede un
    # event loop già associato al thread; nei thread di lavoro va creato
    # esplicitamente e usato anche per collect_video_urls.
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        crawler = Crawler(
            url=url, start_episode=start, end_episode=end, episodes=episodes,
        )
        anime_name = crawler.extract_anime_name(soup, url)
        state.reset_progress(label=anime_name or url)
        state.log(f"Anime: {anime_name} ({crawler.num_episodes} episodi sul sito)")

        download_path = create_download_directory(anime_name, custom_path=custom_path)
        state.log(f"Cartella di destinazione: {download_path}")
        with state.lock:
            state.download_path = str(download_path)

        if cancel.is_set():
            raise DownloadCancelled

        video_urls = loop.run_until_complete(crawler.collect_video_urls())
    finally:
        asyncio.set_event_loop(None)
        loop.close()

    missing = sum(1 for v in video_urls if not v)
    video_urls = [v for v in video_urls if v]
    if missing:
        state.log(f"⚠️ {missing} episodi non raggiungibili, verranno saltati.")
    state.log(f"Episodi da scaricare: {len(video_urls)}")

    if not video_urls:
        state.log("Nessun episodio da scaricare.")
        return

    progress = GuiProgress(state, cancel)
    run_downloads(video_urls, progress, download_path, cancel, state)

    with state.lock:
        state.completed.append({
            "label": anime_name,
            "path": str(download_path),
            "size": folder_size(str(download_path)),
        })
        state.download_path = None
    state.log(f"✅ Download di \"{anime_name}\" completato.")
    # Nell'app nativa la notifica la pubblica Swift (con l'icona dell'app);
    # via osascript solo in modalità browser.
    if not os.environ.get("GUI_NO_BROWSER"):
        notify(anime_name)


# ================================================= "Altri siti" (yt-dlp)
def _safe_listdir(folder: Path) -> set:
    """Elenca i file di una cartella senza mai sollevare eccezioni."""
    try:
        return set(folder.iterdir())
    except OSError:
        return set()


def _download_one_url(
    url: str,
    options: dict,
    base: Path,
    state: AppState,
    cancel: threading.Event,
) -> str:
    """Scarica un singolo link (che può essere una playlist). Ritorna il titolo."""
    quality_label = QUALITY_LABELS.get(options.get("quality", "best"), "")
    state.log(f"Recupero informazioni da {url} …")
    title = fetch_title(url) or url
    if cancel.is_set():
        raise DownloadCancelled

    with state.lock:
        state.overall = {"label": title, "total": 1, "done": 0}
        state.tasks = {0: {"desc": quality_label, "pct": 0.0, "visible": True}}
        state.speed_bps = 0.0
        state.bytes_now = 0
    state.log(f"Titolo: {title} — qualità: {quality_label}")

    def on_progress(downloaded, total, speed, eta) -> None:  # noqa: ARG001
        pct = (100 * downloaded / total) if total else 0.0
        with state.lock:
            state.tasks[0]["pct"] = min(pct, 100.0)
            state.speed_bps = speed
            state.bytes_now = int(downloaded)

    def on_stage(text: str) -> None:
        with state.lock:
            state.tasks[0]["desc"] = f"{quality_label} · {text}"

    def on_playlist(index: int, count: int) -> None:
        with state.lock:
            state.overall["label"] = f"{title} — elemento {index} di {count}"
            state.overall["total"] = count
            state.overall["done"] = index - 1
            state.tasks[0]["pct"] = 0.0

    try:
        run_ytdlp_download(
            url, options, str(base), cancel,
            on_progress, on_stage, on_playlist, state.log,
        )
    except YtdlpCancelled as exc:
        raise DownloadCancelled from exc
    return title


def download_other_site(
    raw_urls: str,
    options: dict,
    state: AppState,
    cancel: threading.Event,
    custom_path: str | None = None,
) -> None:
    """Scarica uno o più link da siti generici tramite yt-dlp ("Altri siti").

    Riusa lo stesso stato/interfaccia dei download di AnimeUnity, così le barre
    di avanzamento hanno un aspetto identico.
    """
    base = Path(custom_path or DEFAULT_BASE) / "Downloads"
    base.mkdir(parents=True, exist_ok=True)
    state.log(f"Cartella di destinazione: {base}")

    urls = [u.strip() for u in raw_urls.splitlines() if u.strip()]
    with state.lock:
        state.manual_progress = True
        state.download_path = None
    try:
        for indx, url in enumerate(urls, start=1):
            if cancel.is_set():
                raise DownloadCancelled
            if len(urls) > 1:
                state.log(f"— Link {indx}/{len(urls)} —")
            before = _safe_listdir(base)
            title = _download_one_url(url, options, base, state, cancel)

            with state.lock:
                state.tasks[0]["pct"] = 100.0
                state.overall["done"] = state.overall.get("total", 1)
                new_files = [f for f in _safe_listdir(base) if f not in before]
                size = sum(
                    f.stat().st_size for f in new_files
                    if f.is_file() and f.exists()
                )
                state.completed.append({
                    "label": title, "path": str(base), "size": size,
                })
            state.log(f"✅ Download di \"{title}\" completato.")
            if not os.environ.get("GUI_NO_BROWSER"):
                notify(title)
    finally:
        with state.lock:
            state.manual_progress = False


# ===================================================== "VibraVid" (multi-sito)
def formato_selezione(params: dict) -> str:
    """Descrizione compatta di cosa è stato scaricato.

    Compatta apposta, perché finisce in una riga d'elenco:
    ``S01E01`` · ``S01E01-E03`` · ``S01 completa`` · ``S01-S03 complete``.
    La lingua non compare: nell'elenco non aiuta a distinguere le voci.
    """
    stagione = str(params.get("season", "")).strip()
    episodio = str(params.get("episode", "")).strip()

    if stagione == "*":
        return "tutte le stagioni"
    if not stagione:
        return ""

    try:
        esse = f"S{int(stagione):02d}"
    except ValueError:
        esse = f"S{stagione}"           # intervalli tipo "1-3"

    if episodio in ("", "*"):
        return f"{esse} completa"

    numeri = []
    for pezzo in episodio.split(","):
        pezzo = pezzo.strip()
        if pezzo.isdigit():
            numeri.append(int(pezzo))
    if not numeri:
        return esse

    numeri.sort()
    if len(numeri) == 1:
        return f"{esse} · E{numeri[0]:02d}"
    # Consecutivi: si accorciano in un intervallo.
    if numeri == list(range(numeri[0], numeri[-1] + 1)):
        return f"{esse} · E{numeri[0]:02d}-E{numeri[-1]:02d}"
    return esse + " · " + ", ".join(f"E{n:02d}" for n in numeri)


def download_vibravid(
    params: dict,
    state: AppState,
    cancel: threading.Event,
) -> None:
    """Scarica da un sito supportato da VibraVid lanciandolo come sottoprocesso.

    Riusa lo stesso stato/interfaccia degli altri download: la barra resta
    indeterminata (VibraVid gestisce il proprio avanzamento) e l'output completo
    scorre nel log. Il testo di stato viene mostrato sotto la barra.
    """
    title = params.get("title") or params.get("query") or "VibraVid"
    # Istante d'avvio: serve a distinguere i file di questo download da quelli
    # già presenti nella cartella di destinazione.
    inizio = time.time()
    with state.lock:
        state.manual_progress = True
        state.download_path = None
        # "unit" dice all'interfaccia che cosa sta contando: qui sono le tracce
        # (video, audio, sottotitoli), non gli episodi. Chiamarle "episodi"
        # faceva scrivere "0 di 2 episodi" anche scaricandone uno solo.
        state.overall = {
            "label": title, "total": 0, "done": 0,
            "stage": "Avvio…", "unit": "tracce",
        }
        state.tasks = {}
        state.speed_bps = 0.0
        state.bytes_now = 0
    state.log(f"VibraVid · sito: {params.get('site')} · ricerca: {params.get('query')}")

    # Quanti episodi sono stati chiesti: serve per sapere a quanto ammonta il
    # lavoro totale. Con "*" non si sa in anticipo e il totale cresce mano a
    # mano che VibraVid annuncia gli episodi.
    richiesti = str(params.get("episode", "")).strip()
    if richiesti and richiesti != "*":
        attesi = len([n for n in richiesti.split(",") if n.strip()])
    else:
        attesi = 0

    # Stato dell'episodio in corso. Le tracce (video, audio, sottotitoli)
    # ripetono le stesse etichette a ogni episodio: vanno azzerate a ogni
    # passaggio, altrimenti il secondo episodio sovrascrive le righe del primo
    # e il conteggio non avanza mai.
    corrente = {"indice": 0, "nome": ""}
    seen: dict[str, dict] = {}

    def nuovo_episodio(nome: str) -> None:
        """VibraVid ha annunciato un nuovo episodio: si riparte da zero."""
        with state.lock:
            corrente["indice"] += 1
            corrente["nome"] = nome
            seen.clear()
            state.tasks = {}
            state.overall["done"] = corrente["indice"] - 1
            state.overall["total"] = max(attesi, corrente["indice"])
            state.overall["unit"] = "episodi"
            state.overall["stage"] = nome
            state.bytes_now = 0
            state.bytes_total = 0
            state.speed_bps = 0.0

    def on_progress(info: dict) -> None:
        label = info["label"] or "Traccia"
        with state.lock:
            seen[label] = info
            # Avanzamento dell'episodio in corso: media delle sue tracce.
            pct_ep = sum(i["pct"] for i in seen.values()) / max(len(seen), 1)
            state.tasks = {
                0: {
                    "desc": corrente["nome"] or "In corso",
                    "pct": min(pct_ep, 100.0),
                    "visible": True,
                }
            }
            if state.overall["total"] == 0:
                state.overall["total"] = max(attesi, 1)
                state.overall["unit"] = "episodi"
            state.overall["stage"] = ""
            # Byte reali delle tracce dell'episodio, non una stima.
            state.bytes_now = int(sum(i["done"] for i in seen.values()))
            state.bytes_total = int(sum(i.get("total") or 0 for i in seen.values()))
            state.speed_bps = sum(i["speed_bps"] for i in seen.values())

    def on_stage(text: str) -> None:
        with state.lock:
            state.overall["stage"] = text

    # Riga con cui VibraVid annuncia l'episodio: "… \ Episodio 2 (S1E2)"
    episodio_re = re.compile(r"\\\s*(.+?)\s*\((S\d+E\d+)\)\s*$")

    def formatta_episodio(codice: str) -> str:
        """Da "S1E2" a "S01 E02": più leggibile e coerente con gli elenchi."""
        parti = re.match(r"S(\d+)E(\d+)", codice, re.IGNORECASE)
        if not parti:
            return codice
        return f"S{int(parti.group(1)):02d} · E{int(parti.group(2)):02d}"

    def on_line(line: str) -> None:
        match = episodio_re.search(line)
        if match:
            nuovo_episodio(formatta_episodio(match.group(2)))
        state.log(line)

    try:
        run_vibravid_search(params, cancel, on_line, on_progress, on_stage)
    except VibravidCancelled as exc:
        raise DownloadCancelled from exc
    finally:
        with state.lock:
            state.manual_progress = False

    dest = str(vibravid_output_root(params.get("path") or None))
    # Solo i file scritti da QUESTO download: sommare tutta la cartella
    # includeva anche i download precedenti, gonfiando il totale (2,88 GB
    # dichiarati per un file da 1,04 GB).
    try:
        size = sum(
            f.stat().st_size
            for f in Path(dest).rglob("*")
            if f.is_file() and f.stat().st_mtime >= inizio - 5
        )
    except OSError:
        size = 0
    # Etichetta precisa: "titolo · stagione 1 · episodi 1, 2 · audio ITA".
    # Il solo titolo non basta a capire cosa sia stato scaricato quando in
    # elenco ci sono più voci della stessa serie.
    etichetta = f"{title} · {formato_selezione(params)}".rstrip(" ·")

    with state.lock:
        state.completed.append({"label": etichetta, "path": dest, "size": size})
    state.log(f"✅ Download di \"{etichetta}\" completato.")
    if not os.environ.get("GUI_NO_BROWSER"):
        notify(title)


def start_job(job, label: str = "", detail: str = "") -> str | None:
    """Mette un download in coda e, se non c'è nulla in corso, lo avvia.

    Prima un secondo download veniva semplicemente rifiutato; ora si accoda e
    parte da solo quando tocca a lui. Ritorna un messaggio d'errore o None.
    """
    with STATE.lock:
        STATE.queue_seq += 1
        STATE.queue.append({
            "id": STATE.queue_seq,
            "label": label or "Download",
            "detail": detail,
            "job": job,
        })
        occupato = STATE.running
    if not occupato:
        _avvia_prossimo()
    return None


def _avvia_prossimo() -> None:
    """Toglie il primo elemento dalla coda e lo esegue in un thread."""
    with STATE.lock:
        if STATE.running or not STATE.queue:
            return
        voce = STATE.queue.pop(0)
        STATE.running = True
    STATE.cancel = threading.Event()
    STATE.reset_progress()
    cancel = STATE.cancel
    job = voce["job"]

    def runner() -> None:
        try:
            job(cancel)
        except DownloadCancelled:
            STATE.log("⏹ Download annullato.")
        except Exception as err:  # noqa: BLE001
            STATE.log("❌ Errore:\n" + traceback.format_exc())
            with STATE.lock:
                STATE.last_error = (
                    f"Si è verificato un errore: {err}"[:300]
                    + "\n\nRiprova, oppure scegli un altro sito."
                )
                STATE.error_seq += 1
        finally:
            with STATE.lock:
                STATE.running = False
                STATE.download_path = None
                STATE.manual_progress = False
            # Tocca al prossimo della coda, se c'è.
            _avvia_prossimo()

    STATE.worker = threading.Thread(target=runner, daemon=True)
    STATE.worker.start()


# ================================================================ server HTTP
class Handler(BaseHTTPRequestHandler):
    """Gestisce la pagina e le API della GUI."""

    def log_message(self, *args) -> None:  # silenzia il log delle richieste
        pass

    # ----------------------------------------------------------- helpers
    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload: dict, code: int = 200) -> None:
        self._send(code, json.dumps(payload).encode(), "application/json")

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", 0) or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            return {}

    def _origin_ok(self) -> bool:
        origin = self.headers.get("Origin")
        return origin is None or origin.startswith(f"http://{HOST}")

    # ------------------------------------------------------------- GET
    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/":
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif path == "/state":
            with STATE.lock:
                STATE.last_poll = time.time()
            self._json(STATE.snapshot())
        elif path == "/urls":
            urls_path = DATI_UTENTE / URLS_FILE
            content = urls_path.read_text(encoding="utf-8") if urls_path.exists() else ""
            self._json({"content": content})
        elif path == "/vibravid_sites":
            self._json({"sites": vibravid_sites()})
        else:
            self._json({"error": "not found"}, code=404)

    # ------------------------------------------------------------- POST
    def do_POST(self) -> None:  # noqa: N802
        if not self._origin_ok():
            self._json({"error": "forbidden"}, code=403)
            return

        path = urlparse(self.path).path
        data = self._read_json()

        try:
            if path == "/download":
                self._json(self._handle_download(data))
            elif path == "/batch":
                self._json(self._handle_batch(data))
            elif path == "/ytdlp":
                self._json(self._handle_ytdlp(data))
            elif path == "/ytdlp_formats":
                self._json(self._handle_ytdlp_formats(data))
            elif path == "/vibravid":
                self._json(self._handle_vibravid(data))
            elif path == "/vibravid_search":
                self._json(self._handle_vibravid_search(data))
            elif path == "/vibravid_seasons":
                self._json(self._handle_vibravid_seasons(data))
            elif path == "/vibravid_episodes":
                self._json(self._handle_vibravid_episodes(data))
            elif path == "/vibravid_watch":
                self._json(self._handle_vibravid_watch(data))
            elif path == "/cancel":
                if STATE.running:
                    STATE.cancel.set()
                    STATE.log("⏹ Annullamento in corso… attendo la fine degli episodi attivi.")
                self._json({"ok": True})
            elif path == "/queue_remove":
                # Toglie un elemento in attesa senza toccare quello in corso.
                voce_id = data.get("id")
                with STATE.lock:
                    prima = len(STATE.queue)
                    STATE.queue = [v for v in STATE.queue if v["id"] != voce_id]
                    rimossi = prima - len(STATE.queue)
                if rimossi:
                    STATE.log("🗑 Elemento rimosso dalla coda.")
                self._json({"ok": True})
            elif path == "/clear_completed":
                with STATE.lock:
                    STATE.completed = []
                self._json({"ok": True})
            elif path == "/save_urls":
                content = str(data.get("content", "")).strip()
                DATI_UTENTE.mkdir(parents=True, exist_ok=True)
                (DATI_UTENTE / URLS_FILE).write_text(
                    content + ("\n" if content else ""), encoding="utf-8")
                self._json({"ok": True})
            elif path == "/pick_folder":
                self._json({"path": pick_folder()})
            elif path == "/open_folder":
                base = Path(str(data.get("path", "")).strip() or DEFAULT_BASE)
                base = base / "Downloads"
                base.mkdir(parents=True, exist_ok=True)
                subprocess.run(["open", str(base)], check=False)
                self._json({"ok": True})
            elif path == "/open_path":
                target = str(data.get("path", ""))
                with STATE.lock:
                    allowed = {entry["path"] for entry in STATE.completed}
                    if STATE.download_path:
                        allowed.add(STATE.download_path)
                if target in allowed and Path(target).exists():
                    subprocess.run(["open", target], check=False)
                self._json({"ok": True})
            elif path == "/quit":
                self._json({"ok": True})
                threading.Timer(0.3, lambda: os._exit(0)).start()
            else:
                self._json({"error": "not found"}, code=404)
        except Exception as err:  # noqa: BLE001
            self._json({"error": str(err)}, code=500)

    # -------------------------------------------------------- avvio job
    @staticmethod
    def _parse_int(value, field: str):
        value = str(value or "").strip()
        if not value:
            return None
        try:
            return int(value)
        except ValueError:
            raise ValueError(f'Il campo "{field}" deve essere un numero intero.')

    def _handle_download(self, data: dict) -> dict:
        url = str(data.get("url", "")).strip()
        if not url:
            return {"error": "Inserisci il link dell'anime."}
        if "/anime/" not in url:
            return {"error": (
                "Il link deve essere la pagina dell'anime su AnimeUnity, "
                "es. https://www.animeunity.so/anime/1517-yuru-yuri")}

        mode = data.get("mode", "all")
        start = end = None
        episodes = None
        if mode == "range":
            try:
                start = self._parse_int(data.get("start"), "da")
                end = self._parse_int(data.get("end"), "a")
            except ValueError as err:
                return {"error": str(err)}
        elif mode == "list":
            raw = str(data.get("episodes", "")).replace(" ", ",").strip()
            episodes = parse_episodes_list([raw] if raw else None)
            if not episodes:
                return {"error": "Indica gli episodi, es. 3, 7, 12."}

        custom_path = str(data.get("path", "")).strip() or DEFAULT_BASE
        error = start_job(
            lambda cancel: download_one_anime(
                url, STATE, cancel,
                start=start, end=end, episodes=episodes, custom_path=custom_path,
            ),
            label=url.rstrip("/").split("/")[-1].replace("-", " ").title(),
            detail="AnimeUnity",
        )
        return {"error": error} if error else {"ok": True}

    def _handle_batch(self, data: dict) -> dict:
        urls = [
            line.strip()
            for line in str(data.get("urls", "")).splitlines()
            if line.strip()
        ]
        if not urls:
            return {"error": "Inserisci almeno un link (uno per riga)."}

        custom_path = str(data.get("path", "")).strip() or DEFAULT_BASE

        def job(cancel: threading.Event) -> None:
            for indx, url in enumerate(urls, start=1):
                if cancel.is_set():
                    raise DownloadCancelled
                STATE.log(f"— Anime {indx}/{len(urls)} —")
                try:
                    download_one_anime(url, STATE, cancel, custom_path=custom_path)
                except DownloadCancelled:
                    raise
                except Exception as err:  # noqa: BLE001
                    STATE.log(f"⚠️ Errore su {url}: {err}")

        error = start_job(job, label=f"{len(urls)} anime", detail="Batch")
        return {"error": error} if error else {"ok": True}

    def _handle_ytdlp(self, data: dict) -> dict:
        if not ytdlp_available():
            return {"error": "La funzione \"Altri siti\" non è disponibile."}
        raw_urls = str(data.get("url", "")).strip()
        if not raw_urls:
            return {"error": "Inserisci un link da scaricare."}
        first = raw_urls.splitlines()[0].strip()
        if not first.startswith(("http://", "https://")):
            return {"error": "Il link deve iniziare con http:// o https://"}

        options = dict(data.get("options") or {})
        options["quality"] = (
            data.get("quality") if data.get("quality") in QUALITY_LABELS else "best"
        )
        custom_path = str(data.get("path", "")).strip() or DEFAULT_BASE
        error = start_job(
            lambda cancel: download_other_site(
                raw_urls, options, STATE, cancel, custom_path=custom_path,
            ),
            label=first.split("/")[2] if "/" in first else "Link",
            detail=QUALITY_LABELS.get(options.get("quality", "best"), ""),
        )
        return {"error": error} if error else {"ok": True}

    def _handle_vibravid(self, data: dict) -> dict:
        if not vibravid_available():
            return {"error": "La funzione \"VibraVid\" non è disponibile."}
        site = str(data.get("site", "")).strip()
        query = str(data.get("query", "")).strip()
        if not site:
            return {"error": "Scegli un sito."}
        if not query:
            return {"error": "Inserisci un titolo da cercare."}

        params = {
            "site": site,
            "query": query,
            "title": str(data.get("title", "")).strip() or query,
            "item": str(data.get("item", "")).strip(),
            "season": str(data.get("season", "")).strip(),
            "episode": str(data.get("episode", "")).strip(),
            "year": str(data.get("year", "")).strip(),
            "video": str(data.get("video", "")).strip(),
            "audio": str(data.get("audio", "")).strip(),
            "subtitle": str(data.get("subtitle", "")).strip(),
            "path": str(data.get("path", "")).strip(),
        }
        error = start_job(
            lambda cancel: download_vibravid(params, STATE, cancel),
            label=params.get("title") or params.get("query") or "VibraVid",
            detail=formato_selezione(params),
        )
        return {"error": error} if error else {"ok": True}

    def _handle_vibravid_search(self, data: dict) -> dict:
        if not vibravid_available():
            return {"error": "La funzione \"VibraVid\" non è disponibile."}
        site = str(data.get("site", "")).strip()
        query = str(data.get("query", "")).strip()
        if not site or not query:
            return {"error": "Scegli un sito e scrivi un titolo da cercare."}
        return vibravid_search_titles(site, query)

    def _handle_vibravid_seasons(self, data: dict) -> dict:
        """Quante stagioni ha il titolo scelto (vuoto = è un film)."""
        if not vibravid_available():
            return {"error": "La funzione \"VibraVid\" non è disponibile."}
        site = str(data.get("site", "")).strip()
        query = str(data.get("query", "")).strip()
        item = str(data.get("item", "")).strip()
        if not site or not query:
            return {"error": "Scegli prima un titolo."}
        return vibravid_seasons(site, query, item)

    def _handle_vibravid_episodes(self, data: dict) -> dict:
        """Episodi di una stagione, con durata quando disponibile."""
        if not vibravid_available():
            return {"error": "La funzione \"VibraVid\" non è disponibile."}
        site = str(data.get("site", "")).strip()
        query = str(data.get("query", "")).strip()
        item = str(data.get("item", "")).strip()
        season = str(data.get("season", "")).strip()
        if not site or not query or not season:
            return {"error": "Scegli prima una stagione."}
        return vibravid_episodes(site, query, item, season)

    def _handle_vibravid_watch(self, data: dict) -> dict:
        """Risolve il flusso e lo apre nel lettore, senza scaricare nulla."""
        if not vibravid_available():
            return {"error": "La funzione \"VibraVid\" non è disponibile."}
        if not vibravid_lettore():
            return {"error": "IINA non è installato: la riproduzione diretta "
                             "richiede un lettore."}
        site = str(data.get("site", "")).strip()
        if not vibravid_riproducibile(site):
            return {"error": f"Il sito {site} consegna un flusso protetto: "
                             "si può solo scaricare."}

        params = {
            "site": site,
            "query": str(data.get("query", "")).strip(),
            "title": str(data.get("title", "")).strip(),
            "item": str(data.get("item", "")).strip(),
            "season": str(data.get("season", "")).strip(),
            "episode": str(data.get("episode", "")).strip(),
            "audio": str(data.get("audio", "")).strip(),
            "subtitle": str(data.get("subtitle", "")).strip(),
            "path": str(data.get("path", "")).strip(),
        }
        esito = vibravid_risolvi(params)
        if "error" in esito:
            return esito

        etichetta = vibravid_etichetta(params)
        errore = vibravid_apri_lettore(esito.get("url", ""), etichetta)
        if errore:
            return {"error": errore}
        STATE.log(f"▶️ Riproduzione in IINA: {etichetta or 'flusso remoto'}")
        return {"ok": True}

    def _handle_ytdlp_formats(self, data: dict) -> dict:
        if not ytdlp_available():
            return {"error": "Funzione non disponibile."}
        url = str(data.get("url", "")).strip().splitlines()
        url = url[0].strip() if url else ""
        if not url.startswith(("http://", "https://")):
            return {"error": "Inserisci prima un link valido."}
        return {"formats": list_formats(url)}


def pick_folder() -> str:
    """Mostra la finestra nativa di scelta cartella (via AppleScript).

    Usata solo in modalità browser; l'app nativa usa NSOpenPanel.
    """
    script = 'POSIX path of (choose folder with prompt "Scegli la cartella di destinazione")'
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=180, check=False,
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except subprocess.TimeoutExpired:
        return ""


def idle_watchdog() -> None:
    """Chiude il programma se la pagina è chiusa da tempo e non scarica nulla."""
    while True:
        time.sleep(30)
        with STATE.lock:
            idle = time.time() - STATE.last_poll
            running = STATE.running
        if not running and idle > IDLE_EXIT_SECONDS:
            os._exit(0)


# ================================================================== pagina web
PAGE = (PROJECT_DIR / "gui_page.html").read_text(encoding="utf-8")


def main() -> None:
    url = f"http://{HOST}:{PORT}"
    try:
        server = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError:
        # Il server è già in esecuzione.
        if not os.environ.get("GUI_NO_BROWSER"):
            webbrowser.open(url)
        return

    STATE.log("Pronto. Incolla un link e premi Scarica.")
    threading.Thread(target=speed_sampler, daemon=True).start()
    if not os.environ.get("GUI_NO_BROWSER"):
        threading.Thread(target=idle_watchdog, daemon=True).start()
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
