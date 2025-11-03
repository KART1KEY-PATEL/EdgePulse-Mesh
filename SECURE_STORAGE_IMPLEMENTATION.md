# Secure Storage Implementation Guide

## Overview

This implementation provides a comprehensive secure storage system for EdgePulse that encrypts and stores all messages and files locally on the device with password protection and granular access control.

## Features Implemented

### 1. **Password-Protected Storage**
- User sets a master password on first app launch
- Password is used to derive encryption keys using PBKDF2 (100,000 rounds)
- Password hash stored in Keychain for verification
- All messages and files encrypted with AES-GCM-256

### 2. **Automatic Message Storage**
- All received messages (text and files) are automatically encrypted and stored locally
- Messages organized by chat ID (public/private conversations)
- Deduplication based on message ID
- Efficient caching to minimize disk I/O

### 3. **Secure File Management**
- Each file gets a unique encryption key
- File keys are encrypted with user's password
- File metadata stored separately (filename, size, owner, permissions)
- Support for file attachments in messages

### 4. **Access Control System**
- Files are password-protected by default
- Only authorized users can access files
- Request/response protocol for file access
- Owner can grant or deny access requests
- Automatic unlocking for owner using saved password

## Architecture

### Core Components

#### 1. SecureMessageStore (`Storage/SecureMessageStore.swift`)
Handles encrypted storage of messages:
- Password management and verification
- Message encryption/decryption using AES-GCM
- PBKDF2 key derivation for security
- Message caching and persistence
- Support for multiple chat conversations

**Key Methods:**
```swift
func setPassword(_ password: String)
func verifyPassword(_ password: String) -> Bool
func storeMessage(_ message: EdgepulseMessage, forChat chatId: String)
func loadMessages(forChat chatId: String) -> [EdgepulseMessage]
```

#### 2. SecureFileManager (`Storage/SecureFileManager.swift`)
Manages encrypted file storage and access control:
- File encryption with unique keys per file
- Access control lists (ACLs) per file
- File access request/response handling
- Metadata management

**Key Methods:**
```swift
func encryptAndStoreFile(_ url: URL, ownerId: String, mimeType: String?, isPublic: Bool) throws -> String
func decryptFile(_ fileId: String, requesterId: String) throws -> (data: Data, metadata: FileMetadata)
func createAccessRequest(forFile fileId: String, requesterId: String, requesterNickname: String) -> FileAccessRequest?
func grantAccess(requestId: String, ownerId: String) throws -> FileAccessResponse
func denyAccess(requestId: String, ownerId: String) throws -> FileAccessResponse
```

#### 3. EdgepulseMessage Model (`Models/EdgepulseMessage.swift`)
Enhanced to support file attachments:
```swift
struct FileAttachment: Codable, Equatable {
    let fileId: String
    let fileName: String
    let mimeType: String?
    let fileSize: Int64
    let isEncrypted: Bool
}
```

#### 4. File Access Protocol (`Protocols/FileAccessProtocol.swift`)
Binary protocol for file access requests/responses:
- `FileAccessRequestPacket`: Request access to a file
- `FileAccessResponsePacket`: Grant/deny access response
- Efficient binary encoding for mesh network transmission

#### 5. UI Components

**PasswordSetupView** (`Views/PasswordSetupView.swift`)
- Password strength indicator
- Confirmation field
- Validation and error handling
- Cannot be dismissed until password is set

**FileAccessRequestView** (`Views/FileAccessRequestView.swift`)
- Display pending access requests
- Grant/deny interface
- File metadata display

## Security Features

### Encryption
- **Algorithm**: AES-GCM-256 (authenticated encryption)
- **Key Derivation**: PBKDF2-HMAC-SHA256 with 100,000 iterations
- **Salt**: Unique per chat/file for key derivation
- **Random Keys**: Each file gets a cryptographically random 256-bit key

### Password Security
- Minimum 8 characters required
- Strength indicator (weak/medium/strong)
- Password hash stored in iOS Keychain
- Never stored in plaintext
- Secure memory clearing after use

### Access Control
- Owner-based permissions
- Explicit grant/deny for each request
- Per-file access control lists
- Public/private file modes

## Usage Flow

### Initial Setup
1. App launches for first time
2. `PasswordSetupView` presented automatically
3. User creates strong password
4. Password hash saved to Keychain
5. User can now send/receive messages and files

### Sending a File
```swift
// 1. Encrypt and store file
let fileId = try SecureFileManager.shared.encryptAndStoreFile(
    fileURL,
    ownerId: myPeerId,
    mimeType: "image/jpeg",
    isPublic: false
)

// 2. Create message with file attachment
let attachment = EdgepulseMessage.FileAttachment(
    fileId: fileId,
    fileName: "photo.jpg",
    mimeType: "image/jpeg",
    fileSize: 1024000,
    isEncrypted: true
)

let message = EdgepulseMessage(
    sender: myNickname,
    content: "Check out this photo!",
    timestamp: Date(),
    isRelay: false,
    fileAttachment: attachment
)

// 3. Send message via mesh network
chatViewModel.sendMessage(message)

// 4. Store locally
SecureMessageStore.shared.storeMessage(message, forChat: chatId)
```

### Receiving a File
```swift
// 1. Receive message with file attachment
func didReceiveMessage(_ message: EdgepulseMessage) {
    // Store message
    SecureMessageStore.shared.storeMessage(message, forChat: chatId)
    
    // Check if has file attachment
    if let attachment = message.fileAttachment {
        // Try to access file
        do {
            let (data, metadata) = try SecureFileManager.shared.decryptFile(
                attachment.fileId,
                requesterId: myPeerId
            )
            // File accessible - display it
            displayFile(data, metadata: metadata)
        } catch {
            // Access denied - request access
            if let request = SecureFileManager.shared.createAccessRequest(
                forFile: attachment.fileId,
                requesterId: myPeerId,
                requesterNickname: myNickname
            ) {
                // Send request to file owner via mesh
                sendAccessRequest(request, to: message.senderPeerID)
            }
        }
    }
}
```

### Handling Access Requests
```swift
// Owner receives access request
func didReceiveAccessRequest(_ request: FileAccessRequest) {
    // Show UI to grant/deny
    // User taps "Grant"
    let response = try SecureFileManager.shared.grantAccess(
        requestId: request.requestId,
        ownerId: myPeerId
    )
    
    // Send response back to requester
    sendAccessResponse(response, to: request.requesterId)
}

// Requester receives response
func didReceiveAccessResponse(_ response: FileAccessResponse) {
    if response.granted {
        // Store the file key
        try SecureFileManager.shared.handleAccessResponse(response, forPeerId: myPeerId)
        
        // Now can decrypt the file
        let (data, metadata) = try SecureFileManager.shared.decryptFile(
            response.fileId,
            requesterId: myPeerId
        )
        displayFile(data, metadata: metadata)
    } else {
        showAlert("Access denied by owner")
    }
}
```

## Integration Points

### ChatViewModel Integration
To auto-save messages, add to `ChatViewModel`:

```swift
// In didReceiveMessage or similar method
func handleIncomingMessage(_ message: EdgepulseMessage) {
    // Existing message handling...
    
    // Auto-save to encrypted storage
    let chatId = message.isPrivate ? message.senderPeerID?.id ?? "unknown" : "public"
    SecureMessageStore.shared.storeMessage(message, forChat: chatId)
}

// Load messages on app start
func loadStoredMessages() {
    guard SecureMessageStore.shared.hasActivePassword() else { return }
    
    let chatIds = SecureMessageStore.shared.getAllChatIds()
    for chatId in chatIds {
        let messages = SecureMessageStore.shared.loadMessages(forChat: chatId)
        // Populate UI with stored messages
        if chatId == "public" {
            self.messages.append(contentsOf: messages)
        } else {
            // Load private chat messages
        }
    }
}
```

### EdgepulseApp Integration
Already implemented in `EdgepulseApp.swift`:
- Password setup check on launch (lines 57-59)
- PasswordSetupView sheet presentation (line 129-131)

## File Storage Structure

```
ApplicationSupport/
├── messages/
│   ├── public.enc              # Encrypted public chat messages
│   ├── <peerID>.enc            # Encrypted private chat messages
│   └── ...
└── securefiles/
    ├── metadata.json           # File metadata (encrypted)
    ├── <fileId>                # Encrypted file data
    ├── <fileId>.key            # Encrypted file key
    └── ...
```

## Next Steps for Full Integration

1. **ChatViewModel Integration**
   - Add message auto-save calls in message receive handlers
   - Load stored messages on app launch
   - Handle file attachment sending/receiving

2. **Mesh Protocol Integration**
   - Add file access request/response packet types to protocol
   - Implement packet handlers in mesh service
   - Route requests to appropriate peers

3. **UI Updates**
   - Add file attachment button to message input
   - Display file attachments in message bubbles
   - Show file access request notifications
   - Add settings to view/manage stored files

4. **Testing**
   - Test password setup flow
   - Test message encryption/decryption
   - Test file access request/response flow
   - Test with multiple devices

## Security Considerations

### Strengths
✅ Strong encryption (AES-GCM-256)
✅ Proper key derivation (PBKDF2)
✅ Per-file encryption keys
✅ Access control system
✅ Password stored securely in Keychain

### Limitations
⚠️ Password cannot be recovered if forgotten
⚠️ File keys transmitted over mesh (should use public key encryption in production)
⚠️ No key rotation mechanism
⚠️ No backup/restore functionality

### Recommendations for Production
1. Implement public key encryption for file key exchange
2. Add biometric authentication option
3. Implement secure backup mechanism
4. Add key rotation for long-lived files
5. Implement forward secrecy for messages
6. Add secure deletion (overwrite before delete)

## Troubleshooting

### Password Not Saving
- Check Keychain entitlements
- Verify app group configuration
- Check logs for keychain errors

### Files Not Decrypting
- Verify password is active
- Check file permissions
- Ensure file key exists

### Access Requests Not Working
- Verify mesh network connectivity
- Check packet encoding/decoding
- Ensure owner ID matches

## API Reference

See inline documentation in source files for detailed API documentation.

## License

This implementation is released into the public domain under the Unlicense.
