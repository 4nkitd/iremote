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

@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable { case remote = "Remote", apps = "Apps", keyboard = "Keyboard" }
    enum Link: Equatable { case offline(String?), connecting, connected, untrusted }

    @Published var tab: Tab = .remote {
        didSet { if oldValue == .keyboard, tab != .keyboard { remote?.cancelTyping() } }
    }
    @Published private(set) var tvs: [PairedTV] = []
    @Published private(set) var selectedName: String?
    @Published private(set) var link: Link = .offline(nil)
    @Published private(set) var isOn = true
    @Published private(set) var currentApp: String?
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
    private var volumeStepper = VolumeStepper()
    private var volumeTimeout: DispatchWorkItem?
    private let defaults = UserDefaults.standard
    private static let tvsKey = "pairedTVs", selectedKey = "selectedTV"

    var selected: PairedTV? { tvs.first { $0.name == selectedName } }

    init() {
        if let data = defaults.data(forKey: Self.tvsKey), let saved = try? JSONDecoder().decode([PairedTV].self, from: data) {
            tvs = saved
        }
        selectedName = defaults.string(forKey: Self.selectedKey) ?? tvs.first?.name
        do {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iRemote")
            identity = try ClientIdentity.loadOrCreate(in: dir)
        } catch {
            fatalError = error.localizedDescription
        }
        discovery.onChange = { [weak self] in self?.discoveryChanged($0) }
        discovery.start()
        if tvs.isEmpty { pairing = PairingState() }
        connect()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectNow() }
        }
    }

    // MARK: Remote

    func press(_ key: KeyCode) {
        guard link == .connected else { return }
        if key == .volumeUp || key == .volumeDown { volumeStepper.cancel(); volumeTimeout?.cancel() }
        remote?.press(key)
        if key == .home { tab = .remote }
    }

    func launch(_ app: KnownApp) {
        guard link == .connected else { return }
        remote?.launch(app.link)
    }

    /// The protocol has no absolute volume, so this steps toward the target with key presses.
    func setVolume(fraction: Double) {
        guard link == .connected else { return }
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
        retry?.cancel()
        remote?.close()
        remote = nil
        currentApp = nil
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

    private func handle(_ event: RemoteSession.Event, from name: String) {
        guard name == selectedName else { return }
        switch event {
        case .connected:
            link = .connected
            retryDelay = 1
        case .power(let on):
            isOn = on
        case .currentApp(let package):
            if package != currentApp { directDraft = TextFieldState() }
            currentApp = package
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
            link = .untrusted
            remote = nil
        case .disconnected(let reason):
            link = .offline(reason)
            remote = nil
            scheduleRetry()
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
            tvs.removeAll { $0.name == name }
            tvs.append(PairedTV(name: name, host: host, certificateSHA256: hash))
            save()
            pairing = nil
            selectedName = nil
            select(tvs.last!)
        case .failed(let message):
            pairingSession = nil
            pairing = PairingState(message: message)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tvs) { defaults.set(data, forKey: Self.tvsKey) }
    }
}
