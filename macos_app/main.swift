// App nativa macOS per AnimeUnityDownloader.
//
// Mostra la GUI (servita da gui.py su 127.0.0.1:8765) in una finestra con
// materiale traslucido e barra del titolo unificata. Avvia il server Python
// all'apertura e lo chiude all'uscita.
//
// Ricompilazione (vedi build.sh):
//   swiftc -O -o "/Applications/AnimeUnity Downloader.app/Contents/MacOS/launcher" main.swift

import Cocoa
import UserNotifications
import WebKit

let serverURL = URL(string: "http://127.0.0.1:8765")!

class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKScriptMessageHandler,
                   UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var serverProcess: Process?

    // Barra dei menu
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var pollTimer: Timer?
    let sTitle = NSTextField(labelWithString: "AnimeUnity Downloader")
    let sBar = NSProgressIndicator()
    let sCaption = NSTextField(labelWithString: "")
    let sEpisodes = NSTextField(labelWithString: "")
    let sSpeed = NSTextField(labelWithString: "")
    let sBytes = NSTextField(labelWithString: "")
    let sEta = NSTextField(labelWithString: "")
    var sRowA: NSStackView!
    var sRowB: NSStackView!
    var sCancel: NSButton!

    // Trova la cartella del progetto (dove vive gui.py):
    //  1. Contents/Resources/app  → versione autosufficiente distribuibile
    //  2. project_path.txt         → installazione di sviluppo (percorso salvato)
    //  3. cartella accanto al bundle
    //  4. posizione standard in Application Support
    func projectDir() -> String {
        let fm = FileManager.default
        var candidates: [String] = []
        if let bundled = Bundle.main.resourcePath.map({ ($0 as NSString)
            .appendingPathComponent("app") }) {
            candidates.append(bundled)
        }
        if let cfg = Bundle.main.path(forResource: "project_path", ofType: "txt"),
           let stored = try? String(contentsOfFile: cfg, encoding: .utf8) {
            candidates.append(stored.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        candidates.append((Bundle.main.bundlePath as NSString).deletingLastPathComponent)
        candidates.append((NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/AnimeUnityDownloader"))
        for dir in candidates
        where fm.fileExists(atPath: (dir as NSString).appendingPathComponent("gui.py")) {
            return dir
        }
        return candidates.last!
    }

    // Interprete Python: quello incorporato nel bundle se presente
    // (versione distribuibile), altrimenti il python3 di sistema (sviluppo).
    func pythonPath() -> String {
        if let res = Bundle.main.resourcePath {
            let bundled = (res as NSString).appendingPathComponent("python/bin/python3")
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        return "/usr/bin/python3"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        startServer()

        // Notifiche con l'icona dell'app (al primo avvio macOS chiede il permesso)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            let msg = "UN auth granted=\(granted) error=\(String(describing: error))\n"
            try? msg.write(
                toFile: NSTemporaryDirectory() + "animeunity_notif.log",
                atomically: true, encoding: .utf8)
        }
        NSUserNotificationCenter.default.delegate = self

        let config = WKWebViewConfiguration()
        for name in ["pickFolder", "dockProgress", "dragWindow", "zoomWindow", "downloadDone"] {
            config.userContentController.add(self, name: name)
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "AnimeUnity Downloader"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 620, height: 560)

        // Materiale traslucido dietro la pagina (la pagina usa uno sfondo
        // semitrasparente quando rileva l'app nativa).
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 660, height: 780))
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        webView.frame = effect.bounds
        webView.autoresizingMask = [.width, .height]
        effect.addSubview(webView)
        window.contentView = effect
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }

        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupStatusItem()
        waitForServerAndLoad(attemptsLeft: 80)

        // Solo per collaudo: POPOVER_TEST=1 apre il popover da solo
        if ProcessInfo.processInfo.environment["POPOVER_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.togglePopover(nil)
            }
        }
    }

    // -------------------------------------------------------- barra dei menu
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: "AnimeUnity Downloader")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        sTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        sTitle.alignment = .left
        sTitle.lineBreakMode = .byTruncatingTail
        sTitle.maximumNumberOfLines = 1

        sBar.isIndeterminate = false
        sBar.minValue = 0
        sBar.maxValue = 100
        sBar.style = .bar

        sCaption.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sCaption.textColor = .secondaryLabelColor
        sCaption.alignment = .left
        sCaption.lineBreakMode = .byTruncatingTail
        sCaption.maximumNumberOfLines = 1

        // Dettagli su due righe: sinistra/destra come le copie del Finder
        for label in [sEpisodes, sSpeed, sBytes, sEta] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        sSpeed.alignment = .right
        sEta.alignment = .right

        sRowA = NSStackView()
        sRowA.orientation = .horizontal
        sRowA.addView(sEpisodes, in: .leading)
        sRowA.addView(sSpeed, in: .trailing)

        sRowB = NSStackView()
        sRowB.orientation = .horizontal
        sRowB.addView(sBytes, in: .leading)
        sRowB.addView(sEta, in: .trailing)

        sCancel = NSButton(
            title: "Annulla download", target: self, action: #selector(cancelFromPopover(_:)))
        sCancel.bezelStyle = .rounded
        sCancel.controlSize = .small
        sCancel.font = .systemFont(ofSize: 11)
        let openButton = NSButton(
            title: "Mostra la finestra", target: self, action: #selector(showWindowAction(_:)))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.font = .systemFont(ofSize: 11)

        let buttonsRow = NSStackView()
        buttonsRow.orientation = .horizontal
        buttonsRow.addView(sCancel, in: .trailing)
        buttonsRow.addView(openButton, in: .trailing)

        let stack = NSStackView(views: [sTitle, sBar, sRowA, sRowB, sCaption, buttonsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(5, after: sRowA)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Ogni riga occupa tutta la larghezza (leading/trailing veri)
        for view in [sTitle, sBar, sRowA!, sRowB!, sCaption, buttonsRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 320),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])

        let controller = NSViewController()
        controller.view = container
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller

        statusItem.isVisible = false  // compare solo durante i download
        applyIdleState(completedCount: 0)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            self.fetchState()
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            fetchState()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Necessario per comparire sopra le app a schermo intero
            if let popoverWindow = popover.contentViewController?.view.window {
                popoverWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                popoverWindow.makeKey()
            }
        }
    }

    @objc func cancelFromPopover(_ sender: Any?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/cancel")!)
        request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request).resume()
    }

    @objc func showWindowAction(_ sender: Any?) {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func fetchState() {
        var request = URLRequest(url: serverURL.appendingPathComponent("state"))
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let state = obj as? [String: Any] else { return }
            DispatchQueue.main.async { self.applyState(state) }
        }.resume()
    }

    func applyState(_ state: [String: Any]) {
        let running = state["running"] as? Bool ?? false
        let overall = state["overall"] as? [String: Any] ?? [:]
        let total = (overall["total"] as? NSNumber)?.doubleValue ?? 0
        let done = (overall["done"] as? NSNumber)?.doubleValue ?? 0
        let episodes = state["episodes"] as? [[String: Any]] ?? []
        let completedCount = (state["completed"] as? [[String: Any]])?.count ?? 0

        var eff = done
        for episode in episodes {
            eff += ((episode["pct"] as? NSNumber)?.doubleValue ?? 0) / 100
        }
        if eff > total { eff = total }

        guard running else {
            applyIdleState(completedCount: completedCount)
            return
        }

        statusItem.isVisible = true
        let symbol = NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: "Download in corso")
        statusItem.button?.image = symbol
        sTitle.stringValue = overall["label"] as? String ?? "Download in corso"
        sCancel.isHidden = false
        sBar.isHidden = false

        if total > 0 {
            let pct = Int((100 * eff / total).rounded())
            statusItem.button?.title = " \(pct)%"
            sBar.isIndeterminate = false
            sBar.stopAnimation(nil)
            sBar.doubleValue = 100 * eff / total

            sCaption.isHidden = true
            sRowA.isHidden = false
            sEpisodes.stringValue = total > 1
                ? "\(Int(done)) di \(Int(total)) episodi"
                : "\(pct)% completato"
            let speed = (state["speed_bps"] as? NSNumber)?.doubleValue ?? 0
            sSpeed.stringValue = speed > 1e5 ? fmtSpeed(speed) : ""

            let bytes = (state["bytes_now"] as? NSNumber)?.doubleValue ?? 0
            if bytes > 1e6 {
                sRowB.isHidden = false
                var piece = fmtBytes(bytes)
                if let est = (state["bytes_total_est"] as? NSNumber)?.doubleValue {
                    piece += " su " + fmtBytes(est)
                }
                sBytes.stringValue = piece
                if let eta = (state["eta_s"] as? NSNumber)?.doubleValue {
                    sEta.stringValue = fmtEta(eta)
                } else {
                    sEta.stringValue = ""
                }
            } else {
                sRowB.isHidden = true
            }
        } else {
            statusItem.button?.title = ""
            sBar.isIndeterminate = true
            sBar.startAnimation(nil)
            sRowA.isHidden = true
            sRowB.isHidden = true
            sCaption.isHidden = false
            sCaption.stringValue = "Recupero informazioni…"
        }
    }

    func applyIdleState(completedCount: Int) {
        if popover.isShown { popover.performClose(nil) }
        statusItem.isVisible = false
        sRowA.isHidden = true
        sRowB.isHidden = true
        sCaption.isHidden = false
        statusItem.button?.title = ""
        statusItem.button?.image = NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: "AnimeUnity Downloader")
        sTitle.stringValue = "Nessun download in corso"
        sBar.isHidden = true
        sBar.stopAnimation(nil)
        sCancel.isHidden = true
        sCaption.stringValue = completedCount > 0
            ? "\(completedCount) download completati in questa sessione"
            : "Incolla un link nell'app per iniziare"
    }

    func fmtBytes(_ bytes: Double) -> String {
        if bytes >= 1e9 {
            return String(format: "%.2f GB", bytes / 1e9)
                .replacingOccurrences(of: ".", with: ",")
        }
        if bytes >= 1e6 { return "\(Int((bytes / 1e6).rounded())) MB" }
        return "\(Int((bytes / 1e3).rounded())) kB"
    }

    func fmtSpeed(_ bps: Double) -> String {
        String(format: "%.1f MB/s", bps / 1e6).replacingOccurrences(of: ".", with: ",")
    }

    func fmtEta(_ seconds: Double) -> String {
        if seconds < 90 { return "meno di 2 minuti" }
        return "circa \(Int((seconds / 60).rounded())) minuti"
    }

    func startServer() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath())
        proc.arguments = ["gui.py"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectDir())
        var env = ProcessInfo.processInfo.environment
        env["GUI_NO_BROWSER"] = "1"
        proc.environment = env
        do {
            try proc.run()
            serverProcess = proc
        } catch {
            showFatal("Impossibile avviare il server Python:\n\(error.localizedDescription)")
        }
        // Se la porta era già occupata (server già attivo), il nuovo processo
        // esce subito e la finestra si collega al server esistente.
    }

    func waitForServerAndLoad(attemptsLeft: Int) {
        let task = URLSession.shared.dataTask(with: serverURL) { _, _, error in
            DispatchQueue.main.async {
                if error == nil {
                    self.webView.load(URLRequest(url: serverURL))
                } else if attemptsLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.waitForServerAndLoad(attemptsLeft: attemptsLeft - 1)
                    }
                } else {
                    self.showFatal("Il server non risponde. Controlla che Python 3 "
                        + "e le dipendenze del progetto siano installati.")
                }
            }
        }
        task.resume()
    }

    func showFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "AnimeUnity Downloader"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Chiudi")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // ---------------------------------------- URL negli appunti: suggerisci
    func applicationDidBecomeActive(_ notification: Notification) {
        guard webView != nil else { return }
        guard var text = NSPasteboard.general.string(forType: .string) else { return }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("http"), text.contains("/anime/"),
              !text.contains("\n") else { return }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript(
            "typeof suggestUrl === 'function' && suggestUrl('\(escaped)')")
    }

    // ------------------------------------------------- alert() di JavaScript
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "AnimeUnity Downloader"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    // --------------------------------------------- confirm() di JavaScript
    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "AnimeUnity Downloader"
        alert.informativeText = message
        alert.addButton(withTitle: "Annulla il download")
        alert.addButton(withTitle: "Continua a scaricare")
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    // ------------------------------------------------ messaggi da JavaScript
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "dragWindow":
            if let event = NSApp.currentEvent {
                window.performDrag(with: event)
            }
        case "zoomWindow":
            window.performZoom(nil)
        case "dockProgress":
            let pct = (message.body as? NSNumber)?.intValue ?? -1
            NSApp.dockTile.badgeLabel = pct >= 0 ? "\(pct)%" : nil
        case "downloadDone":
            NSSound(named: "Glass")?.play()
            NSApp.requestUserAttention(.informationalRequest)
            let name = message.body as? String ?? ""
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                if settings.authorizationStatus == .authorized {
                    let content = UNMutableNotificationContent()
                    content.title = "Download completato"
                    if !name.isEmpty { content.body = name }
                    let request = UNNotificationRequest(
                        identifier: UUID().uuidString, content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request) { err in
                        let msg = "UN add error=\(String(describing: err))\n"
                        if let handle = FileHandle(
                            forWritingAtPath: NSTemporaryDirectory() + "animeunity_notif.log") {
                            handle.seekToEndOfFile()
                            handle.write(msg.data(using: .utf8)!)
                            handle.closeFile()
                        }
                    }
                } else {
                    // Ripiego: API classica, funziona anche senza firma Developer
                    DispatchQueue.main.async {
                        let notif = NSUserNotification()
                        notif.title = "Download completato"
                        if !name.isEmpty { notif.informativeText = name }
                        NSUserNotificationCenter.default.deliver(notif)
                    }
                }
            }
        case "pickFolder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Scegli"
            panel.message = "Scegli la cartella di destinazione"
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let path = panel.url?.path {
                    let escaped = path
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    self.webView.evaluateJavaScript("setPickedFolder('\(escaped)')")
                }
            }
        default:
            break
        }
    }

    // --------------------------------------------------------- azioni menu
    @objc func newDownload(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        webView?.evaluateJavaScript("typeof focusUrl === 'function' && focusUrl()")
    }

    @objc func openDownloadsFolder(_ sender: Any?) {
        webView?.evaluateJavaScript("typeof openDest === 'function' && openDest()")
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Apri cartella Scaricati",
            action: #selector(openDownloadsFolder(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    // Mostra il banner anche quando l'app è in primo piano
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }

    // ------------------------------------------------------------- chiusura
    // Chiudere la finestra lascia l'app attiva nella barra dei menu
    // (i download continuano); si esce con Cmd+Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        webView.evaluateJavaScript("window.__running === true") { result, _ in
            let running = (result as? Bool) ?? false
            if running {
                let alert = NSAlert()
                alert.messageText = "Download in corso"
                alert.informativeText =
                    "Se esci ora, il download verrà interrotto. Vuoi uscire comunque?"
                alert.addButton(withTitle: "Esci")
                alert.addButton(withTitle: "Continua il download")
                let response = alert.runModal()
                NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
            } else {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = nil
        serverProcess?.terminate()
    }

    // ------------------------------------------------------------------ menu
    func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Informazioni su AnimeUnity Downloader",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Nascondi AnimeUnity Downloader",
            action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Esci da AnimeUnity Downloader",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(
            title: "Nuovo download",
            action: #selector(newDownload(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        let openItem = NSMenuItem(
            title: "Apri cartella Scaricati",
            action: #selector(openDownloadsFolder(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Modifica")
        editMenu.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Ripeti", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Seleziona tutto",
            action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Finestra")
        winMenu.addItem(
            withTitle: "Contrai",
            action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(
            withTitle: "Ingrandisci/Riduci",
            action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
