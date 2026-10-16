import AppKit
import Combine
import Foundation
import RemoteCore

struct PairedTV: Codable, Identifiable, Equatable {
    var name: String
    var host: String
    var certificateSHA256: String
    var id: String { name }
}

struct PairingState: Equatable {
    enum Phase: Equatable { case choosing, connecting(String), awaitingCode(String), verifying(String) }
    var phase: Phase = .choosing
    var code = ""
    var message: String?

    var tvName: String? {
        switch phase {
        case .choosing: nil
        case .connecting(let n), .awaitingCode(let n), .verifying(let n): n
        }
    }
}

enum AppDiscoveryState: Equatable {
    case idle
    case running(app: String, index: Int, total: Int)
    case finished(found: Int)
    case unavailable
    case cancelled
}

@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable { case remote = "Remote", apps = "Apps", keyboard = "Keyboard" }
    enum Link: Equatable { case offline(String?), connecting, connected, untrusted }

    @Published var tab: Tab = .remote {
        didSet {
            if oldValue == .keyboard, tab != .keyboard { remote?.cancelTyping() }
            if tab != .apps { cancelAppDiscovery() }
        }
    }
    @Published private(set) var tvs: [PairedTV] = []
    @Published private(set) var selectedName: String?
    @Published private(set) var link: Link = .offline(nil)
    @Published private(set) var isOn = false
    @Published private(set) var currentApp: String?
    @Published private(set) var apps: [KnownApp] = KnownLinks.apps
    @Published private(set) var appDiscovery: AppDiscoveryState = .idle
    @Published private(set) var appListVerified = false
    @Published private(set) var showsDiscoveryConfirmation = false
    @Published private(set) var volume: VolumeInfo?
    @Published private(set) var textField = TextFieldState()
    @Published private(set) var typingError: String?
    @Published private(set) var directDraft = TextFieldState()
    var typingDisplay: TextFieldState { textField.active ? textField : directDraft }
    @Published private(set) var discovered: [DiscoveredTV] = []
    @Published var pairing: PairingState?
    @Published private(set) var fatalError: String?

    private var identity: ClientIdentity?
    private let discovery = Discovery()
    private var remote: RemoteSession?
    private var pairingSession: PairingSession?
    private var retryDelay: TimeInterval = 1
    private var retry: DispatchWorkItem?
    private var sessionID = UUID()
    private var pairingAttempt = UUID()
    private var appProbeAttempt = UUID()
    private var appProbeTimer: DispatchWorkItem?
    private var appScan = AppDiscoveryScan()
    private var discoveredPackagesByTV: [String: [String]] = [:]
    private var volumeStepper = VolumeStepper()
    private var volumeTimeout: DispatchWorkItem?
    private let defaults: UserDefaults
    private static let tvsKey = "pairedTVs", selectedKey = "selectedTV", appDiscoveryKey = "discoveredAppsByTV"

    var selected: PairedTV? { tvs.first { $0.name == selectedName } }

    convenience init() {
        self.init(defaults: .standard)
        startServices()
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.tvsKey), let saved = try? JSONDecoder().decode([PairedTV].self, from: data) {
            tvs = saved
        }
        if let data = defaults.data(forKey: Self.appDiscoveryKey), let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            discoveredPackagesByTV = saved
        }
        selectedName = defaults.string(forKey: Self.selectedKey) ?? tvs.first?.name
        loadAppsForSelectedTV()
        if tvs.isEmpty { pairing = PairingState() }
    }

    private func startServices() {
        do {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iRemote")
            identity = try ClientIdentity.loadOrCreate(in: dir)
        } catch {
            fatalError = error.localizedDescription
        }
        discovery.onChange = { [weak self] in self?.discoveryChanged($0) }
        discovery.start()
        connect()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectNow() }
        }
    }

    // MARK: Remote

    func press(_ key: KeyCode) {
        guard link == .connected else { return }
        cancelAppDiscovery()
        if key == .volumeUp || key == .volumeDown { volumeStepper.cancel(); volumeTimeout?.cancel() }
        remote?.press(key)
        if key == .home { tab = .remote }
    }

    func launch(_ app: KnownApp) {
        guard link == .connected, isOn, !isDiscoveringApps, !showsDiscoveryConfirmation else { return }
        remote?.launch(app.link)
    }

    var isDiscoveringApps: Bool {
        if case .running = appDiscovery { return true }
        return false
    }

    var appDiscoveryStatus: String {
        switch appDiscovery {
        case .idle: return appListVerified ? "\(apps.count) saved shortcuts. Rescan to check again." : "Suggested shortcuts. Not checked on this TV."
        case .running(let app, let index, let total): return "Checking \(app) (\(index)/\(total))"
        case .finished(let found): return "\(found) of \(KnownLinks.apps.count) shortcuts confirmed. Others were not verified."
        case .unavailable: return "TV app reports unavailable. Scan not saved."
        case .cancelled: return "Scan stopped. Saved list unchanged."
        }
    }

    func requestAppDiscovery() {
        guard link == .connected, isOn, tab == .apps, pairing == nil, !isDiscoveringApps else { return }
        showsDiscoveryConfirmation = true
    }

    func discoverApps() {
        guard link == .connected, isOn, tab == .apps, pairing == nil, showsDiscoveryConfirmation, !isDiscoveringApps else { return }
        showsDiscoveryConfirmation = false
        remote?.cancelTyping()
        volumeStepper.cancel()
        volumeTimeout?.cancel()
        appProbeAttempt = UUID()
        applyAppScanAction(appScan.start(at: ProcessInfo.processInfo.systemUptime, current: currentApp))
        scheduleAppScanTick(appProbeAttempt)
    }

    func cancelAppDiscovery() {
        showsDiscoveryConfirmation = false
        appProbeAttempt = UUID()
        appProbeTimer?.cancel()
        appProbeTimer = nil
        appScan.cancel()
        if isDiscoveringApps { appDiscovery = .cancelled }
    }

    /// The protocol has no absolute volume, so this steps toward the target with key presses.
    func setVolume(fraction: Double) {
        guard link == .connected else { return }
        cancelAppDiscovery()
        sendVolumeStep(volumeStepper.setTarget(fraction))
    }

    private func sendVolumeStep(_ key: KeyCode?) {
        guard let key else { return }
        remote?.press(key)
        volumeTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.volumeStepper.cancel() }
        volumeTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    func insertText(_ text: String) {
        guard link == .connected, tab == .keyboard else { return }
        typingError = nil
        if textField.active {
            remote?.insertText(text)
        } else if remote?.typeHardware(text) == true {
            let cursor = min(directDraft.cursor, directDraft.value.utf16.count)
            directDraft.value = (directDraft.value as NSString).replacingCharacters(in: NSRange(location: cursor, length: 0), with: text)
            directDraft.cursor = cursor + text.utf16.count
            directDraft.selectionStart = directDraft.cursor
            if directDraft.value.utf16.count > 4096 { directDraft = TextFieldState() }
        }
    }

    func textKey(_ key: KeyCode) {
        guard link == .connected, tab == .keyboard else { return }
        typingError = nil
        if textField.active {
            remote?.textKey(key)
        } else {
            remote?.press(key)
            var value = directDraft.value as NSString
            let cursor = min(directDraft.cursor, value.length)
            switch key {
            case .deleteBackward where cursor > 0:
                let range = value.rangeOfComposedCharacterSequence(at: cursor - 1)
                value = value.replacingCharacters(in: range, with: "") as NSString
                directDraft.cursor = range.location
            case .deleteForward where cursor < value.length:
                let range = value.rangeOfComposedCharacterSequence(at: cursor)
                value = value.replacingCharacters(in: range, with: "") as NSString
            case .dpadLeft: directDraft.cursor = max(0, cursor - 1)
            case .dpadRight: directDraft.cursor = min(value.length, cursor + 1)
            case .moveHome: directDraft.cursor = 0
            case .moveEnd: directDraft.cursor = value.length
            case .enter:
                directDraft = TextFieldState()
                return
            default: break
            }
            directDraft.value = value as String
            directDraft.selectionStart = directDraft.cursor
        }
    }

    func clearText() {
        guard textField.active else {
            typingError = "The TV isn't sharing its text. Use Backspace to delete characters."
            return
        }
        typingError = nil
        remote?.clearText()
    }

    func replaceText(_ range: NSRange, with text: String) {
        guard link == .connected, tab == .keyboard else { return }
        typingError = nil
        guard textField.active else {
            if range.length == 0, range.location == directDraft.cursor {
                insertText(text)
                return
            }
            typingError = "The TV isn't sharing its text. Use Backspace instead of selection replacement."
            return
        }
        remote?.replaceText(range, with: text)
    }

    func pauseTyping() { remote?.cancelTyping() }

    func stepVolume(_ up: Bool) {
        press(up ? .volumeUp : .volumeDown)
    }

    func select(_ tv: PairedTV) {
        guard tv.name != selectedName else { return }
        selectedName = tv.name
        defaults.set(tv.name, forKey: Self.selectedKey)
        connect()
    }

    func forgetSelected() {
        guard let name = selectedName else { return }
        if let tv = selected {
            discoveredPackagesByTV.removeValue(forKey: tv.certificateSHA256)
            saveAppDiscovery()
        }
        tvs.removeAll { $0.name == name }
        save()
        selectedName = tvs.first?.name
        defaults.set(selectedName, forKey: Self.selectedKey)
        connect()
        if tvs.isEmpty { pairing = PairingState() }
    }

    func reconnectNow() {
        retryDelay = 1
        connect()
    }

    private func connect() {
        sessionID = UUID()
        let attempt = sessionID
        cancelAppDiscovery()
        retry?.cancel()
        remote?.close()
        remote = nil
        currentApp = nil
        loadAppsForSelectedTV()
        appDiscovery = .idle
        isOn = false
        volume = nil
        volumeTimeout?.cancel()
        volumeStepper = VolumeStepper()
        textField = TextFieldState()
        directDraft = TextFieldState()
        typingError = nil
        guard let tv = selected, let identity else {
            link = .offline(nil)
            return
        }
        link = .connecting
        let session = RemoteSession(host: tv.host, identity: identity, pinnedCertificateSHA256: tv.certificateSHA256) { [weak self] event in
            MainActor.assumeIsolated {
                guard self?.sessionID == attempt else { return }
                self?.handle(event, from: tv.name)
            }
        }
        remote = session
        session.start()
    }

    func handle(_ event: RemoteSession.Event, from name: String) {
        guard name == selectedName else { return }
        switch event {
        case .connected:
            link = .connected
            retryDelay = 1
        case .power(let on):
            isOn = on
            if !on { cancelAppDiscovery() }
        case .currentApp(let package):
            if package != currentApp { directDraft = TextFieldState() }
            currentApp = package
            applyAppScanAction(appScan.receive(package, at: ProcessInfo.processInfo.systemUptime))
        case .volume(let v):
            volume = v
            sendVolumeStep(volumeStepper.receive(v))
        case .textField(let state):
            if state.context != textField.context { directDraft = TextFieldState() }
            textField = state
            typingError = nil
        case .typingError(let message):
            typingError = message
        case .untrustedTV:
            cancelAppDiscovery()
            link = .untrusted
            remote = nil
        case .disconnected(let reason):
            cancelAppDiscovery()
            link = .offline(reason)
            remote = nil
            scheduleRetry()
        }
    }

    private func scheduleAppScanTick(_ attempt: UUID) {
        guard attempt == appProbeAttempt, isDiscoveringApps else { return }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.appProbeAttempt == attempt, self.isDiscoveringApps else { return }
            self.advanceAppDiscovery(at: ProcessInfo.processInfo.systemUptime)
            self.scheduleAppScanTick(attempt)
        }
        appProbeTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: timer)
    }

    func advanceAppDiscovery(at now: TimeInterval) {
        guard isDiscoveringApps else { return }
        applyAppScanAction(appScan.tick(at: now))
    }

    private func applyAppScanAction(_ action: AppDiscoveryScan.Action?) {
        if let app = appScan.current {
            appDiscovery = .running(app: app.name, index: appScan.position, total: appScan.total)
        }
        switch action {
        case .home:
            remote?.press(.home)
        case .launch(let link):
            remote?.launch(link)
        case .completed(let packages):
            cancelAppDiscovery()
            saveDiscoveredApps(packages)
            appDiscovery = .finished(found: apps.count)
        case .unavailable:
            cancelAppDiscovery()
            if !appListVerified { apps = [] }
            appDiscovery = .unavailable
        case nil:
            break
        }
    }

    func saveDiscoveredApps(_ packages: [String]) {
        guard let tv = selected else { return }
        apps = KnownLinks.apps.filter { packages.contains($0.package) }
        discoveredPackagesByTV[tv.certificateSHA256] = apps.map(\.package)
        appListVerified = true
        saveAppDiscovery()
    }

    private func loadAppsForSelectedTV() {
        appListVerified = false
        guard let tv = selected else {
            apps = KnownLinks.apps
            return
        }
        guard let packages = discoveredPackagesByTV[tv.certificateSHA256] else {
            apps = KnownLinks.apps
            return
        }
        let selectedPackages = Set(packages)
        apps = KnownLinks.apps.filter { selectedPackages.contains($0.package) }
        appListVerified = true
    }

    private func saveAppDiscovery() {
        if let data = try? JSONEncoder().encode(discoveredPackagesByTV) {
            defaults.set(data, forKey: Self.appDiscoveryKey)
        }
    }

    private func scheduleRetry() {
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryDelay = min(self.retryDelay * 2, 30)
                self.connect()
            }
        }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: item)
    }

    /// A TV's DHCP address can change; Bonjour knows the new one.
    private func discoveryChanged(_ found: [DiscoveredTV]) {
        discovered = found
        for tv in found where tvs.contains(where: { $0.name == tv.name }) {
            Discovery.resolveHost(tv.endpoint) { [weak self] host in
                MainActor.assumeIsolated {
                    guard let self, let host, let i = self.tvs.firstIndex(where: { $0.name == tv.name }), self.tvs[i].host != host else { return }
                    self.tvs[i].host = host
                    self.save()
                    if tv.name == self.selectedName, self.link != .connected { self.reconnectNow() }
                }
            }
        }
    }

    // MARK: Pairing

    func beginPairing() {
        cancelAppDiscovery()
        pairingAttempt = UUID()
        pairingSession?.cancel()
        pairingSession = nil
        pairing = PairingState()
    }

    func cancelPairing() {
        pairingAttempt = UUID()
        pairingSession?.cancel()
        pairingSession = nil
        pairing = tvs.isEmpty ? PairingState() : nil
    }

    func pair(with tv: DiscoveredTV) {
        guard let identity else { return }
        pairingAttempt = UUID()
        let attempt = pairingAttempt
        pairingSession?.cancel()
        pairing = PairingState(phase: .connecting(tv.name))
        Discovery.resolveHost(tv.endpoint) { [weak self] host in
            MainActor.assumeIsolated {
                guard let self, self.pairingAttempt == attempt, self.pairing?.phase == .connecting(tv.name) else { return }
                guard let host else {
                    self.pairing = PairingState(message: "Couldn't reach \(tv.name). Is it on?")
                    return
                }
                let session = PairingSession(host: host, identity: identity, clientName: Host.current().localizedName ?? "iRemote") { [weak self] event in
                    MainActor.assumeIsolated {
                        guard self?.pairingAttempt == attempt else { return }
                        self?.pairingEvent(event, tv: tv.name, host: host)
                    }
                }
                self.pairingSession = session
                session.start()
            }
        }
    }

    func updateCode(_ raw: String) {
        guard var state = pairing, case .awaitingCode = state.phase else { return }
        state.code = String(raw.uppercased().filter { $0.isHexDigit }.prefix(6))
        state.message = nil
        pairing = state
    }

    func submitCode() {
        guard var state = pairing, case .awaitingCode(let name) = state.phase, state.code.count == 6 else { return }
        state.phase = .verifying(name)
        pairing = state
        pairingSession?.submit(code: state.code)
    }

    private func pairingEvent(_ event: PairingSession.Event, tv name: String, host: String) {
        guard pairing?.tvName == name else { return }
        switch event {
        case .awaitingCode:
            pairing = PairingState(phase: .awaitingCode(name))
        case .invalidCode(let message):
            pairing = PairingState(phase: .awaitingCode(name), code: "", message: message)
        case .paired(let hash):
            pairingSession = nil
            if let old = tvs.first(where: { $0.name == name }) {
                discoveredPackagesByTV.removeValue(forKey: old.certificateSHA256)
                saveAppDiscovery()
            }
            tvs.removeAll { $0.name == name }
            tvs.append(PairedTV(name: name, host: host, certificateSHA256: hash))
            save()
            pairing = nil
            selectedName = nil
            select(tvs.last!)
            tab = .apps
            showsDiscoveryConfirmation = true
        case .failed(let message):
            pairingSession = nil
            pairing = PairingState(message: message)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tvs) { defaults.set(data, forKey: Self.tvsKey) }
    }
}
