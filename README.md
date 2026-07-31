# Vault

> App per macOS che scarica film, serie, anime e manga — e guarda in streaming
> senza scaricare niente.
> **Pronta all'uso**: nessun Python da installare, nessun terminale.

![Vault](assets/vault-vibravid.png)

## ⬇️ Scarica l'app

1. Vai alla pagina **[Releases](../../releases/latest)** e scarica il DMG
2. Aprilo e **trascina Vault nella cartella Applicazioni**
3. Avviala da Applicazioni o dal Launchpad

> Al **primo avvio**, se macOS dice *"impossibile verificare lo sviluppatore"*,
> fai **clic destro sull'app → Apri → Apri**. Serve solo la prima volta.

Dentro c'è già tutto il necessario: **non devi installare Python** né altro.

**Requisiti:** macOS 26 e un Mac con chip Apple.

## Cosa fa

Quattro motori nella stessa finestra, uno per scheda.

### VibraVid — film, serie e anime da 18 siti

La ricerca è dentro l'app: nessun link da incollare. Scegli il titolo, poi
stagione ed episodi, e scarichi.

- **18 siti**, fra cui StreamingCommunity, AnimeWorld, AltaDefinizione, RaiPlay,
  Mediaset Infinity, Crunchyroll, Discovery+, Pluto TV, Tubi
- **Stagioni ed episodi** — tutta la serie, una stagione, o solo quelli che scegli
- **Audio e sottotitoli** in italiano o inglese
- **Durata complessiva** calcolata prima di cominciare
- I film saltano direttamente al download: non hanno stagioni da leggere

### ▶︎ Guarda senza scaricare

Il pulsante ▶︎ risolve il flusso e lo apre in **[IINA](https://iina.io)**, senza
occupare un byte di disco. Il titolo compare leggibile nella finestra del
lettore, e i segmenti che non arrivano vengono richiesti di nuovo invece di
essere saltati, così la riproduzione non fa salti in avanti.

Funziona sui siti che consegnano un flusso in chiaro. I 9 che lo consegnano
cifrato — Crunchyroll, RaiPlay, Mediaset Infinity, Discovery+ e i canali del
gruppo — restano solo scaricabili: un lettore esterno riceverebbe dati
illeggibili, quindi lì il pulsante non compare affatto.

### AnimeUnity — download singoli e in batch

Un anime alla volta oppure una lista intera, con scelta degli episodi: tutti, un
intervallo (dal 5 al 10) o quelli specifici che indichi.

<p align="center">
  <img src="assets/vault-animeunity.png" width="72%" alt="La scheda AnimeUnity">
</p>

### MangaWorld — manga, capitoli e PDF/CBZ

Lo stesso campo cerca e apre i link: se scrivi un titolo lo cerca, se incolli
un indirizzo lo apre. I risultati mostrano tipo, stato e autore, che su
MangaWorld servono a distinguere fra titoli quasi omonimi.

Scelto il manga, l'app dice **quanti capitoli** ci sono e li fa prendere tutti,
per intervallo o singolarmente. Si sceglie **come salvarli** — PDF, CBZ o
immagini sciolte — e la scelta è esclusiva: chiedendo un PDF non ti ritrovi
anche la cartella di pagine a occupare il doppio.

### Altri siti — yt-dlp

Per tutto il resto: incolli un link e yt-dlp fa il lavoro, con il pannello
completo delle sue opzioni a disposizione.

## In ogni scheda

- **Avanzamento in tempo reale** — velocità, dati scaricati, tempo rimanente
- **Coda dei download**, con quelli completati sotto
- **Cronologia** che resta dopo la chiusura: cosa hai scaricato, quanto pesa, quando
- **Ripresa automatica** se cade la connessione
- **Salta i doppioni**: quello che c'è già non viene riscaricato
- **Il Mac non si addormenta** mentre un download è in corso
- **Cartella a scelta**, con notifica a fine download
- **Tema chiaro e scuro** automatici, interfaccia nativa in Liquid Glass

## Si tiene aggiornata da sola

Una volta al giorno Vault guarda se ne è uscita una versione nuova. Se c'è, lo
dice e — accettando — la scarica, si sostituisce e si riavvia: niente da
scaricare a mano, niente da trascinare.

Anche **yt-dlp** si aggiorna per conto suo, ed è quello che conta di più: i siti
cambiano di continuo e la correzione arriva con una versione nuova, spesso ogni
settimana. Senza, la scheda "Altri siti" invecchierebbe male.

---

<details>
<summary><b>Uso da riga di comando (avanzato, facoltativo)</b></summary>

Gli script Python originali di AnimeUnity restano utilizzabili da soli.
Richiedono Python 3 e le dipendenze del progetto:

```bash
pip install -r requirements.txt
```

Scaricare un anime (tutti gli episodi, un intervallo o una lista):

```bash
python3 anime_downloader.py <url_anime>
python3 anime_downloader.py <url_anime> --start 5 --end 10
python3 anime_downloader.py <url_anime> --episodes 3,7,12
```

Download in batch: un URL per riga in `URLs.txt`, poi:

```bash
python3 main.py
```

Cartella di destinazione personalizzata: aggiungere `--custom-path <percorso>`.

</details>

<details>
<summary><b>Sviluppo e compilazione</b></summary>

L'app è divisa in due pezzi: un'interfaccia nativa SwiftUI
(`macos_app/native/GlassApp.swift`) e un motore Python (`gui.py`) che gira come
piccolo server locale su `127.0.0.1:8765`. L'interfaccia non scarica nulla da
sola: parla col motore via API JSON.

- **Ricompilare e installare l'interfaccia:** `macos_app/native/build_native.sh`
- **Produrre il pacchetto autosufficiente e il DMG:** `macos_app/native/make_dist.sh`
  (incorpora un Python portatile, VibraVid, ffmpeg e yt-dlp; solo Apple Silicon)

Serve macOS 26 e i Command Line Tools; Xcode non è necessario.

</details>

## Crediti e licenza

Vault mette insieme il lavoro di altri, e va detto chiaramente:

- Il downloader AnimeUnity a riga di comando è di
  **[Lysagxra/AnimeUnityDownloader](https://github.com/Lysagxra/AnimeUnityDownloader)**
- Il downloader dei manga è di
  **[Lysagxra/MangaWorldDownloader](https://github.com/Lysagxra/MangaWorldDownloader)**,
  incluso nel pacchetto
- La ricerca multi-sito e la risoluzione dei flussi sono di
  **[AstraeLabs/VibraVid](https://github.com/AstraeLabs/VibraVid)**, incluso nel pacchetto
- Il lettore consigliato per la riproduzione diretta è **[IINA](https://iina.io)**

L'interfaccia nativa per macOS, l'integrazione fra i tre motori e
l'impacchettamento sono l'aggiunta di questo progetto.

Distribuito sotto licenza **GPL-3.0**, la stessa dei progetti da cui deriva.
