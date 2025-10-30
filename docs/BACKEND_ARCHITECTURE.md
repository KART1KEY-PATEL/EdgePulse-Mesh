# EdgePulse — Backend & Mesh Networking Architecture (Technical Report)

This document focuses exclusively on backend systems: peer discovery and mesh formation, storage & distribution, indexing & lookup, the peer-to-peer transfer protocol, synchronization and consistency, and security/key management. It assumes the codebase components (BLEService, NoiseEncryptionService, GossipSyncManager, MeshTopologyTracker, MessageDeduplicator, TransferProgressManager, etc.) described in the repository.

---

## Executive summary (one-liner)
A dual-role BLE mesh (central + peripheral), Noise-authenticated transport, and a gossip-based index provide decentralized, privacy-first storage and retrieval of sharded, encrypted file data with multi-hop routing, anti-entropy synchronization, and robust replay/DoS protections.

---

## 1. Node discovery and mesh formation

High-level goals
- Low-energy discovery on mobile devices.
- No central registry; peers discover via BLE adverts and mutual announce messages.
- Authentication uses Noise (XX) with long-term static Curve25519 keys; identity fingerprints are SHA256(staticPubKey).

1.1 BLE discovery model (practical implementation)
- Each node advertises a single service UUID (application constant) and exposes a single characteristic for notifications/writes.
- Advertising payload: service UUID only (no Local Name) for privacy; core announce content flows over characteristic notifications (announce packets).
- Scanning: central-side scanning uses "allow duplicates" when foreground to accelerate discovery. A duty-cycle can reduce scanning when many neighbors exist.
- Dual-role pattern: devices act as peripheral (advertise) and central (scan & connect). This enables both push (notify) and direct write paths.

1.2 Establishing and authenticating a connection
- Discovery -> subscription: when central subscribes, peripheral delays a small post-subscribe announce.
- Identity exchange & authentication:
  - Announce packet contains: nickname, Noise static public key (Curve25519), Ed25519 signing public key, and neighbor hints.
  - Announce optionally carries an Ed25519 signature over a canonical announce byte sequence (peerID, noisePub, edPub, nickname, timestamp). Verification uses the signing public key present in the announce.
  - For session establishment across transports, the Noise_XX handshake is used (Noise_XX_25519_ChaChaPoly_SHA256). The handshake:
    - Provides mutual authentication of static keys,
    - Establishes ephemeral session keys,
    - Produces a per-session transport cipher and replay window.
  - Fingerprint = SHA256(NoiseStaticPublicKey) used for out-of-band verification and local trust marking.

1.3 Mesh topology management and healing
- Graph model:
  - A MeshTopologyTracker records direct links (myRoutingID <-> neighborRoutingID) and learned routes (sequence of hops).
  - Routes are stored as ordered lists of routingData (8-byte short IDs).
- Join:
  - New node: advertise -> receive announce from neighbor -> verify signature -> persisted identity -> add neighbor into local graph, send announce back (bidirectional discovery), and participate in gossip sync.
- Leave:
  - Graceful: send leave packet; peers remove direct link and update mesh topology.
  - Hard disconnect: link inactivity timeouts and reachability retention windows prune stale peers.
- Healing & re-routing:
  - Periodic maintenance checks (ble/mesh maintenance timer) refresh announces, attempt reconnections, and recompute routes.
  - When a link fails, nodes recompute best routes using BFS/shortest-path on the local graph; if route exists, packets can be forwarded along that route (see routing below).
  - Gossip rebroadcast of recent announces and limited fan-out relays ensure alternate paths are discovered.

---

## 2. Data storage and distribution strategy

Design goals
- Files stored encrypted (owner-side) before any network distribution.
- Provide redundancy so files survive node churn and partitions.
- Minimize bandwidth while enabling reconstruction from available peers.

2.1 Content addressing and manifests
- Files are content-addressed:
  - File content is first chunked and each chunk hashed with SHA-256 → chunkID.
  - A manifest (metadata) lists chunkIDs, byte sizes, order, MIME, file-level encryption metadata (encrypted symmetric key), erasure coding parameters (if used), and optional preimage info (Merkle root).
  - Manifest itself is content-addressed (manifestID = SHA256(manifestBytes)) and stored like any other object.
- Storage layout (local):
  - On-disk chunk store: directory of chunk files keyed by chunkID (hex).
  - Metadata DB (lightweight SQLite or file-backed map) mapping manifestID → manifest + local chunk reference counts.
  - Retention policy and LRU for cleanup.

2.2 Chunking and sharding strategy
Two complementary modes (configurable):
A) Simple replication (fast, robust):
  - Split file into fixed-size chunks (e.g., 64 KiB).
  - Replicate each chunk to N distinct peers (N = replication factor).
  - Index metadata announces which peers hold that chunk (see Section 3).
B) Sharded/erasure-coded (space efficient):
  - Apply Reed-Solomon (k,n) erasure coding per file: encode original data to n shards; any k shards suffice to reconstruct.
  - Each shard becomes a chunk object (content hashed). Manifest records (k,n) and shard indices.
  - Balancing: choose n based on desired redundancy and expected churn.
  - Benefits: storage efficiency vs pure replication.

2.3 Chunk management data structures
- Chunk record (in-memory & persisted):
  - chunkID: SHA256
  - size: bytes
  - stores: set of PeerShortIDs (recently seen owners)
  - localPresent: boolean
  - lastAnnouncedAt: timestamp
- Manifest record:
  - manifestID, chunkIDs[], encoding (plain/erasure), reconstructParams, ownerFingerprint, encryptedFileKeyMetadata
- Garbage collection:
  - Reference counting for locally stored chunks and LRU eviction under storage pressure.
  - Coordination: when a manifest is removed, readers remove local references and optionally trigger gossip to indicate removed availability.

---

## 3. Data indexing and lookup protocol

Challenges
- No global DHT server, limited connectivity and mobile churn.
- Bluetooth mesh topologies are local and dynamic; a global DHT is impractical.

3.1 Hybrid local DHT + gossip index (practical adaptation)
- Each node maintains a local index (IndexStore) mapping chunkID → set of PeerShortIDs that recently announced availability.
- Discovery and advertisement:
  - When a node stores a chunk, it issues a small index announcement (AnnouncementPacket variant or dedicated IndexAnnouncement) with entries: [chunkID, peerShortID, timestamp].
  - Index announcements are gossiped with bounded fan-out and deduplicated using a Bloom filter (OptimizedBloomFilter) to avoid loops.
- Aggregate exchange:
  - Periodically (or on join), nodes exchange compact index digests (Bloom filters or small Merkle summaries) with direct neighbors via RequestSync/ResponseSync.
  - Bloom filter exchange enables identification of candidate peers who likely have chunk(s) of interest.
- Lookup algorithm (two phase):
  1. Local check: see if local chunk store has content.
  2. Local index check: see peers in local index; if a direct link to a listed peer exists, request chunk directly.
  3. Expand search via multi-hop routing:
     - Query neighbors for chunkID (iterative breadth-limited RPC). Query includes a TTL hop budget to avoid flooding.
     - If index indicates remote peers, issue targeted RequestSync to nodes that are likely to hold the chunk (use manifest->owners mapping).
  4. If still not found, escalate via gossip sync: request neighbor to perform a broader search or leverage out-of-band relays (Nostr) if available.

3.2 Index consistency and update propagation
- Index announcements are ephemeral and time-limited; nodes prune index entries older than a configurable TTL.
- Anti-entropy:
  - Periodic, randomized pairwise sync sessions exchange index digests (Bloom or Merkle).
  - Missing entries are requested and merged.
- Conflict model:
  - Index ownership is not single-authoritative; multiple nodes can claim to host a chunk. The system is eventually consistent: entries converge via periodic anti-entropy and announcements.
- Efficiency:
  - For large indexes, use sharding of index messages (by chunk prefix) and bloom filters sized to the active set.

---

## 4. Peer-to-peer communication and data transfer protocol

4.1 Packet framing and envelope
- Binary framed `EdgepulsePacket` with:
  - header fields (version, type, TTL, timestamp, flags, payload length, sender short ID, optional recipient short ID, optional signature).
  - payload: either application-level (e.g., announce, index announcement, manifest) or Noise transport bytes (for encrypted content).
  - Padding to selected block sizes (256/512/1024) to obscure true lengths.
- Top-level types include: announce, message, fileTransfer, fragment, noiseHandshake, noiseEncrypted, requestSync.

4.2 Noise transport layering
- Two-layer approach:
  - Control & public payloads (announce, index messages) may be signed and optionally encrypted (signed announce required).
  - Private transfers (private messages, file chunk requests/responses) use Noise transport (per-peer Noise session). NoiseMessage wrapper used for handshake/transport types.
- The Noise session provides AEAD (ChaCha20-Poly1305) encryption, associated data (header), and replay protection (nonce window).

4.3 Transfer request/response format
- Chunk request:
  - Typed Noise payload or a public Request message: [type: request_chunk, chunkID, manifestID (optional), preferred offset].
  - If encrypted: the request is Noise-encrypted to the peer owning the chunk.
- Chunk response:
  - Typed Noise payload: [type: chunk_response, chunkID, seq, totalSize, chunkBytes, checksum].
  - For large chunk objects (files/shards), use fragmentation (fragment packets) with transferId and per-fragment index / total count.
- Fragmentation:
  - Each fragment contains fragmentID (random 8 bytes), index (uint16), total (uint16), originalType, fragment bytes.
  - Receiver assembles by fragment key (senderShort + fragmentID). Guardrails: cap total fragments and overall reconstruction size.
  - TransferProgressManager tracks fragment progress and issues acknowledgments.
- Checksums & integrity:
  - Each chunk payload includes SHA256 digest for integrity; fragments include inner checksums for reassembly verification.
  - Final chunk verification checks computed digest against chunkID.

4.4 Multi-hop routing (store-and-forward)
- If target node is not directly connected, packets are routed along computed routes:
  - Route computation uses the MeshTopologyTracker graph: compute a shortest path (BFS) based on known direct neighbor links and routing hints in announce metadata.
  - Packets carry a route array; nodes forward to the next hop described there.
  - TTL is decremented each hop; if TTL falls to 0, the node processes the packet if it is the intended recipient but does not relay.
- Relay control:
  - RelayController decides whether to relay a packet based on TTL, type, degree, and probabilistic fanout (k-of-n deterministic selection using seed derived from message ID).
  - Deduplication: MessageDeduplicator + OptimizedBloomFilter prevents infinite loops and redundant relays.
- Directed store-and-forward:
  - When no current path to recipient exists, the sender spools directed packets in pendingDirectedRelays keyed by recipient short ID and tries again when a direct link becomes available (bounded spool window).

4.5 Reliability, acknowledgments, and retransmission
- For small, idempotent control messages: best-effort with gossip redundancy.
- For chunk transfers:
  - Per-transfer transferId is used. The sender expects per-fragment progress events from TransferProgressManager; missing fragments are retransmitted with exponential backoff.
  - Acks:
    - Per-fragment implicit acknowledgement via progress manager or explicit small ACK messages (depending on link reliability). For BLE writes, lack of write confirmation triggers requeue/retry.
    - end-of-transfer ack (DELIVERED) is sent once the receiver successfully reconstructs and verifies checksum of the full chunk or manifest.
- Packet loss handling:
  - Fragment-level reassembly checks detect missing sequences; re-request only missing fragments.
  - Non-responsive peers cause the requesting node to fallback to other owners found in the index.

---

## 5. Data synchronization and consistency model

5.1 Eventual consistency via gossip + anti-entropy
- Every node participates in:
  - Local announcements of stored chunks and manifests,
  - Periodic anti-entropy syncs (digest exchange) with neighbors,
  - Opportunistic sync triggered on connect / reconnection.
- Digest design:
  - Bloom filters or compact Merkle summaries of local manifestIDs and chunkIDs reduce bandwidth for discovery.
  - Upon discovering differences (neighbor reports some IDs we lack), the node requests specific manifests or chunk availability lists.
- Merge semantics:
  - Index entries are additive (peer X has chunk Y). Removal uses tombstones: a small delete announcement with timestamp for that manifest/chunk; tombstones expire after a retention period (or are removed by admin).
  - For conflicting deletes vs adds, last-writer-wins by monotonic timestamp (wall-clock) with caution; stronger semantics can use signed sequence numbers from owners.

5.2 Node rejoin flow (fast catch-up)
- On reconnection:
  1. Node advertises presence (announce).
  2. Node runs a compact sync: exchange Bloom filter summarizing local manifestIDs.
  3. Neighbors reply with missing manifestIDs and optional direct owner lists for missing chunkIDs.
  4. Node requests manifests and then chunk owners; fetch chunks directly (or via multi-hop).
  5. Optionally run a manifest Merkle diff to find reassignment/updates more efficiently.
- Incremental catch-up minimizes bandwidth; full re-sync only when local store is empty or manifest root diverges.

---

## 6. Security, privacy, and encryption (backend implementation)

6.1 File encryption and key management (end-to-end)
- File encryption model:
  - Each file is encrypted with a randomly generated symmetric key (FileKey) using an AEAD cipher (ChaCha20-Poly1305 or AES-GCM).
  - Manifest stores metadata: encryption algorithm, nonce, and FileKey encrypted to intended recipients (encrypted-file-key bundles).
- Distributing FileKey to recipients:
  - Asymmetric encryption: derive a shared secret per recipient using X25519 (Curve25519 key agreement) or use Noise-established session keys to encrypt the file key for that recipient.
  - Implementation choices:
    - If distributing to many recipients (e.g., group), encrypt the FileKey once to a group key or use per-recipient wrapped keys.
    - For ephemeral one-off shares (e.g., geohash DMs), use the per-geohash identity derived via idBridge and encrypt the file key to that public key.
- Offline delivery:
  - If recipient is offline, store the encrypted manifest & encrypted FileKey on multiple nodes (replicas). When recipient reconnects and requests manifest, they can obtain the encrypted FileKey and decrypt it locally.

6.2 Key material storage & rotation
- Long-term keys:
  - Noise static key pair (Curve25519) and Ed25519 signing key persist in platform Keychain managed by KeychainManagerProtocol.
  - Fingerprints = SHA256(staticPub).
- Rotations:
  - Rekey sessions periodically via NoiseSessionManager rekeying.
  - For file keys, rotate when sharing policy changes.

6.3 Authentication, integrity, and non-repudiation
- Announce signing:
  - Ed25519 signatures over canonical announce bytes provide integrity for identity claims.
  - Announce verification helps detect replay/spoofed announces.
- Packet signatures:
  - EdgepulsePacket can include Ed25519 signatures for origin authentication (used for file transfers & announces).
- Replay protection:
  - Noise transport includes nonces and sliding-window replay protection.
  - The transport-level nonce and packet-level timestamps guard replay attacks.

6.4 Transport security beyond BLE link-layer
- Bluetooth link-layer encryption (LE Secure Connections) protects the radio hop but does not provide end-to-end privacy across multi-hop.
- End-to-end encryption is enforced by:
  - Noise sessions for per-peer transport encryption; all private payloads traverse Noise.
  - File-level symmetric encryption ensures stored data is unreadable without FileKey regardless of where chunks are stored.
- Denial-of-Service and rate limiting:
  - NoiseRateLimiter and NoiseRateLimiter.allowHandshake / allowMessage functions throttle abusive handshake/message rates.
  - Fragmentation caps and pending queue size limits prevent memory exhaustion.

6.5 Trust model and out-of-band verification
- Trust is social and local:
  - Users verify fingerprints (SHA256 of Noise public key) OOB (QR or read-aloud).
  - Verified fingerprints marked locally in SecureIdentityStateManager influence UI and reachability retention.
- Blocking & favorites:
  - Local blocking causes immediate discard of packets from blocked fingerprints at earliest stage to avoid processing cost and privacy leakage.

---

## 7. Operational & algorithmic details

7.1 Routing algorithms
- Shortest path: simple BFS on local graph for route computation.
- Deterministic subset selection for broadcast (K-of-N fanout):
  - Score-based deterministic selection using SHA256(seed || "::" || id) to select a stable subset for relaying given messageID seed.
  - subsetSizeForFanout uses log2(n) heuristic to balance spread vs redundancy.

7.2 Deduplication and loop prevention
- Per-message deduplication: messageDeduplicator with time-limited retention and OptimizedBloomFilter for fast membership tests.
- IngressByMessageID maps messageIDs -> {link, timestamp} to prevent sending a packet back to the link it arrived from.

7.3 Fragmentation & reassembly
- Fragment metadata includes fragmentID, index, total, originalType.
- Assembly guardrails: cap total fragments (max), cap total reassembled size, timeouts for incomplete assemblies, and eviction policies for stale assemblies.

7.4 Performance & battery considerations
- Scanning duty-cycle and adaptive RSSI thresholds manage discovery vs battery.
- Prioritize smaller fragments and favor writeWithoutResponse for speed; queue heavier writes to avoid saturation.
- ActiveTransfer caps limit concurrent heavy transfers.

---

## 8. Practical deployment considerations & failure modes

8.1 Common failure scenarios
- Partitioning: use replication and erasure coding. When partitioned, nodes in each partition continue to serve local requests; cross-partition fetch fails until reconnection.
- High churn: increase replication factor or reduce rebalancing aggressiveness.
- Malicious peers: authenticated announces mitigate spoofing; rate limiting mitigates DoS; local blocklists and identity verification prevent persistent abuse.

8.2 Tuning knobs
- replication factor (N) vs erasure coding (k,n).
- fragment chunk size (default tuned to BLE MTU minus overhead).
- index announcement frequency and bloom filter sizes.
- transfer concurrency caps and maintenance/announce intervals.

---

## 9. Summary: data flow (end-to-end example)
1. User A encrypts file -> generates FileKey -> encrypts file into chunks (or erasure shards) -> computes chunkIDs and manifest.
2. A stores chunks locally, persists manifest, and issues index announcements advertising chunkIDs -> peers gossip index.
3. Node B wants the file:
   - B fetches manifestID (e.g., by known manifestID, or by search).
   - B consults local index: finds owners for chunkIDs.
   - B opens Noise sessions to owners (handshake if needed).
   - B requests chunks (possibly multi-hop) and reassembles; integrity checks via chunk digests.
   - B decrypts using FileKey (received encrypted to B's public key or via session-wrapped FileKey).
4. On reconnection, A and B catch up using digest exchange (bloom/merkle) and request missing manifests/chunks.

---

## 10. Implementation mapping (codebase pointers)
- BLE transport and discovery: `BLEService.swift` (advertising, scanning, connection, read/write, fragmented send).
- Noise sessions & handshakes: `NoiseEncryptionService.swift` and `NoiseSessionManager` (handshake, encrypt/decrypt wrappers, rekey).
- Packet framing, types and fragmentation: `EdgepulsePacket`, `PrivateMessagePacket`, `EdgepulseFilePacket`, `fragment` handling in `BLEService`.
- Gossip sync & index exchange: `GossipSyncManager` (scheduling, onPublicPacketSeen), plus RequestSync/ResponseSync handlers.
- Identity management and verification: `SecureIdentityStateManagerProtocol`, `idBridge` (per-geohash identities).
- Transfer orchestration: `TransferProgressManager` + Fragment assembly logic in `BLEService`.

---

## 11. Extensions & next steps (recommended)
- Add explicit manifest Merkle trees for efficient divergence detection and PRUNING.
- Add optional storage incentive or fairness mechanism (e.g., tit-for-tat) to encourage replication.
- Implement encrypted sealed-box (libsodium sealed box) wrappers for FileKey distribution to non-interactive recipients.
- Provide privacy-preserving indexing (private set membership / PIR) for large networks.

---

End of document.
