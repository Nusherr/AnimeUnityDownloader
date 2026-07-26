"""Download da altri siti tramite yt-dlp — funzione OPZIONALE e ISOLATA.

Usata solo dalla scheda "Altri siti". Se i binari in ./tools/ non esistono,
`ytdlp_available()` ritorna False e la scheda non compare: il programma
AnimeUnity resta identico. Non importa nulla da gui.py (comunica via callback).
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
ARCHIVE_NAME = ".ytdlp-archivio.txt"

# Formati per la selezione della qualità video
_VIDEO_FMT = {
    "best": "bv*+ba/b",
    "1080": "bv*[height<=1080]+ba/b[height<=1080]",
    "720": "bv*[height<=720]+ba/b[height<=720]",
    "480": "bv*[height<=480]+ba/b[height<=480]",
}

QUALITY_LABELS = {
    "best": "Migliore disponibile",
    "1080": "1080p",
    "720": "720p",
    "480": "480p",
    "audio": "Solo audio",
}

_AUDIO_QUALITY = {"best": "0", "320": "320K", "256": "256K", "192": "192K", "128": "128K"}

_PROGRESS_RE = re.compile(r"^GUIPROG\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)")
_PLAYLIST_RE = re.compile(r"Downloading item (\d+) of (\d+)")


def ytdlp_available() -> bool:
    return YTDLP_BIN.exists()


def _to_float(value: str):
    try:
        return float(value)
    except (ValueError, TypeError):
        return None


def _flag(options: dict, key: str) -> bool:
    return bool(options.get(key))


def fetch_title(url: str, timeout: int = 40) -> str | None:
    """Recupera il titolo (per l'etichetta) prima del download."""
    try:
        result = subprocess.run(
            [str(YTDLP_BIN), "--no-playlist", "--skip-download",
             "--playlist-items", "1", "--print", "%(title)s", url],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
        lines = [line for line in result.stdout.strip().splitlines() if line]
        return lines[0] if lines else None
    except (subprocess.TimeoutExpired, OSError):
        return None


def list_formats(url: str, timeout: int = 60) -> str:
    """Restituisce l'elenco leggibile dei formati/qualità disponibili."""
    try:
        result = subprocess.run(
            [str(YTDLP_BIN), "--no-playlist", "-F", url],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
        return result.stdout.strip() or result.stderr.strip() or "Nessun formato trovato."
    except (subprocess.TimeoutExpired, OSError) as err:
        return f"Impossibile leggere i formati: {err}"


def build_args(options: dict, download_path: str) -> list[str]:
    """Traduce le opzioni dell'interfaccia negli argomenti di yt-dlp."""
    quality = options.get("quality", "best")
    args: list[str] = ["--newline", "--no-mtime"]

    # --- Selezione formato / qualità -------------------------------------
    if quality == "audio":
        audio_fmt = options.get("audio_format", "mp3")
        args += ["-f", "ba/b", "-x", "--audio-format", audio_fmt]
        aq = _AUDIO_QUALITY.get(options.get("audio_quality", "best"), "0")
        args += ["--audio-quality", aq]
        if _flag(options, "keep_original"):
            args += ["-k"]
    else:
        args += ["-f", _VIDEO_FMT.get(quality, _VIDEO_FMT["best"])]
        container = options.get("container", "mp4")
        if container in ("mp4", "mkv"):
            args += ["--merge-output-format", container]
        if _flag(options, "recode") and options.get("recode_format"):
            args += ["--recode-video", options["recode_format"]]
        if _flag(options, "split_chapters"):
            args += ["--split-chapters"]

    # --- Contenuti extra (sottotitoli, metadati, ...) --------------------
    if _flag(options, "subtitles"):
        langs = options.get("sub_lang", "it,en") or "it,en"
        args += ["--write-subs", "--write-auto-subs", "--sub-langs", langs]
        if _flag(options, "sub_embed"):
            args += ["--embed-subs"]
    if _flag(options, "thumbnail"):
        args += ["--embed-thumbnail"]
    if _flag(options, "metadata"):
        args += ["--embed-metadata"]
    if _flag(options, "chapters"):
        args += ["--embed-chapters"]
    if _flag(options, "write_description"):
        args += ["--write-description"]
    if _flag(options, "write_comments"):
        args += ["--write-comments"]
    if _flag(options, "write_info"):
        args += ["--write-info-json"]

    # --- SponsorBlock ----------------------------------------------------
    sb_mode = options.get("sponsorblock", "off")
    if sb_mode in ("mark", "remove"):
        cats = options.get("sponsorblock_cats") or "all"
        if isinstance(cats, list):
            cats = ",".join(cats) if cats else "all"
        flag = "--sponsorblock-remove" if sb_mode == "remove" else "--sponsorblock-mark"
        args += [flag, cats]

    # --- Playlist e selezione -------------------------------------------
    if _flag(options, "playlist"):
        args += ["--yes-playlist"]
        if options.get("playlist_items"):
            args += ["--playlist-items", str(options["playlist_items"])]
        if _flag(options, "playlist_reverse"):
            args += ["--playlist-reverse"]
    else:
        args += ["--no-playlist"]
    if options.get("date_after"):
        args += ["--dateafter", str(options["date_after"])]
    if options.get("date_before"):
        args += ["--datebefore", str(options["date_before"])]
    if _flag(options, "download_archive"):
        args += ["--download-archive", str(Path(download_path) / ARCHIVE_NAME)]

    # --- Ritaglio e live -------------------------------------------------
    tfrom = (options.get("time_from") or "").strip()
    tto = (options.get("time_to") or "").strip()
    if tfrom or tto:
        args += ["--download-sections", f"*{tfrom or '0'}-{tto or 'inf'}"]
    if _flag(options, "live_from_start"):
        args += ["--live-from-start"]

    # --- Protezione ------------------------------------------------------
    if options.get("video_password"):
        args += ["--video-password", str(options["video_password"])]

    # --- Rete e robustezza ----------------------------------------------
    if _flag(options, "fast"):
        args += ["--concurrent-fragments", "4"]
    if options.get("rate_limit"):
        args += ["--limit-rate", f"{options['rate_limit']}M"]
    if options.get("proxy"):
        args += ["--proxy", str(options["proxy"])]
    if _flag(options, "geo_bypass"):
        args += ["--geo-bypass"]
    if options.get("sleep_interval"):
        args += ["--sleep-interval", str(options["sleep_interval"])]
    if options.get("retries"):
        args += ["--retries", str(options["retries"])]
    cookies = options.get("cookies_browser", "none")
    if cookies and cookies != "none":
        args += ["--cookies-from-browser", cookies]

    # --- Nomi file e cartelle -------------------------------------------
    template = (options.get("filename_template") or "").strip()
    if not template:
        template = "%(uploader)s/%(title)s.%(ext)s" \
            if _flag(options, "subfolder_channel") else "%(title)s.%(ext)s"
    args += ["-o", str(Path(download_path) / template)]

    if FFMPEG_BIN.exists():
        args += ["--ffmpeg-location", str(FFMPEG_BIN)]
    return args


def run_ytdlp_download(
    url: str,
    options: dict,
    download_path: str,
    cancel: threading.Event,
    on_progress: Callable[[float, float, float, object], None],
    on_stage: Callable[[str], None],
    on_playlist: Callable[[int, int], None],
    on_log: Callable[[str], None],
) -> None:
    """Scarica con yt-dlp inoltrando l'avanzamento tramite callback."""
    cmd = [
        str(YTDLP_BIN),
        "--progress-template",
        ("download:GUIPROG %(progress.downloaded_bytes)s "
         "%(progress.total_bytes)s %(progress.total_bytes_estimate)s "
         "%(progress.speed)s %(progress.eta)s"),
        *build_args(options, download_path),
        url,
    ]

    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
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
                continue

            pl = _PLAYLIST_RE.search(line)
            if pl:
                on_playlist(int(pl.group(1)), int(pl.group(2)))
            elif line.startswith("[Merger]") or "Merging formats" in line:
                on_stage("Unione video e audio…")
            elif line.startswith("[ExtractAudio]"):
                on_stage("Estrazione audio…")
            elif line.startswith("[SponsorBlock]"):
                on_stage("SponsorBlock…")
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
        on_log(f"yt-dlp: codice di uscita {returncode}")
        raise RuntimeError(
            "yt-dlp ha restituito un errore. Verifica il link e le opzioni scelte.")


class _Cancelled(Exception):
    """Annullamento interno (mappato su DownloadCancelled in gui.py)."""
