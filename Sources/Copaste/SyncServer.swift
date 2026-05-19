import Foundation
import Network
import CryptoKit

// MARK: - Wire types

/// Pre-auth handshake messages exchanged as plain JSON frames.
private struct WireMessage: Codable {
    enum Kind: String, Codable {
        case hello           // client → server
        case pairRequired    // server → client
        case pairRequest     // client → server
        case pairSuccess     // server → client (carries secret)
        case pairFailed      // server → client
        case authReady       // server → client (post-hello, already paired)
    }
    let kind: Kind
    // hello
    let deviceID: String?
    let deviceName: String?
    // pairRequest
    let code: String?
    // pairSuccess
    let secret: String?   // hex(32) — AES-GCM key
    let serverDeviceID: String?
    let serverDeviceName: String?
    // pairFailed
    let reason: String?
}

/// Post-auth content payload. Carried inside an AES-GCM ciphertext.
private struct SyncClipPayload: Codable {
    enum Kind: String, Codable {
        case text
        case image
        case ping
    }
    let kind: Kind
    let text: String?
    let imageBase64: String?
}

// MARK: - Delegate

protocol SyncServerDelegate: AnyObject {
    func syncServer(_ server: SyncServer, didReceiveText text: String)
    func syncServer(_ server: SyncServer, didReceiveImage data: Data)
    func syncServer(_ server: SyncServer, peerCountChanged count: Int)
    func syncServer(_ server: SyncServer, didPairDeviceNamed name: String)
}

// MARK: - SyncServer

/// Local-network clipboard sync. Listens for TCP connections, advertises
/// `_copaste._tcp` via Bonjour, performs a 6-digit pairing handshake on
/// first connect, then exchanges AES-GCM-encrypted JSON frames with each
/// paired peer.
final class SyncServer {
    weak var delegate: SyncServerDelegate?

    private(set) var port: UInt16 = 0
    private(set) var peerCount: Int = 0
    private(set) var isRunning: Bool = false

    /// Current 60-second pairing window state. nil means not pairing.
    private(set) var pairingCode: String?
    private(set) var pairingExpiresAt: Date?

    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private let queue = DispatchQueue(label: "com.copaste.sync", qos: .userInitiated)
    private var pairingTimer: Timer?
    private var heartbeatTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue() {
        guard !isRunning else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(
                name: SyncStorage.ownDeviceName,
                type: "_copaste._tcp"
            )
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: queue)
            self.listener = listener
            self.isRunning = true
            NSLog("[Copaste] SyncServer starting, advertising '\(SyncStorage.ownDeviceName)' via _copaste._tcp")
            startHeartbeat()
        } catch {
            NSLog("[Copaste] SyncServer start failed: \(error)")
        }
    }

    /// Sends a periodic encrypted ping to every authenticated peer.
    /// The phone uses these as a liveness signal — its read socket has
    /// a 25-second timeout, so without a ping every ~10s the phone
    /// concludes the link is dead and reconnects. We start one timer
    /// for the whole server (rather than per-peer) to keep things
    /// simple.
    private func startHeartbeat() {
        DispatchQueue.main.async { [weak self] in
            self?.heartbeatTimer?.invalidate()
            self?.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    let payload = SyncClipPayload(kind: .ping, text: nil, imageBase64: nil)
                    for (_, peer) in self.peers where peer.state == .authenticated {
                        guard let plain = try? JSONEncoder().encode(payload),
                              let sealed = self.encrypt(plain) else { continue }
                        let frame = self.frame(sealed)
                        peer.connection.send(content: frame, completion: .contentProcessed { _ in })
                    }
                }
            }
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        for (_, p) in peers { p.connection.cancel() }
        peers.removeAll()
        port = 0
        isRunning = false
        DispatchQueue.main.async { [weak self] in
            self?.heartbeatTimer?.invalidate()
            self?.heartbeatTimer = nil
        }
        publishPeerCount()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let p = listener?.port {
                self.port = p.rawValue
                NSLog("[Copaste] SyncServer listening on port \(p.rawValue)")
            }
        case .failed(let error):
            NSLog("[Copaste] SyncServer listener failed: \(error)")
            isRunning = false
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - Pairing window

    /// Open a 60-second pairing window. Returns the code the user should
    /// type on the phone.
    @discardableResult
    func beginPairing(window: TimeInterval = 60) -> String {
        let code = randomPairingCode()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pairingCode = code
            self.pairingExpiresAt = Date().addingTimeInterval(window)
            self.pairingTimer?.invalidate()
            self.pairingTimer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
                self?.cancelPairing()
            }
            NSLog("[Copaste] sync pairing window open, code \(code), \(Int(window))s")
        }
        return code
    }

    func cancelPairing() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pairingCode = nil
            self.pairingExpiresAt = nil
            self.pairingTimer?.invalidate()
            self.pairingTimer = nil
        }
    }

    private var isPairingOpen: Bool {
        guard let exp = pairingExpiresAt else { return false }
        return Date() < exp && pairingCode != nil
    }

    private func randomPairingCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let n = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) % 1_000_000
        return String(format: "%06d", n)
    }

    // MARK: - Broadcast (public)

    func broadcast(text: String) {
        send(SyncClipPayload(kind: .text, text: text, imageBase64: nil))
    }

    func broadcast(image data: Data) {
        send(SyncClipPayload(kind: .image, text: nil, imageBase64: data.base64EncodedString()))
    }

    private func send(_ payload: SyncClipPayload) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let plain = try? JSONEncoder().encode(payload) else { return }
            for (_, peer) in self.peers where peer.state == .authenticated {
                guard let sealed = self.encrypt(plain) else { continue }
                let frame = self.frame(sealed)
                peer.connection.send(content: frame, completion: .contentProcessed { error in
                    if let error = error {
                        NSLog("[Copaste] sync: send error: \(error)")
                    }
                })
            }
        }
    }

    // MARK: - Connection lifecycle

    private final class Peer {
        let connection: NWConnection
        var state: State = .awaitingHello
        var deviceID: String?
        var deviceName: String?

        enum State {
            case awaitingHello
            case awaitingPairRequest
            case authenticated
        }

        init(_ c: NWConnection) { self.connection = c }
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        let peer = Peer(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                NSLog("[Copaste] sync: peer ready from \(conn.endpoint)")
                self.peers[id] = peer
                self.publishPeerCount()
                self.receiveFrame(on: peer)
            case .failed(let error):
                NSLog("[Copaste] sync: peer failed: \(error)")
                self.peers.removeValue(forKey: id)
                self.publishPeerCount()
            case .cancelled:
                self.peers.removeValue(forKey: id)
                self.publishPeerCount()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func publishPeerCount() {
        let count = peers.values.filter { $0.state == .authenticated }.count
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.peerCount = count
            self.delegate?.syncServer(self, peerCountChanged: count)
        }
    }

    // MARK: - Framing

    /// 4-byte big-endian length prefix + body.
    private func frame(_ body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var f = Data(capacity: 4 + body.count)
        withUnsafeBytes(of: &length) { f.append(contentsOf: $0) }
        f.append(body)
        return f
    }

    private func receiveFrame(on peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            if error != nil || isComplete {
                peer.connection.cancel()
                return
            }
            guard let lenData = data, lenData.count == 4 else {
                peer.connection.cancel()
                return
            }
            let length = lenData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length < 50_000_000 else {
                NSLog("[Copaste] sync: bogus frame length \(length)")
                peer.connection.cancel()
                return
            }
            self.receiveBody(length: Int(length), on: peer)
        }
    }

    private func receiveBody(length: Int, on peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            if error != nil || isComplete {
                peer.connection.cancel()
                return
            }
            if let body = data {
                self.handleBody(body, on: peer)
            }
            self.receiveFrame(on: peer)
        }
    }

    private func handleBody(_ body: Data, on peer: Peer) {
        switch peer.state {
        case .authenticated:
            // Body is 12-byte IV + GCM ciphertext+tag. Decrypt, then
            // decode the SyncClipPayload.
            guard let plain = decrypt(body) else {
                NSLog("[Copaste] sync: decrypt failed — closing peer")
                peer.connection.cancel()
                return
            }
            guard let payload = try? JSONDecoder().decode(SyncClipPayload.self, from: plain) else {
                NSLog("[Copaste] sync: malformed SyncClipPayload")
                return
            }
            handleSyncClipPayload(payload, from: peer)
        case .awaitingHello, .awaitingPairRequest:
            // Plain JSON handshake.
            guard let msg = try? JSONDecoder().decode(WireMessage.self, from: body) else {
                NSLog("[Copaste] sync: malformed handshake JSON")
                peer.connection.cancel()
                return
            }
            handleHandshake(msg, on: peer)
        }
    }

    // MARK: - Handshake

    private func handleHandshake(_ msg: WireMessage, on peer: Peer) {
        switch (peer.state, msg.kind) {
        case (.awaitingHello, .hello):
            let id = msg.deviceID ?? ""
            let name = msg.deviceName ?? "Unknown device"
            peer.deviceID = id
            peer.deviceName = name

            if SyncStorage.isPaired(id) {
                // Already trusted — flip straight to encrypted mode.
                NSLog("[Copaste] sync: known peer '\(name)' (\(id)) — switching to encrypted")
                SyncStorage.touchLastSeen(id: id)
                sendHandshake(
                    WireMessage(
                        kind: .authReady,
                        deviceID: nil, deviceName: nil,
                        code: nil, secret: nil,
                        serverDeviceID: SyncStorage.ownDeviceID,
                        serverDeviceName: SyncStorage.ownDeviceName,
                        reason: nil
                    ),
                    on: peer
                )
                peer.state = .authenticated
                publishPeerCount()
            } else if isPairingOpen {
                // Unknown peer, but we're in pairing mode → wait for code.
                NSLog("[Copaste] sync: unknown peer in pairing window — awaiting code")
                sendHandshake(
                    WireMessage(
                        kind: .pairRequired,
                        deviceID: nil, deviceName: nil,
                        code: nil, secret: nil,
                        serverDeviceID: nil, serverDeviceName: nil,
                        reason: nil
                    ),
                    on: peer
                )
                peer.state = .awaitingPairRequest
            } else {
                // Reject.
                NSLog("[Copaste] sync: unknown peer '\(name)' and not in pairing mode — rejecting")
                sendHandshake(
                    WireMessage(
                        kind: .pairFailed,
                        deviceID: nil, deviceName: nil,
                        code: nil, secret: nil,
                        serverDeviceID: nil, serverDeviceName: nil,
                        reason: "not paired"
                    ),
                    on: peer,
                    closeAfter: true
                )
            }

        case (.awaitingPairRequest, .pairRequest):
            guard isPairingOpen, let code = pairingCode, msg.code == code else {
                NSLog("[Copaste] sync: pair_request rejected (code mismatch or window closed)")
                sendHandshake(
                    WireMessage(
                        kind: .pairFailed,
                        deviceID: nil, deviceName: nil,
                        code: nil, secret: nil,
                        serverDeviceID: nil, serverDeviceName: nil,
                        reason: "invalid code"
                    ),
                    on: peer,
                    closeAfter: true
                )
                return
            }
            // Code is right — save the peer and hand over the shared secret.
            // This is the one moment the secret transits in plaintext, only
            // within the user-initiated 60-second window.
            let secretHex = SyncStorage.sharedSecret().map { String(format: "%02x", $0) }.joined()
            let id = peer.deviceID ?? "unknown"
            let name = peer.deviceName ?? "Device"
            SyncStorage.upsertPairedDevice(id: id, name: name)
            sendHandshake(
                WireMessage(
                    kind: .pairSuccess,
                    deviceID: nil, deviceName: nil,
                    code: nil,
                    secret: secretHex,
                    serverDeviceID: SyncStorage.ownDeviceID,
                    serverDeviceName: SyncStorage.ownDeviceName,
                    reason: nil
                ),
                on: peer
            )
            peer.state = .authenticated
            publishPeerCount()
            // Close the pairing window — one successful pair per code.
            cancelPairing()
            NSLog("[Copaste] sync: paired '\(name)' (\(id))")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.syncServer(self, didPairDeviceNamed: name)
            }

        default:
            NSLog("[Copaste] sync: unexpected handshake message in state \(peer.state) — closing")
            peer.connection.cancel()
        }
    }

    private func sendHandshake(_ msg: WireMessage, on peer: Peer, closeAfter: Bool = false) {
        guard let body = try? JSONEncoder().encode(msg) else { return }
        let f = frame(body)
        peer.connection.send(content: f, completion: .contentProcessed { [weak peer] error in
            if let error = error {
                NSLog("[Copaste] sync: handshake send error: \(error)")
            }
            // Closing inside the send-completion handler guarantees the
            // bytes are actually on the wire before we tear the socket
            // down — otherwise a quick cancel() preempts the send and the
            // peer sees a bare EOF.
            if closeAfter {
                peer?.connection.cancel()
            }
        })
    }

    // MARK: - Authenticated payloads

    private func handleSyncClipPayload(_ payload: SyncClipPayload, from peer: Peer) {
        if let id = peer.deviceID { SyncStorage.touchLastSeen(id: id) }
        switch payload.kind {
        case .text:
            guard let t = payload.text, !t.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.syncServer(self, didReceiveText: t)
            }
        case .image:
            guard let b64 = payload.imageBase64, let data = Data(base64Encoded: b64) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.syncServer(self, didReceiveImage: data)
            }
        case .ping:
            break
        }
    }

    // MARK: - AES-GCM

    /// Encrypts plaintext under the shared secret. Output = 12-byte
    /// nonce || ciphertext || 16-byte tag. AES.GCM.SealedBox.combined gives
    /// us exactly that ordering.
    private func encrypt(_ plain: Data) -> Data? {
        let key = SymmetricKey(data: SyncStorage.sharedSecret())
        do {
            let box = try AES.GCM.seal(plain, using: key)
            return box.combined
        } catch {
            NSLog("[Copaste] sync: encrypt error: \(error)")
            return nil
        }
    }

    private func decrypt(_ blob: Data) -> Data? {
        let key = SymmetricKey(data: SyncStorage.sharedSecret())
        do {
            let box = try AES.GCM.SealedBox(combined: blob)
            return try AES.GCM.open(box, using: key)
        } catch {
            NSLog("[Copaste] sync: decrypt error: \(error)")
            return nil
        }
    }
}
