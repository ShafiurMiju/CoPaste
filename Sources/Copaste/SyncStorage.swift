import Foundation
import Security

/// Persistent state for the sync feature:
/// - This Mac's stable device ID (UUID, kept in UserDefaults)
/// - The shared AES-GCM secret used by every paired device (kept in Keychain)
/// - The list of paired devices' IDs + display names (kept in UserDefaults —
///   non-sensitive metadata only; the secret itself never leaves the Keychain)
enum SyncStorage {
    private static let ownDeviceIDKey = "Copaste.sync.ownDeviceID"
    private static let pairedDevicesKey = "Copaste.sync.pairedDevices"
    private static let keychainService = "com.copaste.app.sync"
    private static let sharedSecretAccount = "shared-secret"

    struct PairedDevice: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var lastSeen: Date?
    }

    // MARK: - Own identity

    static var ownDeviceID: String {
        if let id = UserDefaults.standard.string(forKey: ownDeviceIDKey), !id.isEmpty {
            return id
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: ownDeviceIDKey)
        return new
    }

    static var ownDeviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    // MARK: - Paired devices

    static func listPairedDevices() -> [PairedDevice] {
        guard let data = UserDefaults.standard.data(forKey: pairedDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    static func isPaired(_ deviceID: String) -> Bool {
        listPairedDevices().contains(where: { $0.id == deviceID })
    }

    static func upsertPairedDevice(id: String, name: String) {
        var devices = listPairedDevices()
        if let idx = devices.firstIndex(where: { $0.id == id }) {
            devices[idx].name = name
            devices[idx].lastSeen = Date()
        } else {
            devices.append(PairedDevice(id: id, name: name, lastSeen: Date()))
        }
        writeDevices(devices)
    }

    static func touchLastSeen(id: String) {
        var devices = listPairedDevices()
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[idx].lastSeen = Date()
        writeDevices(devices)
    }

    static func removePairedDevice(id: String) {
        var devices = listPairedDevices()
        devices.removeAll { $0.id == id }
        writeDevices(devices)
        // The shared secret survives a single unpair on purpose — other
        // devices that share the same secret keep working. We only clear
        // the secret when the user removes the *last* paired device.
        if devices.isEmpty {
            deleteSharedSecret()
        }
    }

    private static func writeDevices(_ devices: [PairedDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: pairedDevicesKey)
        }
    }

    // MARK: - Shared secret (Keychain)

    /// Returns the existing secret, or generates + stores a fresh 32-byte
    /// AES key on first call.
    static func sharedSecret() -> Data {
        if let existing = keychainLoad(account: sharedSecretAccount) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        let data = Data(bytes)
        keychainSave(account: sharedSecretAccount, data: data)
        return data
    }

    private static func deleteSharedSecret() {
        keychainDelete(account: sharedSecretAccount)
    }

    // MARK: - Keychain plumbing

    private static func keychainSave(account: String, data: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainLoad(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func keychainDelete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
