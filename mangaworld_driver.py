"""Avvia MangaWorldDownloader per conto di Vault.

Non si usa il suo ``manga_downloader.py`` per tre motivi.

Il primo è un difetto suo. Passando ``--start``/``--end``, i link dei capitoli
vengono raccolti con gli indici validati (0-based) mentre l'elenco delle pagine
viene affettato con quelli grezzi, che sono 1-based::

    download_links = await extract_download_links(chapter_urls, start_chapter, end_chapter, ...)
    download_chapter_with_progress(manga_name, download_links,
                                   pages_per_chapter[start_index:end_index], ...)

Chiedendo il solo primo capitolo lo slice diventa ``[1:1]``, cioè vuoto: il
programma esce con successo senza scaricare niente. Qui gli indici validati si
usano per entrambi.

Il secondo è la cartella di destinazione, che nel loro config è fissa e
relativa (``"Downloads"``): lasciandola stare, i file finirebbero dentro una
sottocartella "Downloads" annidata in quella scelta dall'utente.

Il terzo è l'importazione. Il pacchetto di MangaWorld si chiama ``src``, come
quello di AnimeUnity che sta già dentro Vault: eseguendo questo file dalla
cartella del progetto verrebbe importato quello sbagliato. Per questo la
cartella di MangaWorld va passata in ``--progetto`` e messa davanti a tutto nel
percorso di ricerca, togliendo la propria.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path


def _prepara_percorso(progetto: Path) -> None:
    """Mette il pacchetto di MangaWorld davanti al nostro, che ha lo stesso nome."""
    mio = Path(__file__).resolve().parent
    sys.path = [p for p in sys.path if p and Path(p).resolve() != mio]
    sys.path.insert(0, str(progetto))


def _conta(url: str, extract_manga_info, fetch_page) -> int:  # noqa: ANN001
    """Stampa nome e numero di capitoli, con una sola richiesta.

    Non si usa il loro ``extract_chapters_info``: quello, per ogni capitolo,
    ne apre la pagina per contarne le immagini — trecento capitoli, trecento
    richieste, e qui serve solo sapere quanti sono. Il selettore è però lo
    stesso che usano loro, così i due conteggi non possono divergere.
    """
    import json

    async def leggi() -> None:
        _, nome, _ = extract_manga_info(url)
        soup = await fetch_page(url)
        voci = [
            a for a in soup.find_all("a", {"class": "chap", "title": True})
            if "/read/" in (a.get("href") or "")
        ]
        print(json.dumps({"nome": nome, "capitoli": len(voci)}, ensure_ascii=False))

    asyncio.run(leggi())
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Ponte fra Vault e MangaWorldDownloader.")
    ap.add_argument("--progetto", required=True, help="cartella di MangaWorldDownloader")
    ap.add_argument("--url", required=True)
    ap.add_argument("--start", type=int, default=None)
    ap.add_argument("--end", type=int, default=None)
    ap.add_argument("--formato", default=None, choices=["pdf", "cbz"])
    ap.add_argument("--destinazione", default="")
    ap.add_argument("--conta", action="store_true",
                    help="stampa quanti capitoli ha il manga, senza scaricare")
    args = ap.parse_args()
    if not args.conta and not args.destinazione:
        ap.error("--destinazione è obbligatoria quando si scarica")

    progetto = Path(args.progetto).expanduser().resolve()
    if not (progetto / "manga_downloader.py").exists():
        sys.stderr.write(f"MangaWorld non trovato in {progetto}\n")
        return 2
    _prepara_percorso(progetto)

    # L'ordine degli import conta: gli altri moduli leggono DOWNLOAD_FOLDER per
    # valore nel momento in cui vengono importati, quindi va sostituito prima.
    import src.config as cfg
    if args.destinazione:
        cfg.DOWNLOAD_FOLDER = str(Path(args.destinazione).expanduser())

    from src.format_utils import extract_manga_info
    from src.general_utils import fetch_page

    if args.conta:
        return _conta(args.url, extract_manga_info, fetch_page)

    from manga_downloader import download_chapter_with_progress
    from src.crawler_utils import (
        extract_chapters_info,
        extract_download_links,
        extract_manga_type,
    )
    from src.general_utils import validate_index_range

    async def esegui() -> None:
        _, nome, slug = extract_manga_info(args.url)
        soup = await fetch_page(args.url)
        tipo = extract_manga_type(soup, slug)

        capitoli, pagine = await extract_chapters_info(soup)
        if not capitoli:
            sys.stderr.write("Nessun capitolo trovato a questo indirizzo.\n")
            return

        inizio, fine = validate_index_range(args.start, args.end, len(capitoli))
        link = await extract_download_links(capitoli, inizio, fine, tipo)

        # Qui la correzione: le pagine si affettano con gli stessi indici con
        # cui sono stati raccolti i link, non con quelli grezzi.
        download_chapter_with_progress(
            nome, link, pagine[inizio:fine], output_format=args.formato,
        )

    asyncio.run(esegui())
    return 0


if __name__ == "__main__":
    sys.exit(main())
