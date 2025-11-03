import Foundation
import CryptoKit
import CommonCrypto
import BitLogger

final class SecureMessageStore {
    static let shared = SecureMessageStore()
    private let fileManager = FileManager.default
    private let keychain = KeychainManager()
    private let queue = DispatchQueue(label: "chat.edgepulse.messagestore")
    
    private var storagePassword: String?
    private var messageCache: [String: [EdgepulseMessage]] = [:]
    private var isPasswordLoaded = false
    
    func setPassword(_ password: String) {
        queue.async {
            self.storagePassword = password
            // Store hashed password in keychain for verification
            let hashedPw = SHA256.hash(data: password.data(using: .utf8)!)
            let success = self.keychain.saveIdentityKey(Data(hashedPw), forKey: "storage_password")
            if success {
                self.isPasswordLoaded = true
                SecureLogger.info("Storage password set successfully", category: .security)
            } else {
                SecureLogger.error(NSError(domain: "SecureMessageStore", code: -1), context: "Failed to save password", category: .security)
            }
        }
    }
    
    func loadPasswordFromKeychain() -> Bool {
        return queue.sync {
            guard let storedHash = keychain.getIdentityKey(forKey: "storage_password") else {
                return false
            }
            // Password exists but we need user to provide it
            // This just verifies it's set up
            isPasswordLoaded = true
            return true
        }
    }
    
    func verifyPassword(_ password: String) -> Bool {
        return queue.sync {
            guard let storedHash = keychain.getIdentityKey(forKey: "storage_password") else {
                return false
            }
            let providedHash = SHA256.hash(data: password.data(using: .utf8)!)
            if Data(providedHash) == storedHash {
                self.storagePassword = password
                self.isPasswordLoaded = true
                return true
            }
            return false
        }
    }
    
    func isPasswordSet() -> Bool {
        return keychain.getIdentityKey(forKey: "storage_password") != nil
    }
    
    func hasActivePassword() -> Bool {
        return queue.sync { storagePassword != nil && isPasswordLoaded }
    }
    
    func storeMessage(_ message: EdgepulseMessage, forChat chatId: String) {
        queue.async {
            guard self.hasActivePassword() else {
                SecureLogger.warning("Cannot store message - no active password", category: .security)
                return
            }
            
            var messages = self.messageCache[chatId] ?? []
            messages.append(message)
            self.messageCache[chatId] = messages
            
            // Save to encrypted file
            self.persistMessages(messages, forChat: chatId)
        }
    }
    
    func storeMessages(_ newMessages: [EdgepulseMessage], forChat chatId: String) {
        queue.async {
            guard self.hasActivePassword() else {
                SecureLogger.warning("Cannot store messages - no active password", category: .security)
                return
            }
            
            var messages = self.messageCache[chatId] ?? []
            messages.append(contentsOf: newMessages)
            // Remove duplicates based on message ID
            let uniqueMessages = messages.reduce(into: [String: EdgepulseMessage]()) { dict, msg in
                dict[msg.id] = msg
            }.values.sorted { $0.timestamp < $1.timestamp }
            
            self.messageCache[chatId] = Array(uniqueMessages)
            self.persistMessages(Array(uniqueMessages), forChat: chatId)
        }
    }
    
    private func persistMessages(_ messages: [EdgepulseMessage], forChat chatId: String) {
        guard let password = storagePassword else {
            SecureLogger.warning("Cannot persist - no password", category: .security)
            return
        }
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(messages)
            
            // Derive a proper encryption key from password using PBKDF2
            let salt = "edgepulse.messages.\(chatId)".data(using: .utf8)!
            let key = try deriveKey(from: password, salt: salt)
            let sealedBox = try AES.GCM.seal(data, using: key)
            
            let url = try messageDirectory()
                .appendingPathComponent("\(chatId).enc")
            
            try sealedBox.combined?.write(to: url)
            SecureLogger.info("Persisted \(messages.count) messages for chat \(chatId)", category: .storage)
        } catch {
            SecureLogger.error(error as NSError, context: "Failed to persist messages", category: .storage)
        }
    }
    
    func loadMessages(forChat chatId: String) -> [EdgepulseMessage] {
        guard let password = storagePassword else {
            SecureLogger.warning("Cannot load messages - no password", category: .security)
            return []
        }
        
        return queue.sync {
            if let cached = messageCache[chatId] {
                return cached
            }
            
            do {
                let url = try messageDirectory()
                    .appendingPathComponent("\(chatId).enc")
                
                guard fileManager.fileExists(atPath: url.path) else {
                    return []
                }
                
                let data = try Data(contentsOf: url)
                let salt = "edgepulse.messages.\(chatId)".data(using: .utf8)!
                let key = try deriveKey(from: password, salt: salt)
                let box = try AES.GCM.SealedBox(combined: data)
                let decrypted = try AES.GCM.open(box, using: key)
                
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let messages = try decoder.decode([EdgepulseMessage].self, from: decrypted)
                messageCache[chatId] = messages
                SecureLogger.info("Loaded \(messages.count) messages for chat \(chatId)", category: .storage)
                return messages
            } catch {
                SecureLogger.error(error as NSError, context: "Failed to load messages for \(chatId)", category: .storage)
                return []
            }
        }
    }
    
    func getAllChatIds() -> [String] {
        return queue.sync {
            do {
                let url = try messageDirectory()
                let files = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                return files.compactMap { fileURL in
                    let filename = fileURL.lastPathComponent
                    if filename.hasSuffix(".enc") {
                        return String(filename.dropLast(4))
                    }
                    return nil
                }
            } catch {
                return []
            }
        }
    }
    
    func clearCache() {
        queue.async {
            self.messageCache.removeAll()
        }
    }
    
    // MARK: - Key Derivation
    
    private func deriveKey(from password: String, salt: Data) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw NSError(domain: "SecureMessageStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid password"])
        }
        
        // Use PBKDF2 to derive a key from the password
        let rounds = 100_000
        var derivedKeyData = Data(count: 32) // 256 bits
        
        let result = derivedKeyData.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        
        guard result == kCCSuccess else {
            throw NSError(domain: "SecureMessageStore", code: -2, userInfo: [NSLocalizedDescriptionKey: "Key derivation failed"])
        }
        
        return SymmetricKey(data: derivedKeyData)
    }
    
    private func messageDirectory() throws -> URL {
        let url = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("messages", isDirectory: true)
        
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        
        return url
    }
}
