//
// FileAccessProtocol.swift
// edgepulse
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Protocol packet types for file access control
enum FileAccessPacketType: UInt8 {
    case accessRequest = 0x10
    case accessResponse = 0x11
    case fileMetadataShare = 0x12
}

/// Binary encoding for file access requests
struct FileAccessRequestPacket {
    let requestId: String
    let fileId: String
    let requesterId: String
    let requesterNickname: String
    let timestamp: Date
    
    func encode() -> Data? {
        var data = Data()
        
        // Packet type
        data.append(FileAccessPacketType.accessRequest.rawValue)
        
        // Timestamp (8 bytes)
        let timestampMillis = UInt64(timestamp.timeIntervalSince1970 * 1000)
        for i in (0..<8).reversed() {
            data.append(UInt8((timestampMillis >> (i * 8)) & 0xFF))
        }
        
        // Request ID
        guard let requestIdData = requestId.data(using: .utf8), requestIdData.count <= 255 else { return nil }
        data.append(UInt8(requestIdData.count))
        data.append(requestIdData)
        
        // File ID
        guard let fileIdData = fileId.data(using: .utf8), fileIdData.count <= 255 else { return nil }
        data.append(UInt8(fileIdData.count))
        data.append(fileIdData)
        
        // Requester ID
        guard let requesterIdData = requesterId.data(using: .utf8), requesterIdData.count <= 255 else { return nil }
        data.append(UInt8(requesterIdData.count))
        data.append(requesterIdData)
        
        // Requester Nickname
        guard let nicknameData = requesterNickname.data(using: .utf8), nicknameData.count <= 255 else { return nil }
        data.append(UInt8(nicknameData.count))
        data.append(nicknameData)
        
        return data
    }
    
    static func decode(_ data: Data) -> FileAccessRequestPacket? {
        guard data.count >= 10 else { return nil }
        
        var offset = 0
        
        // Verify packet type
        guard data[offset] == FileAccessPacketType.accessRequest.rawValue else { return nil }
        offset += 1
        
        // Timestamp
        guard offset + 8 <= data.count else { return nil }
        let timestampData = data[offset..<offset+8]
        let timestampMillis = timestampData.reduce(0) { result, byte in
            (result << 8) | UInt64(byte)
        }
        offset += 8
        let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampMillis) / 1000.0)
        
        // Request ID
        guard offset < data.count else { return nil }
        let requestIdLen = Int(data[offset]); offset += 1
        guard offset + requestIdLen <= data.count else { return nil }
        guard let requestId = String(data: data[offset..<offset+requestIdLen], encoding: .utf8) else { return nil }
        offset += requestIdLen
        
        // File ID
        guard offset < data.count else { return nil }
        let fileIdLen = Int(data[offset]); offset += 1
        guard offset + fileIdLen <= data.count else { return nil }
        guard let fileId = String(data: data[offset..<offset+fileIdLen], encoding: .utf8) else { return nil }
        offset += fileIdLen
        
        // Requester ID
        guard offset < data.count else { return nil }
        let requesterIdLen = Int(data[offset]); offset += 1
        guard offset + requesterIdLen <= data.count else { return nil }
        guard let requesterId = String(data: data[offset..<offset+requesterIdLen], encoding: .utf8) else { return nil }
        offset += requesterIdLen
        
        // Requester Nickname
        guard offset < data.count else { return nil }
        let nicknameLen = Int(data[offset]); offset += 1
        guard offset + nicknameLen <= data.count else { return nil }
        guard let nickname = String(data: data[offset..<offset+nicknameLen], encoding: .utf8) else { return nil }
        
        return FileAccessRequestPacket(
            requestId: requestId,
            fileId: fileId,
            requesterId: requesterId,
            requesterNickname: nickname,
            timestamp: timestamp
        )
    }
}

/// Binary encoding for file access responses
struct FileAccessResponsePacket {
    let requestId: String
    let fileId: String
    let granted: Bool
    let encryptedFileKey: Data?
    
    func encode() -> Data? {
        var data = Data()
        
        // Packet type
        data.append(FileAccessPacketType.accessResponse.rawValue)
        
        // Granted flag
        data.append(granted ? 1 : 0)
        
        // Request ID
        guard let requestIdData = requestId.data(using: .utf8), requestIdData.count <= 255 else { return nil }
        data.append(UInt8(requestIdData.count))
        data.append(requestIdData)
        
        // File ID
        guard let fileIdData = fileId.data(using: .utf8), fileIdData.count <= 255 else { return nil }
        data.append(UInt8(fileIdData.count))
        data.append(fileIdData)
        
        // Encrypted file key (if granted)
        if granted, let keyData = encryptedFileKey {
            guard keyData.count <= 65535 else { return nil }
            let length = UInt16(keyData.count)
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
            data.append(keyData)
        } else {
            data.append(contentsOf: [0, 0])
        }
        
        return data
    }
    
    static func decode(_ data: Data) -> FileAccessResponsePacket? {
        guard data.count >= 5 else { return nil }
        
        var offset = 0
        
        // Verify packet type
        guard data[offset] == FileAccessPacketType.accessResponse.rawValue else { return nil }
        offset += 1
        
        // Granted flag
        let granted = data[offset] == 1
        offset += 1
        
        // Request ID
        guard offset < data.count else { return nil }
        let requestIdLen = Int(data[offset]); offset += 1
        guard offset + requestIdLen <= data.count else { return nil }
        guard let requestId = String(data: data[offset..<offset+requestIdLen], encoding: .utf8) else { return nil }
        offset += requestIdLen
        
        // File ID
        guard offset < data.count else { return nil }
        let fileIdLen = Int(data[offset]); offset += 1
        guard offset + fileIdLen <= data.count else { return nil }
        guard let fileId = String(data: data[offset..<offset+fileIdLen], encoding: .utf8) else { return nil }
        offset += fileIdLen
        
        // Encrypted file key
        var encryptedFileKey: Data?
        if granted {
            guard offset + 2 <= data.count else { return nil }
            let keyLength = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
            offset += 2
            
            if keyLength > 0 {
                guard offset + keyLength <= data.count else { return nil }
                encryptedFileKey = data[offset..<offset+keyLength]
            }
        }
        
        return FileAccessResponsePacket(
            requestId: requestId,
            fileId: fileId,
            granted: granted,
            encryptedFileKey: encryptedFileKey
        )
    }
}
