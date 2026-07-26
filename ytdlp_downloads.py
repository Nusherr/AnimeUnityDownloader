"""Download da altri siti tramite yt-dlp — funzione OPZIONALE e ISOLATA.

Questo modulo è completamente separato dal downloader di AnimeUnity: viene
usato solo dalla scheda "Altri siti". Se i binari in ./tools/ non esistono,
`ytdlp_available()` ritorna False e la scheda non compare nemmeno: il
programma AnimeUnity resta identico a prima.

Non importa nulla da gui.py: comunica tramite callback, così resta autonomo.
"""

from __future__ import annotations

import re
import subprocess
import threading
from pathlib import Path
from typing import Callable

PROJECT_DIR = Path(__file__).resolve().parent
YTDLP_BIN = PROJECT_DIR / "tools" / "yt-dlp"
FFMPEG_BIN = PROJECT_DIR / "tools" / "ffmpeg"

# Opzioni di qualità offerte nell'interfaccia → argomenti di yt-dlp
QUALITY_FORMATS = {
    "best": ["-f", "bv*+ba/b", "--merge-output-format", "mp4"],
    "1080": ["-f", "bv*[height<=1080]+ba/b[height<=1080]", "--merge-output-format", "mp4"],
    "720": ["-f", "bv*[height<=720]+ba/b[height<=720]", "--merge-output-format", "mp4"],
    "480": ["-f", "bv*[height<=480]+ba/b[height<=480]", "--merge-output-format", "mp4"],
    "audio": ["-f", "ba/b", "-x", "--audio-format", "mp3"],
}

QUALITY_LABELS = {
    "best": "Migliore disponibile",
    "1080": "1080p",
    "720": "720p",
    "480": "480p",
    "audio": "Solo audio (MP3)",
}

_PROGRESS_RE = re.compile(
    r"^GUIPROG\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)")


def ytdlp_available() -> bool:
    """La funzione è disponibile solo se il binario yt-dlp è presente."""
    return YTDLP_BIN.exists()


def _to_float(value: str) -> float | None:
    try:
        return float(value)
    except (ValueError, TypeError):
        return None


def fetch_title(url: str, timeout: int = 30) -> str | None:
    """Recupera il titolo del video prima del download (per l'etichetta)."""
    try:
        result = subprocess.run(
            [str(YTDLP_BIN), "--no-playlist", "--skip-download",
             "--print", "%(title)s", url],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
        title = result.stdout.strip().splitlines()
        return title[0] if title else None
    except (subprocess.TimeoutExpired, OSError):
        return None


def run_ytdlp_download(
    url: str,
    quality: str,
    download_path: str,
    cancel: threading.Event,
    on_progress: Callable[[float, float, float, float], None],
    on_stage: Callable[[str], None],
    on_log: Callable[[str], None],
) -> None:
    """Scarica un video con yt-dlp inoltrando l'avanzamento tramite callback.

    - on_progress(scaricati, totale, velocità_bps, eta_s): valori 0/None se ignoti
    - on_stage(testo): descrizione della fase corrente (es. "Video", "Audio")
    - on_log(testo): riga per il log dettagli
    """
    fmt_args = QUALITY_FORMATS.get(quality, QUALITY_FORMATS["best"])
    out_template = str(Path(download_path) / "%(title)s.%(ext)s")

    cmd = [
        str(YTDLP_BIN),
        "--no-playlist",
        "--newline",
        "--no-mtime",
        "--progress-template",
        ("download:GUIPROG %(progress.downloaded_bytes)s "
         "%(progress.total_bytes)s %(progress.total_bytes_estimate)s "
         "%(progress.speed)s %(progress.eta)s"),
        *fmt_args,
        "-o", out_template,
        url,
    ]
    if FFMPEG_BIN.exists():
        cmd += ["--ffmpeg-location", str(FFMPEG_BIN)]

    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    )

    try:
        for line in proc.stdout:
            if cancel.is_set():
                proc.terminate()
                raise _Cancelled

            line = line.rstrip("\n")
            match = _PROGRESS_RE.match(line)
            if match:
                downloaded = _to_float(match.group(1)) or 0.0
                total = _to_float(match.group(2)) or _to_float(match.group(3)) or 0.0
                speed = _to_float(match.group(4)) or 0.0
                eta = _to_float(match.group(5))
                on_progress(downloaded, total, speed, eta)
            elif line.startswith("[Merger]") or "Merging formats" in line:
                on_stage("Unione video e audio…")
            elif line.startswith("[ExtractAudio]"):
                on_stage("Estrazione audio…")
            elif line.startswith("[download] Destination:"):
                on_stage("Download in corso…")
            elif line.startswith("ERROR:"):
                on_log(line)
    finally:
        proc.stdout.close()

    returncode = proc.wait()
    if cancel.is_set():
        raise _Cancelled
    if returncode != 0:
        message = "yt-dlp ha restituito un errore. Verifica che il link sia valido e supportato."
        on_log(f"yt-dlp: codice di uscita {returncode}")
        raise RuntimeError(message)


class _Cancelled(Exception):
    """Segnala l'annullamento interno (mappato su DownloadCancelled in gui.py)."""
