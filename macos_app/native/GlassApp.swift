// Vault — interfaccia nativa SwiftUI con Liquid Glass.
//
// Sostituisce la pagina HTML mostrata nella WKWebView: parla con lo stesso
// server Python (gui.py su 127.0.0.1:8765) tramite le sue API JSON, quindi
// il motore di download resta identico e non va toccato.
//
// Compilazione (vedi build_native.sh):
//   swiftc -O -parse-as-library -o GlassApp GlassApp.swift
//
// Richiede macOS 26 (Tahoe) per le API Liquid Glass.

import SwiftUI

let serverBase = URL(string: "http://127.0.0.1:8765")!
let accent = Color(red: 0.83, green: 0.0, blue: 0.25)

/// Accento che segue lo stato della finestra: quando perde il fuoco si smorza,
/// come fanno da soli i controlli nativi di macOS. Tutto ciò che disegniamo a
/// mano deve passare di qui, altrimenti resterebbe acceso mentre il resto
/// dell'interfaccia è spento.
func accento(_ stato: ControlActiveState) -> Color {
    stato == .inactive ? Color.secondary.opacity(0.55) : accent
}

// ============================================================ dati dal server
struct Overall: Decodable {
    var label: String = ""
    var total: Double = 0
    var done: Double = 0
    var stage: String?
    /// Che cosa sta contando `total`: "episodi" per AnimeUnity, "tracce" per
    /// VibraVid (video, audio, sottotitoli). Serve a non chiamare episodi
    /// quello che episodi non è.
    var unit: String?
}

struct EpisodeRow: Decodable, Identifiable {
    var desc: String
    var pct: Double
    var id: String { desc }

    /// True per le righe che descrivono un flusso interno anziché un episodio:
    /// "Vid [H.264, AAC] 1920x1080", "Aud it-IT [DEFAULT]", "Sub [vtt] en-US".
    var isTraccia: Bool {
        let t = desc.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("Vid ") || t.hasPrefix("Aud ") || t.hasPrefix("Sub ")
    }
}

/// Elemento in attesa: parte quando il download in corso finisce.
struct QueueItem: Decodable, Identifiable {
    var id: Int
    var label: String
    var detail: String
}

struct CompletedRow: Decodable, Identifiable {
    var label: String
    var path: String
    var size: Double
    /// Che cosa è stato scaricato: "capitoli 2, 4 · PDF", "S01 · E03"…
    var detail: String = ""
    /// Quando, in secondi dal 1970. Manca nelle voci salvate prima che la
    /// cronologia esistesse, quindi è opzionale.
    var when: Double? = nil
    var id: String { "\(path)|\(label)|\(when ?? 0)" }

    /// Solo il giorno, senza ora: in una cronologia serve sapere quando più o
    /// meno, non il minuto esatto.
    var quando: String {
        guard let t = when else { return "" }
        let data = Date(timeIntervalSince1970: t)
        if Calendar.current.isDateInToday(data) { return "oggi" }
        if Calendar.current.isDateInYesterday(data) { return "ieri" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM"
        return f.string(from: data)
    }
}

struct ServerState: Decodable {
    var running: Bool = false
    var log: [String] = []
    var overall: Overall = Overall()
    var episodes: [EpisodeRow] = []
    var completed: [CompletedRow] = []
    var speed_bps: Double = 0
    var bytes_now: Double = 0
    var bytes_total_est: Double?
    var eta_s: Double?
    var last_error: String?
    var error_seq: Int = 0
    var queue: [QueueItem] = []
    var ytdlp: Bool = false
    var vibravid: Bool = false
    var mangaworld: Bool = false
}

// ================================================================== modello
@MainActor
final class AppModel: ObservableObject {
    /// Unico per tutta l'app: la finestra e l'icona nella barra dei menu
    /// devono leggere lo stesso stato, altrimenti mostrerebbero cose diverse.
    static let shared = AppModel()

    @Published var state = ServerState()
    @Published var reachable = false
    @Published var destination = ""          // cartella scelta ("" = predefinita)
    @Published var searchResults: [VibraResult] = []
    @Published var searching = false

    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            Task { await self.poll() }
        }
        Task { await poll() }
    }

    func poll() async {
        guard let data = try? await get("/state"),
              let decoded = try? JSONDecoder().decode(ServerState.self, from: data)
        else { reachable = false; return }
        reachable = true
        state = decoded
    }

    // ------------------------------------------------------------ rete
    private func get(_ path: String) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: serverBase.appending(path: path))
        return data
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any]) async -> [String: Any] {
        var req = URLRequest(url: serverBase.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        if let err = obj["error"] as? String { showAlert(err) }
        return obj
    }

    func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // -------------------------------------------------------- azioni
    func cancel() { Task { await post("/cancel", [:]) } }
    func rimuoviDallaCoda(_ id: Int) { Task { await post("/queue_remove", ["id": id]) } }
    func clearCompleted() { Task { await post("/clear_completed", [:]) } }
    func openDestination() { Task { await post("/open_folder", ["path": destination]) } }
    func open(path: String) { Task { await post("/open_path", ["path": path]) } }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scegli"
        panel.message = "Scegli la cartella di destinazione"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path
        }
    }

    var destinationName: String {
        destination.isEmpty ? "Downloads"
            : (URL(fileURLWithPath: destination).lastPathComponent)
    }
}

struct VibraResult: Decodable, Identifiable {
    var name: String
    var type: String
    var year: String
    var index: Int = 0
    var id: Int { index }

    enum CodingKeys: String, CodingKey { case name, type, year }

    /// I siti non parlano lo stesso vocabolario: streamingcommunity risponde
    /// "tv" e "movie" minuscoli, animeunity "TV", "Movie", "ONA", "Special".
    /// Al flusso interessa una sola distinzione — film oppure no — e va fatta
    /// senza badare alle maiuscole, altrimenti su animeunity nessun confronto
    /// va mai a segno e perfino i film finiscono trattati da serie.
    var isMovie: Bool {
        ["movie", "film"].contains(type.lowercased())
    }

    /// Etichetta mostrata accanto al titolo nei risultati. "ONA" e "Special"
    /// dicono qualcosa a chi cerca anime, quindi si conservano invece di
    /// appiattirle tutte su "serie".
    var kind: String {
        if isMovie { return "film" }
        let t = type.lowercased()
        return (t.isEmpty || t == "tv") ? "serie" : t
    }
}

// ================================================================ formattazione
func fmtBytes(_ b: Double) -> String {
    if b >= 1e9 { return String(format: "%.2f GB", b / 1e9).replacingOccurrences(of: ".", with: ",") }
    if b >= 1e6 { return "\(Int(b / 1e6)) MB" }
    return "\(Int(b / 1e3)) kB"
}

func fmtSpeed(_ bps: Double) -> String {
    String(format: "%.1f MB/s", bps / 1e6).replacingOccurrences(of: ".", with: ",")
}

func fmtEta(_ s: Double) -> String {
    s < 90 ? "meno di 2 minuti rimanenti" : "circa \(Int((s / 60).rounded())) minuti rimanenti"
}

// ==================================================================== schede
/// L'ordine dei casi è quello con cui appaiono nella barra.
/// "Singolo" e "Batch" erano due schede per lo stesso sito: ora sono un'unica
/// scheda AnimeUnity con la modalità scelta al suo interno.
enum Tab: String, CaseIterable, Identifiable {
    case vibra = "VibraVid", animeunity = "AnimeUnity"
    case manga = "MangaWorld", other = "Altri siti"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .vibra:      return "film.stack"
        case .animeunity: return "square.and.arrow.down"
        case .manga:      return "books.vertical"
        case .other:      return "globe"
        }
    }
}


// Pulsante con sola icona SF Symbol. Essendo senza testo porta con sé il
// suggerimento a comparsa e l'etichetta per VoiceOver, altrimenti l'azione
// resterebbe indovinabile solo dal disegno.
struct IconButton: View {
    let symbol: String
    let hint: String                 // suggerimento + etichetta accessibile
    var prominent: Bool = false      // azione principale: tinta d'accento
    var size: CGFloat = 29
    let action: () -> Void
    @Environment(\.controlActiveState) private var stato

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(.circle)
                // Il simbolo può cambiare mentre il pulsante resta lo stesso
                // (freccia → spunta alla conferma): così si trasforma invece
                // di sparire e riapparire.
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        // Niente cerchio pieno sotto: prima il vetro era solo un velo su una
        // pastiglia opaca e non si vedeva. Qui il colore lo porta la tinta del
        // vetro stesso, così resta traslucido e lascia passare lo sfondo.
        .glassEffect(prominent
                        ? .regular.tint(accento(stato).opacity(0.8)).interactive()
                        : .regular.interactive(),
                     in: .circle)
        .help(hint)
        .accessibilityLabel(hint)
    }
}

/// Pulsante di avvio del download, che conferma di essere stato premuto.
///
/// Il lavoro parte in un sottoprocesso e la barra compare solo quando questo
/// risponde: nel frattempo a schermo non cambiava nulla e non si capiva se il
/// clic fosse andato a segno, tanto che veniva naturale premere una seconda
/// volta. Qui la freccia diventa una spunta per un istante, e nel frattempo il
/// pulsante si disabilita così il doppio invio non è nemmeno possibile.
struct DownloadButton: View {
    var inCoda: Bool                     // c'è già un download in corso
    var attivo: Bool
    let action: () -> Void
    @State private var confermato = false

    var body: some View {
        IconButton(symbol: confermato ? "checkmark" : "arrow.down.to.line",
                   hint: confermato
                       ? (inCoda ? "Aggiunto alla coda" : "Download avviato")
                       : (inCoda ? "Aggiungi alla coda" : "Scarica"),
                   prominent: true) {
            action()
            withAnimation(.snappy) { confermato = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy) { confermato = false }
            }
        }
        .disabled(!attivo || confermato)
        .opacity(attivo ? 1 : 0.4)
    }
}

// Selettore a segmenti in vetro: stessa logica della barra schede, in piccolo.
// Sostituisce il Picker di sistema, che userebbe il blu invece dell'accento.
struct SegOption: Identifiable {
    let id: String
    let label: String
}

struct GlassSegmented: View {
    @Environment(\.controlActiveState) private var stato
    @Binding var selection: String
    let options: [SegOption]
    @State private var frames: [String: CGRect] = [:]

    var body: some View {
        let box = frames[selection] ?? .zero
        GlassEffectContainer(spacing: 20) {
            ZStack(alignment: .leading) {
                if box != .zero {
                    Capsule()
                        .fill(accento(stato).opacity(0.22))
                        .glassEffect(.regular.tint(accento(stato).opacity(0.34)).interactive(),
                                     in: .capsule)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX)
                }

                HStack(spacing: 2) {
                    ForEach(options) { opt in
                        let on = (opt.id == selection)
                        Button {
                            withAnimation(.smooth(duration: 0.38, extraBounce: 0.3)) {
                                selection = opt.id
                            }
                        } label: {
                            Text(opt.label)
                                .font(.system(size: 12, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 5)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: TabFrames.self,
                                value: [opt.id: geo.frame(in: .named("seg"))])
                        })
                    }
                }
            }
            .coordinateSpace(name: "seg")
            .onPreferenceChange(TabFrames.self) { frames = $0 }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

// Barra schede fluttuante in Liquid Glass (stile Apple Music):
// una capsula di vetro sopra la quale scorre il contenuto; la scheda attiva
// ha la sua capsula che si sposta fluidamente grazie a glassEffectID.
// Misura la posizione di ogni scheda, così l'indicatore può essere posizionato
// esplicitamente: una sola vista che si sposta, mai ricreata.
struct TabFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct FloatingTabBar: View {
    @Environment(\.controlActiveState) private var stato
    @Binding var tab: Tab
    let tabs: [Tab]
    @State private var frames: [String: CGRect] = [:]

    var body: some View {
        // Spacing ampio: dentro un GlassEffectContainer le forme di vetro vicine
        // si fondono, ed è questo che dà l'effetto "liquido" mentre l'indicatore
        // scorre da una scheda all'altra.
        let box = frames[tab.rawValue] ?? .zero
        GlassEffectContainer(spacing: 26) {
            ZStack(alignment: .leading) {
                // Indicatore unico: dimensione e posizione imposte a mano, quindi
                // si sposta invece di sparire e riapparire. Tinto d'accento così
                // resta leggibile anche su fondi poco contrastati.
                if box != .zero {
                    Capsule()
                        .fill(accento(stato).opacity(0.22))
                        .glassEffect(.regular.tint(accento(stato).opacity(0.34)).interactive(),
                                     in: .capsule)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX)
                }

                HStack(spacing: 2) {
                    ForEach(tabs) { t in
                        let on = (t == tab)
                        Button {
                            withAnimation(.smooth(duration: 0.45, extraBounce: 0.32)) {
                                tab = t
                            }
                        } label: {
                            Text(t.rawValue)
                                .font(.system(size: 13, weight: on ? .semibold : .medium))
                                .padding(.horizontal, 17)
                                .padding(.vertical, 8)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: TabFrames.self,
                                value: [t.rawValue: geo.frame(in: .named("tabbar"))])
                        })
                    }
                }
            }
            .coordinateSpace(name: "tabbar")
            .onPreferenceChange(TabFrames.self) { frames = $0 }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

// ================================================================== interfaccia
struct ContentView: View {
    @StateObject private var model = AppModel.shared
    @State private var tab: Tab = .vibra
    @State private var showLog = false
    @State private var schermoIntero = false

    /// Permesso che impedisce al Mac di addormentarsi mentre si scarica.
    @State private var veglia: NSObjectProtocol? = nil

    // Le schede opzionali compaiono solo se il motore corrispondente c'è.
    var visibleTabs: [Tab] {
        Tab.allCases.filter { t in
            switch t {
            case .other: return model.state.ytdlp
            case .vibra: return model.state.vibravid
            case .manga: return model.state.mangaworld
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // --- Livello CONTENUTO: i moduli di inserimento ---
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Group {
                        switch tab {
                        case .vibra:      VibraPane(model: model)
                        case .animeunity: AnimeUnityPane(model: model)
                        case .manga:      MangaPane(model: model)
                        case .other:      OtherPane(model: model)
                        }
                    }
                    // La barra schede cambia `tab` dentro una molla con rimbalzo,
                    // ed è giusto così: è quella a dare il movimento liquido
                    // all'indicatore. Ma un rimbalzo su un'opacità la porta oltre
                    // il valore finale e poi indietro, e mentre le due schede si
                    // incrociano i controlli si schiariscono e riscuriscono — il
                    // selettore del sito, chiaro e piatto, è dove si nota di più.
                    // La transizione si porta quindi la propria curva, senza
                    // rimbalzo, così la dissolvenza procede in un verso solo.
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                            .animation(.easeOut(duration: 0.24))
                    )

                    DestinationRow(model: model)
                    Divider()
                    DownloadsSection(model: model, showLog: $showLog)
                }
                .padding(22)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)   // lascia passare la traslucenza
        }
        .frame(minWidth: 520, minHeight: 560)
        // Sfondo traslucido della finestra, via API nativa di SwiftUI: è il
        // sistema a gestirne la composizione, quindi non serve alcun intervento
        // manuale su opacità, ridisegni o cambi di scrivania.
        //
        // Tranne che a schermo intero. Lì dietro la finestra non c'è più la
        // scrivania ma il fondo nero dello spazio dedicato, e un materiale
        // sottile non fa che filtrarlo: l'interfaccia si incupiva tutta, anche
        // in tema chiaro. A schermo intero non c'è nulla da lasciar trasparire,
        // quindi si usa il colore di sfondo delle finestre, che segue il tema.
        .containerBackground(for: .window) {
            if schermoIntero {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didEnterFullScreenNotification)) { _ in
            schermoIntero = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didExitFullScreenNotification)) { _ in
            schermoIntero = false
        }
        // Il download in corso non galleggia più sopra il contenuto: vive
        // dentro la sezione DOWNLOAD, insieme a quelli completati.
        //
        // La barra delle schede invece galleggia in alto: il contenuto le scorre sotto, ed è questo
        // che rende visibile la rifrazione del vetro.
        .safeAreaInset(edge: .top) {
            FloatingTabBar(tab: $tab, tabs: visibleTabs)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .animation(.snappy, value: model.state.running)
        .onAppear { model.start() }
        // Un download lungo non deve essere interrotto dal Mac che si addormenta.
        .onChange(of: model.state.running) { _, inCorso in
            vegliaSuiDownload(inCorso)
        }
    }

    /// Tiene sveglio il Mac finché c'è un download in corso.
    ///
    /// Si blocca il solo sonno di sistema: lo schermo può spegnersi
    /// tranquillamente, e non c'è motivo di tenerlo acceso per ore. Il permesso
    /// viene restituito appena la coda si svuota, così il Mac torna a
    /// comportarsi normalmente senza bisogno di riavviare l'app.
    func vegliaSuiDownload(_ inCorso: Bool) {
        if inCorso, veglia == nil {
            veglia = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Download in corso")
        } else if !inCorso, let attiva = veglia {
            ProcessInfo.processInfo.endActivity(attiva)
            veglia = nil
        }
    }
}

// ------------------------------------------------------------- AnimeUnity
/// Un'unica scheda per AnimeUnity, con la modalità scelta al suo interno.
/// In "Elenco" la scelta episodi non compare affatto: il motore scarica ogni
/// anime per intero, e un controllo che non ha effetto è peggio che assente.
struct AnimeUnityPane: View {
    @ObservedObject var model: AppModel
    @State private var modalita = "singolo"
    @State private var url = ""
    @State private var mode = "all"
    @State private var start = ""
    @State private var end = ""
    @State private var list = ""
    @State private var elenco = ""

    var unSolo: Bool { modalita == "singolo" }
    var linkValido: Bool { url.contains("/anime/") }

    /// Almeno una riga non vuota nell'elenco.
    var haLink: Bool {
        elenco.split(separator: "\n").contains {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var pronto: Bool { unSolo ? linkValido : haLink }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Modalità").font(.caption).foregroundStyle(.secondary)
                GlassSegmented(selection: $modalita, options: [
                    SegOption(id: "singolo", label: "Un anime"),
                    SegOption(id: "elenco", label: "Elenco"),
                ])
            }

            if unSolo {
                TextField("Incolla il link dell'anime da AnimeUnity…", text: $url)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .onSubmit { if linkValido { avvia() } }
            } else {
                // Campo multiriga nativo: stesso TextField del caso singolo,
                // con asse verticale. Prima era un TextEditor con sfondo,
                // angoli e segnaposto disegnati a mano — TextEditor un
                // segnaposto non ce l'ha, e si vedeva.
                TextField("Un link per riga…", text: $elenco, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .lineLimit(4...10)
                HStack {
                    Button("Ricarica elenco") { caricaElenco() }.buttonStyle(.link)
                    Button("Salva elenco") {
                        Task { await model.post("/save_urls", ["content": elenco]) }
                    }.buttonStyle(.link)
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                // La scelta episodi vale solo per un anime alla volta.
                if unSolo {
                    Text("Episodi").font(.caption).foregroundStyle(.secondary)
                    GlassSegmented(selection: $mode, options: [
                        SegOption(id: "all", label: "Tutti"),
                        SegOption(id: "range", label: "Intervallo"),
                        SegOption(id: "list", label: "Specifici"),
                    ])
                } else {
                    Text("Ogni anime dell'elenco viene scaricato per intero")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                DownloadButton(inCoda: model.state.running, attivo: pronto) { avvia() }
            }

            if unSolo && mode == "range" {
                HStack(spacing: 10) {
                    Text("da").foregroundStyle(.secondary)
                    TextField("", text: $start).frame(width: 62)
                    Text("a").foregroundStyle(.secondary)
                    TextField("", text: $end).frame(width: 62)
                    Text("vuoto = dall'inizio / fino alla fine")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .textFieldStyle(.roundedBorder)
            } else if unSolo && mode == "list" {
                HStack(spacing: 10) {
                    TextField("3, 7, 12", text: $list).frame(width: 180)
                        .textFieldStyle(.roundedBorder)
                    Text("numeri separati da virgola")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .animation(.snappy, value: modalita)
        .animation(.snappy, value: mode)
        .task { caricaElenco() }
    }

    func avvia() {
        Task {
            if unSolo {
                await model.post("/download", [
                    "url": url, "mode": mode, "start": start, "end": end,
                    "episodes": list, "path": model.destination,
                ])
            } else {
                await model.post("/batch", [
                    "urls": elenco, "path": model.destination,
                ])
            }
        }
    }

    func caricaElenco() {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(
                    from: serverBase.appending(path: "/urls")),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = obj["content"] as? String else { return }
            elenco = content
        }
    }
}

struct OtherPane: View {
    @ObservedObject var model: AppModel
    @State private var url = ""
    @State private var quality = "best"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Incolla un link (YouTube, Vimeo, …)", text: $url)
                .textFieldStyle(.roundedBorder).controlSize(.large)

            HStack(spacing: 12) {
                Text("Qualità").foregroundStyle(.secondary).font(.callout)
                GlassSegmented(selection: $quality, options: [
                    SegOption(id: "best", label: "Migliore"),
                    SegOption(id: "1080", label: "1080p"),
                    SegOption(id: "720", label: "720p"),
                    SegOption(id: "480", label: "480p"),
                    SegOption(id: "audio", label: "Audio"),
                ])

                Spacer()
                DownloadButton(inCoda: model.state.running, attivo: !url.isEmpty) {
                    Task {
                        await model.post("/ytdlp", [
                            "url": url, "quality": quality,
                            "options": [:], "path": model.destination,
                        ])
                    }
                }
            }

            Text("Il pannello opzioni completo arriverà nella prossima versione.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Riga di attesa con rotellina: la usano sia VibraVid sia MangaWorld mentre
/// interrogano il sito, e conviene che siano identiche.
func loadingRow(_ text: String) -> some View {
    HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(text).foregroundStyle(.secondary).font(.callout)
    }
}

// --------------------------------------------------------------- MangaWorld
/// Scheda MangaWorld: si incolla il link del manga e si scelgono i capitoli.
///
/// Niente ricerca interna come in VibraVid: MangaWorld non la offre, si parte
/// sempre da un indirizzo. E niente modalità volume: senza intervallo esplicito
/// il loro downloader apre una selezione interattiva a terminale, che qui
/// resterebbe appesa in attesa di una risposta che nessuno può dare.
struct MangaPane: View {
    @Environment(\.controlActiveState) private var stato
    @ObservedObject var model: AppModel
    @State private var url = ""
    @State private var mode = "all"          // all | range | list
    @State private var start = ""
    @State private var end = ""
    @State private var elenco = ""           // capitoli sparsi: "3, 7, 12"
    @State private var formato = ""          // "" | pdf | cbz

    // Quanti capitoli ha il manga incollato. Si legge da solo poco dopo che si
    // smette di scrivere: senza, l'intervallo si compila a indovinare.
    @State private var capitoli: Int? = nil
    @State private var nomeLetto = ""
    @State private var leggendo = false
    @State private var erroreLettura: String? = nil
    @State private var lettura: Task<Void, Never>? = nil

    /// I numeri scritti in "Specifici", ripuliti da spazi e da ciò che non è cifra.
    var scelti: [String] {
        elenco.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Int($0) != nil }
    }

    var pronto: Bool {
        guard url.hasPrefix("http") else { return false }
        switch mode {
        case "range":
            // Con l'intervallo serve almeno un estremo, o equivale a "tutti".
            return !start.trimmingCharacters(in: .whitespaces).isEmpty
                || !end.trimmingCharacters(in: .whitespaces).isEmpty
        case "list":
            return !scelti.isEmpty
        default:
            return true
        }
    }

    /// Nome del manga: quello letto dal sito se è arrivato, altrimenti ricavato
    /// dall'indirizzo, che finisce con "/manga/<id>/<nome-del-manga>".
    var titolo: String {
        if !nomeLetto.isEmpty { return nomeLetto }
        guard let ultimo = url.split(separator: "/").last, !ultimo.isEmpty else {
            return "Manga"
        }
        return ultimo.replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// Rilegge il conteggio dopo una pausa nella digitazione, così incollando
    /// un indirizzo non si manda una richiesta per ogni carattere.
    func programmaLettura() {
        lettura?.cancel()
        capitoli = nil; nomeLetto = ""; erroreLettura = nil
        let indirizzo = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard indirizzo.hasPrefix("http") else { leggendo = false; return }

        lettura = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            leggendo = true
            let obj = await model.post("/mangaworld_info", ["url": indirizzo])
            if Task.isCancelled { return }
            leggendo = false
            if let err = obj["error"] as? String {
                erroreLettura = err
            } else {
                capitoli = obj["count"] as? Int
                nomeLetto = (obj["name"] as? String) ?? ""
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Incolla il link del manga da MangaWorld…", text: $url)
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .onChange(of: url) { _, _ in programmaLettura() }

            // Esito della lettura: quanti capitoli ci sono, o perché non si sa.
            if leggendo {
                loadingRow("Leggo i capitoli…")
            } else if let n = capitoli {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accento(stato))
                    Text(nomeLetto.isEmpty ? "Manga trovato" : nomeLetto)
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Text(n == 1 ? "· 1 capitolo" : "· \(n) capitoli")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(accento(stato).opacity(0.14), in: .rect(cornerRadius: 9))
            } else if let err = erroreLettura {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                Text("Capitoli").font(.caption).foregroundStyle(.secondary)
                GlassSegmented(selection: $mode, options: [
                    SegOption(id: "all", label: "Tutti"),
                    SegOption(id: "range", label: "Intervallo"),
                    SegOption(id: "list", label: "Specifici"),
                ])
                Spacer()
                DownloadButton(inCoda: model.state.running, attivo: pronto) { avvia() }
            }

            if mode == "range" {
                HStack(spacing: 10) {
                    Text("dal").foregroundStyle(.secondary)
                    TextField("1", text: $start).frame(width: 62)
                    Text("al").foregroundStyle(.secondary)
                    // Letto il manga, il segnaposto diventa il numero
                    // dell'ultimo capitolo invece di un generico "ultimo".
                    TextField(capitoli.map(String.init) ?? "ultimo", text: $end)
                        .frame(width: 62)
                    Text(capitoli == nil
                            ? "vuoto = dall'inizio / fino alla fine"
                            : "su \(capitoli ?? 0) disponibili")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .textFieldStyle(.roundedBorder)
            } else if mode == "list" {
                HStack(spacing: 10) {
                    TextField("3, 7, 12", text: $elenco).frame(width: 180)
                        .textFieldStyle(.roundedBorder)
                    Text(scelti.isEmpty
                            ? "numeri separati da virgola"
                            : (scelti.count == 1
                                ? "1 capitolo scelto"
                                : "\(scelti.count) capitoli scelti"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 12) {
                Text("Genera anche").font(.caption).foregroundStyle(.secondary)
                GlassSegmented(selection: $formato, options: [
                    SegOption(id: "", label: "Solo immagini"),
                    SegOption(id: "pdf", label: "PDF"),
                    SegOption(id: "cbz", label: "CBZ"),
                ])
                Spacer()
            }

            Text("Le pagine vengono salvate in una cartella per capitolo.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .animation(.snappy, value: mode)
    }

    func avvia() {
        Task {
            await model.post("/mangaworld", [
                "url": url.trimmingCharacters(in: .whitespacesAndNewlines),
                "title": titolo,
                "start": mode == "range" ? start.trimmingCharacters(in: .whitespaces) : "",
                "end": mode == "range" ? end.trimmingCharacters(in: .whitespaces) : "",
                "chapters": mode == "list" ? scelti.joined(separator: ",") : "",
                "format": formato,
                "path": model.destination,
            ])
        }
    }
}

// ---------------------------------------------------------------- VibraVid
struct SeasonInfo: Identifiable {
    let index: Int
    let name: String
    var id: Int { index }
}

struct EpisodeInfo: Identifiable {
    let index: Int
    let name: String
    let duration: Int?
    var id: Int { index }
}

/// Pastiglia selezionabile in vetro, usata per stagioni ed episodi.
struct Chip: View {
    @Environment(\.controlActiveState) private var stato
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background {
            Capsule().fill(on ? accento(stato).opacity(0.85) : Color.primary.opacity(0.08))
        }
    }
}

/// Scheda VibraVid a passi: prima si sceglie il titolo, poi — solo se è una
/// serie — compaiono stagioni ed episodi, con il conteggio di quanti ce ne sono.
struct VibraPane: View {
    @Environment(\.controlActiveState) private var stato
    @ObservedObject var model: AppModel
    @State private var site = "streamingcommunity"
    @State private var sites: [String] = []
    @State private var query = ""

    // Titolo scelto
    @State private var chosen: Int? = nil
    @State private var chosenTitle = ""
    @State private var chosenKind = ""

    // Stagioni
    @State private var seasons: [SeasonInfo] = []
    @State private var loadingSeasons = false
    @State private var isMovie = false
    @State private var seasonsError: String? = nil
    @State private var allSeasons = false
    @State private var selectedSeason: Int? = nil

    // Episodi
    @State private var episodes: [EpisodeInfo] = []
    @State private var loadingEpisodes = false
    @State private var allEpisodes = true
    @State private var pickedEpisodes: Set<Int> = []

    // Siti senza stagioni (animeunity, animeworld): di quelle serie si conosce
    // soltanto quanti episodi ci sono, non i loro nomi né le durate. Si sceglie
    // quindi per numero, con lo stesso comando che la scheda AnimeUnity già usa.
    @State private var flatCount: Int? = nil
    @State private var flatMode = "all"        // all | range | list
    @State private var flatStart = ""
    @State private var flatEnd = ""
    @State private var flatList = ""

    var isFlat: Bool { flatCount != nil }

    /// La selezione degli episodi nella sintassi di VibraVid: "*", "3-7", "1,4,9".
    /// Un estremo vuoto nell'intervallo significa "dall'inizio" o "fino alla fine".
    var flatSelection: String {
        switch flatMode {
        case "range":
            let a = flatStart.trimmingCharacters(in: .whitespaces)
            let b = flatEnd.trimmingCharacters(in: .whitespaces)
            if a.isEmpty && b.isEmpty { return "*" }
            return "\(a.isEmpty ? "1" : a)-\(b.isEmpty ? "*" : b)"
        case "list":
            let n = flatList.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && Int($0) != nil }
            return n.joined(separator: ",")
        default:
            return "*"
        }
    }

    // Lingua e sottotitoli: solo italiano e inglese, il resto si ignora.
    // Di partenza audio italiano e nessun sottotitolo.
    @State private var audio = "ita"
    @State private var sottotitoli = ""

    // Riproduzione diretta nel lettore
    @State private var apreLettore = false

    /// Siti che consegnano il flusso cifrato: lì un lettore esterno non può
    /// riprodurre nulla, quindi il pulsante non compare.
    static let sitiProtetti: Set<String> = [
        "crunchyroll", "raiplay", "mediasetinfinity", "discoveryplus",
        "dmax", "nove", "realtime", "foodnetwork", "homegardentv",
    ]

    /// Il ▶︎ ha senso solo su un singolo episodio (o un film) da un sito in chiaro.
    var puoGuardare: Bool {
        guard chosen != nil, !Self.sitiProtetti.contains(site.lowercased()) else {
            return false
        }
        if isMovie { return true }
        // Sito piatto: un episodio solo, cioè "Specifici" con un numero dentro.
        if isFlat { return flatMode == "list" && Int(flatSelection) != nil }
        guard isSeries, !allSeasons, selectedSeason != nil else { return false }
        return !allEpisodes && pickedEpisodes.count == 1
    }

    var isSeries: Bool { !isMovie && !seasons.isEmpty }

    /// Quanti passi numerati vengono prima di "Lingua e sottotitoli". Non è
    /// sempre il quarto: un film non ha né stagione né episodi, un sito senza
    /// stagioni ha solo gli episodi, e chi sceglie tutte le stagioni salta la
    /// scelta degli episodi. Fissarlo a "4" faceva saltare la numerazione.
    var passoLingua: String {
        if isMovie { return "2" }
        if isFlat || allSeasons { return "3" }
        return "4"
    }
    var canDownload: Bool {
        guard chosen != nil else { return false }
        if isFlat { return !flatSelection.isEmpty }        // serve una selezione valida
        if !isSeries { return true }                       // film: basta il titolo
        if allSeasons { return true }                      // tutte le stagioni
        guard selectedSeason != nil else { return false }  // serve una stagione
        return allEpisodes || !pickedEpisodes.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ---- 1. Dove cercare
            HStack(spacing: 12) {
                Text("Sito").foregroundStyle(.secondary).font(.callout)
                Picker("", selection: $site) {
                    ForEach(sites, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .onChange(of: site) { _, _ in resetAll() }
            }

            HStack(spacing: 10) {
                TextField("Titolo da cercare (es. One Piece)…", text: $query)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .onSubmit { search() }
                    .onChange(of: query) { _, _ in resetAll() }
                IconButton(symbol: "magnifyingglass", hint: "Cerca") { search() }
                    .disabled(model.searching || query.isEmpty)
                    .opacity(model.searching || query.isEmpty ? 0.4 : 1)
            }

            // ---- 2. Risultati: si sceglie il titolo
            if model.searching {
                loadingRow("Ricerca in corso…")
            } else if chosen != nil {
                // Titolo scelto: l'elenco si richiude e resta solo la riga
                // selezionata, così la schermata non resta ingombra.
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accento(stato))
                    Text(chosenTitle).font(.callout.weight(.medium)).lineLimit(1)
                    Text(chosenKind == "movie" ? "· film" : "· serie")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cambia") { chosen = nil }.buttonStyle(.link)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(accento(stato).opacity(0.14), in: .rect(cornerRadius: 9))
            } else if !model.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    stepLabel("1", "Scegli il titolo",
                              detail: "\(model.searchResults.count) risultati")
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.searchResults) { r in
                                HStack {
                                    Text(r.name).lineLimit(1)
                                    Spacer()
                                    Text([r.kind, r.year]
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(chosen == r.index ? accento(stato).opacity(0.18) : .clear)
                                .contentShape(.rect)
                                .onTapGesture { choose(r) }
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                    .background(.background.secondary, in: .rect(cornerRadius: 9))
                }
            }

            // ---- 3. Stagioni (solo dopo aver scelto, e solo se è una serie)
            if chosen != nil {
                if loadingSeasons {
                    loadingRow("Leggo le stagioni di \"\(chosenTitle)\"…")
                } else if let err = seasonsError {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Riprova") { loadSeasons() }.buttonStyle(.link)
                    }
                } else if isMovie {
                    HStack(spacing: 7) {
                        Image(systemName: "film").foregroundStyle(accento(stato))
                        Text("\(chosenTitle) è un film: nessuna stagione da scegliere.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if isFlat {
                    // Sito senza stagioni: si passa dritti agli episodi. Di
                    // loro si sa solo quanti sono — niente nomi, niente durate
                    // — quindi si scelgono per numero invece che a pastiglie:
                    // con 1171 episodi una griglia sarebbe comunque inservibile.
                    VStack(alignment: .leading, spacing: 7) {
                        stepLabel("2", "Scegli gli episodi",
                                  detail: "\(flatCount ?? 0) episodi, questo sito non ha stagioni")
                        GlassSegmented(selection: $flatMode, options: [
                            SegOption(id: "all", label: "Tutti"),
                            SegOption(id: "range", label: "Intervallo"),
                            SegOption(id: "list", label: "Specifici"),
                        ])
                        if flatMode == "range" {
                            HStack(spacing: 10) {
                                Text("da").foregroundStyle(.secondary)
                                TextField("1", text: $flatStart).frame(width: 62)
                                Text("a").foregroundStyle(.secondary)
                                TextField("\(flatCount ?? 0)", text: $flatEnd).frame(width: 62)
                                Text("vuoto = dall'inizio / fino alla fine")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .textFieldStyle(.roundedBorder)
                        } else if flatMode == "list" {
                            HStack(spacing: 10) {
                                TextField("3, 7, 12", text: $flatList).frame(width: 180)
                                    .textFieldStyle(.roundedBorder)
                                Text("numeri separati da virgola")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } else if !seasons.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        stepLabel("2", "Scegli la stagione",
                                  detail: "\(seasons.count) stagioni disponibili")
                        FlowChips {
                            Chip(label: "Tutte le stagioni", on: allSeasons) {
                                allSeasons = true
                                selectedSeason = nil
                                episodes = []
                            }
                            ForEach(seasons) { s in
                                Chip(label: s.name, on: !allSeasons && selectedSeason == s.index) {
                                    allSeasons = false
                                    selectedSeason = s.index
                                    loadEpisodes(s.index)
                                }
                            }
                        }
                    }
                }
            }

            // ---- 4. Episodi (solo dopo aver scelto una stagione precisa)
            if isSeries && !allSeasons && selectedSeason != nil {
                if loadingEpisodes {
                    loadingRow("Leggo gli episodi…")
                } else if !episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        stepLabel("3", "Scegli gli episodi",
                                  detail: "\(episodes.count) episodi")
                        FlowChips {
                            Chip(label: "Tutti gli episodi", on: allEpisodes) {
                                allEpisodes = true
                                pickedEpisodes = []
                            }
                            ForEach(episodes) { e in
                                Chip(label: "\(e.index)",
                                     on: !allEpisodes && pickedEpisodes.contains(e.index)) {
                                    allEpisodes = false
                                    if pickedEpisodes.contains(e.index) {
                                        pickedEpisodes.remove(e.index)
                                    } else {
                                        pickedEpisodes.insert(e.index)
                                    }
                                }
                            }
                        }
                        if let total = totalMinutes, allEpisodes {
                            Text("Durata complessiva: circa \(total) minuti")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // ---- 4. Lingua e sottotitoli, una volta scelto cosa scaricare
            if chosen != nil && (isMovie || isFlat || allSeasons || selectedSeason != nil) {
                VStack(alignment: .leading, spacing: 7) {
                    stepLabel(passoLingua, "Lingua e sottotitoli", detail: "italiano o inglese")
                    HStack(spacing: 14) {
                        HStack(spacing: 6) {
                            Text("Audio").font(.caption).foregroundStyle(.secondary)
                            Chip(label: "ITA", on: audio == "ita") { audio = "ita" }
                            Chip(label: "ENG", on: audio == "eng") { audio = "eng" }
                        }
                        Divider().frame(height: 16)
                        HStack(spacing: 6) {
                            Text("Sottotitoli").font(.caption).foregroundStyle(.secondary)
                            Chip(label: "Nessuno", on: sottotitoli.isEmpty) { sottotitoli = "" }
                            Chip(label: "ITA", on: sottotitoli == "ita") { sottotitoli = "ita" }
                            Chip(label: "ENG", on: sottotitoli == "eng") { sottotitoli = "eng" }
                        }
                        Spacer()
                    }
                }
            }

            // ---- 5. Avvio: compare solo quando c'è davvero qualcosa da scaricare
            if chosen != nil {
                HStack {
                    Text(riepilogo).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if apreLettore {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Apro IINA…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if puoGuardare {
                        IconButton(symbol: "play.fill", hint: "Guarda senza scaricare") {
                            guarda()
                        }
                    }
                    DownloadButton(inCoda: model.state.running,
                                   attivo: canDownload) { download() }
                }
            }
        }
        .animation(.snappy, value: chosen)
        .animation(.snappy, value: seasons.count)
        .animation(.snappy, value: episodes.count)
        .animation(.snappy, value: allSeasons)
        .task { await loadSites() }
    }

    var totalMinutes: Int? {
        let mins = episodes.compactMap(\.duration)
        return mins.isEmpty ? nil : mins.reduce(0, +)
    }

    /// Coda del riepilogo con le lingue: la sola lingua audio, più i
    /// sottotitoli quando ci sono. Dichiarare che NON ci sono occuperebbe
    /// spazio senza aggiungere informazione.
    var lingue: String {
        var parti = [audio.uppercased()]
        if !sottotitoli.isEmpty { parti.append("Sub \(sottotitoli.uppercased())") }
        return " · " + parti.joined(separator: " · ")
    }

    /// Selezione compatta: "S01 · E01", "S01 · E01-E03", "S01 completa".
    var selezione: String {
        guard let s = selectedSeason else { return "" }
        let esse = String(format: "S%02d", s)
        if allEpisodes { return "\(esse) completa" }
        let numeri = pickedEpisodes.sorted()
        guard let primo = numeri.first, let ultimo = numeri.last else { return esse }
        let ep = { (n: Int) in "E" + String(format: "%02d", n) }
        if numeri.count == 1 { return "\(esse) · \(ep(primo))" }
        if numeri == Array(primo...ultimo) {
            return "\(esse) · \(ep(primo))-\(ep(ultimo))"
        }
        return esse + " · " + numeri.map(ep).joined(separator: ", ")
    }

    var riepilogo: String {
        guard !chosenTitle.isEmpty else { return "" }
        if isFlat {
            let quali = flatSelection == "*"
                ? "tutti i \(flatCount ?? 0) episodi"
                : "episodi \(flatSelection)"
            return "\(chosenTitle) · \(quali)" + lingue
        }
        if !isSeries { return chosenTitle + lingue }
        if allSeasons {
            return "\(chosenTitle) · tutte le \(seasons.count) stagioni" + lingue
        }
        guard selectedSeason != nil else { return chosenTitle }
        return "\(chosenTitle) · \(selezione)" + lingue
    }

    func stepLabel(_ n: String, _ title: String, detail: String) -> some View {
        HStack(spacing: 7) {
            Text(n)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(accento(stato)))
            Text(title).font(.callout.weight(.medium))
            Text("· \(detail)").font(.caption).foregroundStyle(.secondary)
        }
    }

    // ------------------------------------------------------------ azioni
    func resetAll() {
        model.searchResults = []
        chosen = nil; chosenTitle = ""; chosenKind = ""
        seasons = []; isMovie = false; allSeasons = false; selectedSeason = nil
        seasonsError = nil
        episodes = []; allEpisodes = true; pickedEpisodes = []
        resetFlat()
    }

    func resetFlat() {
        flatCount = nil; flatMode = "all"
        flatStart = ""; flatEnd = ""; flatList = ""
    }

    func choose(_ r: VibraResult) {
        chosen = r.index
        chosenTitle = r.name
        chosenKind = r.type
        seasons = []; isMovie = false; allSeasons = false; selectedSeason = nil
        seasonsError = nil
        episodes = []; allEpisodes = true; pickedEpisodes = []
        resetFlat()

        // Un film non ha stagioni, e la ricerca l'ha già detto: è la stessa
        // fonte che scrive "· film" nella riga qui sopra, e loadSeasons() la
        // tratta comunque come autorevole. Chiedere le stagioni al server
        // significava aspettare un giro in rete intero per farsi rispondere
        // "nessuna stagione" e concludere quello che si sapeva già in partenza.
        // Il confronto passa da isMovie, che ignora le maiuscole: su animeunity
        // il tipo arriva come "Movie" e un confronto letterale non scattava mai.
        if r.isMovie {
            isMovie = true
            return
        }
        loadSeasons()
    }

    /// Carica l'elenco dei siti, riprovando finché il server non risponde.
    ///
    /// All'avvio a freddo l'app lancia il server Python e mostra subito la
    /// finestra: la prima richiesta arriva quando il server non è ancora in
    /// ascolto. Senza ritentare, il menu "Sito" restava vuoto per tutta la
    /// sessione, e la scheda risultava inutilizzabile.
    func loadSites() async {
        for tentativo in 0..<20 {
            if let (data, _) = try? await URLSession.shared.data(
                    from: serverBase.appending(path: "/vibravid_sites")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["sites"] as? [String], !list.isEmpty {
                sites = list
                if !list.contains(site) { site = list.first ?? "" }
                return
            }
            if tentativo < 19 {
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    func search() {
        model.searching = true
        model.searchResults = []
        Task {
            let obj = await model.post("/vibravid_search", ["site": site, "query": query])
            var out: [VibraResult] = []
            if let arr = obj["results"] as? [[String: Any]] {
                for (i, d) in arr.enumerated() {
                    out.append(VibraResult(
                        name: d["name"] as? String ?? "",
                        type: d["type"] as? String ?? "",
                        year: d["year"] as? String ?? "",
                        index: i))
                }
            }
            model.searchResults = out
            model.searching = false
        }
    }

    func loadSeasons() {
        guard let item = chosen else { return }
        loadingSeasons = true
        seasonsError = nil
        Task {
            let obj = await model.post("/vibravid_seasons", [
                "site": site, "query": query, "item": String(item),
            ])

            // Un errore non deve mai travestirsi da "è un film": sono cose
            // diverse e vanno dette in modo diverso.
            if let err = obj["error"] as? String {
                seasonsError = err
                seasons = []
                isMovie = false
                loadingSeasons = false
                return
            }

            var out: [SeasonInfo] = []
            if let arr = obj["seasons"] as? [[String: Any]] {
                for d in arr {
                    out.append(SeasonInfo(
                        index: d["index"] as? Int ?? 0,
                        name: d["name"] as? String ?? ""))
                }
            }
            seasons = out

            if out.isEmpty {
                // Nessuna stagione: tre casi distinti, e confonderli era il
                // motivo per cui su animeunity non si caricava nulla.
                if obj["flat"] as? Bool == true {
                    // Il sito le stagioni non le ha proprio: la serie è un
                    // elenco unico di episodi, di cui si conosce solo quanti
                    // sono. Si scelgono per numero, più avanti.
                    isMovie = false
                    flatCount = obj["count"] as? Int ?? 0
                } else if obj["movie"] as? Bool == true {
                    isMovie = true
                } else {
                    // Il server non sa dire cos'è: è un guasto, e va detto.
                    isMovie = false
                    seasonsError = "Non sono riuscito a leggere le stagioni di "
                        + "\"\(chosenTitle)\". Riprova, oppure scegli un altro sito."
                }
            } else {
                isMovie = false
            }
            loadingSeasons = false
        }
    }

    func loadEpisodes(_ season: Int) {
        guard let item = chosen else { return }
        loadingEpisodes = true
        episodes = []
        Task {
            let obj = await model.post("/vibravid_episodes", [
                "site": site, "query": query,
                "item": String(item), "season": String(season),
            ])
            var out: [EpisodeInfo] = []
            if let arr = obj["episodes"] as? [[String: Any]] {
                for d in arr {
                    out.append(EpisodeInfo(
                        index: d["index"] as? Int ?? 0,
                        name: d["name"] as? String ?? "",
                        duration: d["duration"] as? Int))
                }
            }
            episodes = out
            loadingEpisodes = false
        }
    }

    /// Risolve il flusso e lo apre in IINA, senza scaricare nulla.
    func guarda() {
        guard let item = chosen else { return }

        // Cosa mandare dipende da com'è fatto il titolo: un film non ha né
        // stagione né episodio, un sito senza stagioni ha solo l'episodio, una
        // serie normale li ha entrambi.
        let stagione: String
        let episodio: String
        if isMovie {
            stagione = ""; episodio = ""
        } else if isFlat {
            stagione = ""; episodio = flatSelection
        } else if let s = selectedSeason {
            stagione = String(s)
            episodio = pickedEpisodes.first.map(String.init) ?? ""
        } else {
            return
        }

        apreLettore = true
        Task {
            await model.post("/vibravid_watch", [
                "site": site, "query": query, "title": chosenTitle,
                "item": String(item),
                "season": stagione,
                "episode": episodio,
                "audio": audio, "subtitle": sottotitoli,
                "path": model.destination,
            ])
            apreLettore = false
        }
    }

    /// Quanti episodi comporta la selezione, quando si può saperlo in anticipo.
    ///
    /// Serve alla barra di avanzamento: senza, il totale veniva scoperto un
    /// episodio alla volta e la barra si suddivideva sotto gli occhi. Con
    /// "tutte le stagioni" resta ignoto, perché gli episodi delle altre
    /// stagioni non sono ancora stati letti.
    var episodiAttesi: Int {
        if isMovie { return 1 }
        if isFlat {
            guard let n = flatCount else { return 0 }
            switch flatMode {
            case "range":
                let a = max(Int(flatStart.trimmingCharacters(in: .whitespaces)) ?? 1, 1)
                let b = min(Int(flatEnd.trimmingCharacters(in: .whitespaces)) ?? n, n)
                return max(0, b - a + 1)
            case "list":
                return flatSelection.isEmpty
                    ? 0 : flatSelection.split(separator: ",").count
            default:
                return n
            }
        }
        guard isSeries, !allSeasons, selectedSeason != nil else { return 0 }
        return allEpisodes ? episodes.count : pickedEpisodes.count
    }

    func download() {
        // "*" è la sintassi di VibraVid per "tutto".
        var seasonArg = ""
        var episodeArg = ""
        if isFlat {
            // Sito senza stagioni: la stagione resta vuota. Il downloader di
            // questi siti accetta il parametro ma non lo guarda nemmeno —
            // gli serve solo la selezione degli episodi.
            episodeArg = flatSelection
        } else if isSeries {
            if allSeasons {
                seasonArg = "*"
                episodeArg = "*"
            } else if let s = selectedSeason {
                seasonArg = String(s)
                episodeArg = allEpisodes
                    ? "*"
                    : pickedEpisodes.sorted().map(String.init).joined(separator: ",")
            }
        }
        Task {
            await model.post("/vibravid", [
                "site": site, "query": query,
                "item": chosen.map(String.init) ?? "",
                "title": chosenTitle,
                "season": seasonArg, "episode": episodeArg,
                "audio": audio, "subtitle": sottotitoli,
                "path": model.destination,
                "count": String(episodiAttesi),
            ])
        }
    }
}

/// Dispone le pastiglie su più righe quando non ci stanno in una sola.
struct FlowChips<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { content }
                .padding(.vertical, 1)
        }
    }
}

// ------------------------------------------------------------ destinazione
struct DestinationRow: View {
    @Environment(\.controlActiveState) private var stato
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(accento(stato))
            Text("Salva in")
            Text(model.destinationName).fontWeight(.medium)
            Button("Cambia…") { model.pickFolder() }.buttonStyle(.link)
            Spacer()
            Button("Apri cartella") { model.openDestination() }.buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// ------------------------------------- download in corso, dentro l'elenco
/// Barra divisa in segmenti, uno per episodio: quelli finiti pieni, quello in
/// corso riempito in parte, i rimanenti vuoti. Con un episodio solo degenera
/// in una barra continua, così la riga ha sempre la stessa forma.
struct BarraSegmenti: View {
    let totali: Int
    let fatti: Int
    let corrente: Double        // 0…1 sull'episodio in corso
    let colore: Color

    var body: some View {
        GeometryReader { geo in
            let n = max(totali, 1)
            let spazio: CGFloat = n > 1 ? 3 : 0
            let largh = max((geo.size.width - spazio * CGFloat(n - 1)) / CGFloat(n), 1)
            HStack(spacing: spazio) {
                ForEach(0..<n, id: \.self) { i in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.14))
                        Capsule().fill(colore)
                            .frame(width: i < fatti ? largh
                                          : (i == fatti ? largh * corrente : 0))
                    }
                    .frame(width: largh)
                }
            }
        }
        .frame(height: 6)
    }
}

/// Download in corso, dentro la sezione DOWNLOAD insieme ai completati.
/// Una riga sola, sempre della stessa forma: titolo, pastiglia dell'episodio,
/// barra e dettaglio. Con più episodi la barra si divide in segmenti.
struct ActiveDownloadRow: View {
    @ObservedObject var model: AppModel
    /// Le barre native si smorzano quando la finestra perde il fuoco: la barra
    /// a segmenti è disegnata a mano, quindi deve farlo da sé per non restare
    /// accesa mentre tutto il resto è spento.
    @Environment(\.controlActiveState) private var stato

    var colore: Color {
        stato == .inactive ? Color.secondary.opacity(0.55) : accent
    }

    /// Unità che si contano una per una, e meritano la barra a segmenti.
    /// I capitoli di un manga si comportano come gli episodi; le tracce di
    /// VibraVid (video, audio, sottotitoli) no, quelle sono un episodio solo.
    var contaEpisodi: Bool {
        ["episodi", "capitoli"].contains(model.state.overall.unit ?? "episodi")
    }
    var totali: Int { max(Int(model.state.overall.total), 1) }
    var fatti: Int { contaEpisodi ? Int(model.state.overall.done) : 0 }
    var multi: Bool { contaEpisodi && totali > 1 }

    /// Avanzamento dell'episodio in corso (0…1).
    var pctCorrente: Double {
        min((model.state.episodes.first?.pct ?? 0) / 100, 1)
    }

    /// Avanzamento complessivo, per la barra continua del caso singolo.
    var pctTotale: Double {
        guard totali > 0 else { return 0 }
        return min((Double(fatti) + pctCorrente) / Double(totali), 1)
    }

    /// Pastiglia con l'elemento in corso: "S01 E04" per le serie, "Capitolo 7"
    /// per i manga.
    var episodio: String {
        let d = model.state.episodes.first?.desc ?? ""
        // Accetta sia "S01E01" sia "S01 · E01": aggiungendo il pallino fra
        // stagione ed episodio la vecchia forma non corrispondeva più e la
        // pastiglia spariva senza segnalare nulla.
        let forma = #"^S\d+\s*(·\s*)?E\d+"#
        if d.range(of: forma, options: .regularExpression) != nil { return d }
        // Dei manga si prende il solo "Ch. 7": il "(2 di 5)" che segue lo dice
        // già il contatore accanto alla barra, e ripeterlo è rumore.
        if let r = d.range(of: #"^Ch\.\s*\d+"#, options: .regularExpression) {
            return String(d[r])
        }
        return ""
    }

    var dettaglio: String {
        let s = model.state
        var parti: [String] = []
        if s.bytes_now > 1e6 {
            var t = fmtBytes(s.bytes_now)
            if let est = s.bytes_total_est { t += " su \(fmtBytes(est))" }
            parti.append(t)
        }
        if s.speed_bps > 1e5 { parti.append(fmtSpeed(s.speed_bps)) }
        if let eta = s.eta_s { parti.append(fmtEta(eta)) }
        if parti.isEmpty { return s.overall.stage ?? "Avvio…" }
        return parti.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .glassEffect(.regular.tint(accento(stato).opacity(0.85)), in: .circle)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(model.state.overall.label)
                        .font(.callout.weight(.medium)).lineLimit(1)
                    if !episodio.isEmpty {
                        Text(episodio)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(colore)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(colore.opacity(0.16)))
                    }
                    Spacer(minLength: 8)
                    if multi {
                        Text("\(fatti + 1) di \(totali)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }

                if multi {
                    BarraSegmenti(totali: totali, fatti: fatti,
                                  corrente: pctCorrente, colore: colore)
                } else if model.state.overall.total > 0 || pctCorrente > 0 {
                    ProgressView(value: multi ? pctTotale : pctCorrente).tint(accento(stato))
                } else {
                    ProgressView().progressViewStyle(.linear).tint(accento(stato))
                }

                Text(dettaglio)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Button { model.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Annulla il download")
        }
        .padding(.bottom, 4)
    }
}

/// Coda dei download in attesa: una riga sola che si apre al clic, così non
/// occupa spazio quando non interessa.
struct CodaRow: View {
    @ObservedObject var model: AppModel
    @Binding var aperta: Bool

    var titoli: String {
        model.state.queue.map(\.label).joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { aperta.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(aperta ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(model.state.queue.count == 1
                         ? "1 in coda" : "\(model.state.queue.count) in coda")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("· \(titoli)")
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, 40)

            if aperta {
                ForEach(Array(model.state.queue.enumerated()), id: \.element.id) { i, voce in
                    HStack(spacing: 12) {
                        Text("\(i + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.primary.opacity(0.07)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voce.label).font(.callout).lineLimit(1)
                            if !voce.detail.isEmpty {
                                Text(voce.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            model.rimuoviDallaCoda(voce.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 20, height: 20).contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Togli dalla coda")
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}

// --------------------------------------------------------------- download
struct DownloadsSection: View {
    @ObservedObject var model: AppModel
    @Binding var showLog: Bool
    @State private var codaAperta = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DOWNLOAD")
                .font(.caption2).foregroundStyle(.tertiary).tracking(0.8)

            // Il download in corso apre l'elenco, sopra quelli completati.
            if model.state.running {
                ActiveDownloadRow(model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !model.state.queue.isEmpty {
                CodaRow(model: model, aperta: $codaAperta)
                    .transition(.opacity)
            }

            if model.state.completed.isEmpty && !model.state.running {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Nessun download")
                        .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Incolla un link e premi Scarica")
                        .font(.callout).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
            }

            ForEach(model.state.completed.reversed()) { c in
                HStack(spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)
                        .background(.green.opacity(0.15), in: .rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label).font(.callout).lineLimit(1)
                        // Che cosa, quanto e quando: "capitoli 2, 4 · PDF" da
                        // solo non basta a ritrovarsi dentro una cronologia
                        // lunga, e la sola dimensione non dice cosa contiene.
                        Text([c.detail, fmtBytes(c.size), c.quando]
                                .filter { !$0.isEmpty }
                                .joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Apri nel Finder") { model.open(path: c.path) }
                        .buttonStyle(.link)
                }
            }

            if !model.state.completed.isEmpty {
                Button("Cancella elenco") { model.clearCompleted() }.buttonStyle(.link)
            }

            // Il pannello "Mostra dettagli" è stato rimosso: mostrava l'output
            // grezzo del motore — migliaia di righe che l'interfaccia doveva
            // ridisegnare, rendendola lentissima e senza dire nulla di utile.
        }
    }
}

// ======================================================= avvio del server
// L'app da sola non scarica nulla: il motore è gui.py. Qui lo si avvia
// all'apertura e lo si chiude all'uscita, con la stessa logica di main.swift
// (l'app storica), così la nuova versione è lanciabile con un doppio clic.
final class ServerLauncher: NSObject, NSApplicationDelegate {
    var serverProcess: Process?

    /// Cartella che contiene gui.py: dentro il bundle, accanto ad esso,
    /// oppure nella posizione standard in Application Support.
    func projectDir() -> String {
        let fm = FileManager.default
        var candidates: [String] = []
        if let bundled = Bundle.main.resourcePath.map({
            ($0 as NSString).appendingPathComponent("app")
        }) {
            candidates.append(bundled)
        }
        if let cfg = Bundle.main.path(forResource: "project_path", ofType: "txt"),
           let stored = try? String(contentsOfFile: cfg, encoding: .utf8) {
            candidates.append(stored.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        candidates.append((Bundle.main.bundlePath as NSString).deletingLastPathComponent)
        candidates.append((NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Vault"))
        for dir in candidates
        where fm.fileExists(atPath: (dir as NSString).appendingPathComponent("gui.py")) {
            return dir
        }
        return candidates.last!
    }

    func pythonPath() -> String {
        if let res = Bundle.main.resourcePath {
            let bundled = (res as NSString).appendingPathComponent("python/bin/python3")
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        return "/usr/bin/python3"
    }

    /// True se qualcuno risponde già sulla porta: in tal caso non si riavvia.
    func serverAlreadyUp() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var up = false
        var req = URLRequest(url: serverBase.appending(path: "/state"))
        req.timeoutInterval = 1.2
        URLSession.shared.dataTask(with: req) { data, _, _ in
            up = (data != nil)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return up
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !serverAlreadyUp() else { return }
        let dir = projectDir()
        guard FileManager.default.fileExists(
                atPath: (dir as NSString).appendingPathComponent("gui.py")) else {
            let alert = NSAlert()
            alert.messageText = "Non trovo gui.py"
            alert.informativeText =
                "L'app cerca il motore di download in:\n\(dir)\n\n" +
                "Sposta l'app accanto alla cartella del progetto, oppure " +
                "avvia il server manualmente."
            alert.alertStyle = .critical
            alert.runModal()
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath())
        proc.arguments = ["gui.py"]
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GUI_NO_BROWSER"] = "1"   // niente browser: la finestra è questa
        proc.environment = env
        do {
            try proc.run()
            serverProcess = proc
        } catch {
            let alert = NSAlert()
            alert.messageText = "Non riesco ad avviare il motore di download"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let proc = serverProcess, proc.isRunning else { return }
        proc.terminate()
        // Si attende davvero la fine: un server sopravvissuto verrebbe riusato
        // al prossimo avvio con il codice Python già caricato in memoria,
        // facendo credere che le modifiche non abbiano effetto.
        let scadenza = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < scadenza {
            usleep(80_000)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Chiudere la finestra chiude l'app (e con essa il server): per una
        // utility è il comportamento atteso, e non lascia processi appesi.
        true
    }

    /// Clic sull'icona nel Dock ad app già avviata: se per qualsiasi motivo non
    /// ci sono finestre, se ne mostra una invece di non fare nulla — altrimenti
    /// l'app sembrerebbe sparita pur essendo in esecuzione.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            for window in sender.windows where !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
}

// ============================================== avanzamento nella barra dei menu
/// Percentuale complessiva del download in corso, comune a tutte le schede.
func percentuale(_ s: ServerState) -> Double? {
    guard s.running else { return nil }
    let o = s.overall
    guard o.total > 0 else { return nil }
    let extra = s.episodes.reduce(0) { $0 + $1.pct / 100 }
    return min((o.done + extra) / o.total, 1)
}

/// Icona nella barra in alto: mostra la percentuale mentre si scarica e
/// permette di controllare il download senza aprire la finestra.
struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.state.running {
            Text(model.state.overall.label)
            if let p = percentuale(model.state) {
                Text("\(Int(p * 100))% completato")
            } else if let stato = model.state.overall.stage, !stato.isEmpty {
                Text(stato)
            }
            if model.state.speed_bps > 1e5 {
                Text(fmtSpeed(model.state.speed_bps))
            }
            if !model.state.queue.isEmpty {
                Text("\(model.state.queue.count) in coda")
            }
            Divider()
            Button("Annulla download") { model.cancel() }
        } else {
            Text("Nessun download in corso")
        }
        Divider()
        Button("Apri cartella") { model.openDestination() }
        Button("Mostra finestra") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { !$0.isVisible }?.makeKeyAndOrderFront(nil)
        }
        Divider()
        Button("Esci") { NSApp.terminate(nil) }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.state.running, let p = percentuale(model.state) {
            // Con la percentuale disponibile la si mostra come testo: nella
            // barra dei menu è più leggibile di una barra minuscola.
            HStack(spacing: 3) {
                Image(systemName: "arrow.down.circle.fill")
                Text("\(Int(p * 100))%")
            }
        } else if model.state.running {
            Image(systemName: "arrow.down.circle")
        } else {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
    }
}

// ===================================================================== app
@main
struct GlassApp: App {
    @NSApplicationDelegateAdaptor(ServerLauncher.self) var launcher

    var body: some Scene {
        // WindowGroup e non Window: con la scena a finestra singola, una volta
        // chiusa non c'era più modo di riaprirla cliccando l'icona nel Dock —
        // l'app restava in esecuzione senza finestre e sembrava rotta.
        WindowGroup("Vault") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent(model: AppModel.shared)
        } label: {
            MenuBarLabel(model: AppModel.shared)
        }
    }
}
