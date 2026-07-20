# Secure Shard Fabric Architecture

Status: protocol foundation and interface simulation  
Implementation: `res://systems/shard_fabric.gd`  
Executable contract: `res://tests/shard_fabric_test.gd`

## Read this first

This repository does **not** currently perform ML-KEM cryptography, run libp2p or
IPFS, publish IPNS records, or submit Hive/Solana transactions. Every adapter
receipt is labeled `INTERFACE_SIMULATION_ONLY`, every protected envelope says
`cryptography_performed: false`, and simulated identifiers use visibly synthetic
prefixes where possible.

The implementation is a security-oriented protocol seam. It lets the UI, shard
directory, lobby, and rules systems integrate against stable types without
claiming that mock hashes are encryption or that generated strings are live chain
transactions.

## Non-negotiable persistence invariants

The shard catalog must never persist:

- raw IPv4 or IPv6 addresses;
- private, secret, recovery, or seed key material;
- plaintext direct messages;
- a plaintext friend list or friend graph;
- plaintext lobby/private/secret payloads;
- device secrets in logs, adapter receipts, snapshots, or replicated records.

`ShardFabric` rejects common sensitive field names recursively and rejects IP
literals in payloads, access policies, imported node catalogs, lobby identifiers,
and relay lists. Protected payloads are reduced to a labeled one-way simulation
envelope; the original dictionary is not retained.

This is defense in depth, not a complete data-loss-prevention system. Production
adapters still need strict typed schemas, log redaction, fuzzing, secure memory,
and independent review.

## Initialization workflow

Initialization begins with a validated settings gate and then enters a monotonic
seven-stage state machine:

```text
validated settings profile + explicit consent policy
    -> device identity
    -> ML-KEM-768 capability
    -> libp2p relay route + PeerID
    -> IPFS CID + signed IPNS directory contract
    -> Hive directory commitment
    -> Solana PDA commitment
    -> ready
```

| Stage | Interface output | Production responsibility |
|---|---|---|
| Device identity | Device/node IDs and non-exportable key handles | OS keystore or hardware-backed key creation; attestation where available |
| ML-KEM-768 | Capability and public-key fingerprint | Audited ML-KEM implementation, downgrade protection, algorithm agility |
| libp2p relay | PeerID and `/p2p-circuit` route | Peer identity binding, relay reservation, NAT traversal, connection gating |
| IPFS/IPNS | Directory CID and IPNS name | Canonical DAG encoding, signed record publication, pinning and expiry policy |
| Hive | Directory commitment | Signed transaction, finality policy, replay/idempotency handling |
| Solana | PDA commitment | Program-derived address checks, account owner checks, finalized commitment |
| Ready | Read-only public snapshot | Permit catalog writes only after all mandatory capabilities succeed |

The settings gate is implemented by
`res://systems/components/fabric_network_settings.gd`. It supports simulation,
local-adapter, and locked testnet-review profiles, rejects secret-bearing fields,
raw IP literals, credentialed/unsafe endpoints, payload logging, raw-address
advertising, and live writes without the exact service and global consent flags.
Its redacted settings receipt is the first receipt in every startup run.

## Concrete component layout

The componentized local stack is executable and independently tested:

| Component | Implementation | Local responsibility |
|---|---|---|
| Settings/preflight | `systems/components/fabric_network_settings.gd` | Validate profile, runtime capabilities, retention, tier visibility, logging, and explicit network consent |
| DAG manifest | `systems/components/ipfs/ipfs_dag_manifest.gd` | Canonical bounded manifest construction and validation |
| Content commitment | `systems/components/ipfs/ipfs_content_commitment.gd` | SHA-256 content verification and explicitly simulated CID previews |
| IPNS records | `systems/components/ipfs/ipns_record_adapter.gd` | Monotonic unsigned records, expiry/replay checks, simulated proof, external signer/verifier seam |
| Relay directory | `systems/components/ipfs/libp2p_relay_peer_directory.gd` | Member-authorized `/p2p-circuit` routes, expiry, epoch rotation, no direct address routes |
| Catalog replication | `systems/components/ipfs/ipfs_catalog_replication.gd` | Tier-aware package/export/ingest/query with tamper checks and no secret-tier replication |
| IPFS startup | `systems/components/ipfs/ipfs_startup_coordinator.gd` | Compose the IPFS pieces from a session-scoped overlay and return a redacted receipt |
| Hive | `systems/components/hive_commitment_component.gd` | Strict commitment-only `custom_json` operation drafts, authority policy, monotonic nonce protection |
| Solana | `systems/components/solana_checkpoint_component.gd` | PDA/checkpoint interface drafts, exact accounts/flags, nonce/revision/parent-link checks |
| Whole workflow | `systems/fabric_initialization_workflow.gd` | Enforce settings as gate zero, run every local component, and return only redacted receipts/pointers |

The Hive and Solana components intentionally reject RPC fields and signing
material. Their outputs are unsigned drafts with `broadcast_performed: false`.
The Solana PDA is explicitly a deterministic interface placeholder with no
curve check. The IPFS CID uses a simulation namespace and IPNS publication remains
false. Production adapters must replace those seams without weakening the same
validators.

Failure in a real adapter must move the coordinator to `FAILED`, wipe volatile
secrets, and avoid publishing partial identity links. The simulation completes
synchronously so screens and tests stay deterministic.

## Adapter boundary

Replace each mock independently behind an equivalent async production adapter:

```text
DeviceIdentityAdapter
  create_identity() -> public identity + opaque non-exportable handles

KemAdapter
  capability() -> negotiated suite
  encapsulate(public_key_handle) -> ciphertext + shared-secret handle
  decapsulate(ciphertext, private_key_handle) -> shared-secret handle

Libp2pAdapter
  bind_identity(device_key_handle) -> PeerID
  reserve_relay() -> opaque relay route (never a stored socket address)

IpfsDirectoryAdapter
  put(canonical_envelope) -> CID
  publish_ipns(CID, signing_handle, sequence) -> signed receipt

HiveCommitmentAdapter / SolanaCommitmentAdapter
  commit(directory_digest, previous_digest, nonce) -> finalized receipt

VaultAdapter
  derive(parent_handle, context) -> child handle
  seal(handle, bytes, associated_data) -> authenticated ciphertext
  destroy(handle) -> acknowledgement
```

Opaque handles, not private bytes, cross these boundaries. Adapter errors and
receipts must be structured and redacted before logging.

## Data tiers

| Tier | Catalog representation | Replication | Authorization |
|---|---|---|---|
| Public | Validated plaintext plus content commitment | IPFS/IPNS; Hive and Solana commitments | Anyone |
| Lobby | Ciphertext envelope and lobby/epoch/member commitments | IPFS ciphertext | Matching lobby capability **and** committed member PeerID |
| Private | Ciphertext envelope and explicit reader commitments | IPFS ciphertext where policy permits | Owner or committed reader |
| Secret | Device-bound envelope | Never leaves the local device catalog | Matching device capability plus explicit secret-query intent |

Access lists contain SHA-256 commitments in this foundation, not plaintext user
or lobby identifiers. A plain unsalted hash is insufficient for low-entropy
identifiers in production. Use keyed commitments or random capability IDs.

Protected catalog queries return envelope metadata, not decrypted payloads.
Decryption belongs in a short-lived authorized view owned by the consuming
subsystem. That view must not write decrypted values back to the catalog.

## Key hierarchy

The manifest is intentionally exportable; the material is not.

```text
root handle (hardware/OS-backed in production)
└── device handle
    ├── lobby epoch handle: H(lobby capability), epoch, member commitments
    │   └── content handles: rules, assets, votes, peer bucket
    ├── DM ratchet/bootstrap handle per remote peer commitment
    │   └── content handles per conversation epoch/message batch
    └── content handles for private and device-local records
```

The current class derives deterministic simulated material into a private volatile
dictionary. `get_public_snapshot()`, key manifests, receipts, records, exports,
and upcycle results expose only handles and commitments. Calling
`clear_volatile_secrets()` wipes that dictionary best-effort and prevents further
protected publishing.

Production changes required:

- root and device private keys never enter GDScript memory;
- lobby epoch rotation occurs on join, leave, ban, compromise, or configured age;
- DM security uses an audited asynchronous ratchet after authenticated PQ/hybrid
  session establishment, not a static shared key;
- content keys are unique per object or bounded batch;
- old lobby epoch keys follow an explicit retention and secure-deletion policy;
- recovery is separated from day-to-day device keys.

ML-KEM-768 (the standardized descendant of Kyber) is a key encapsulation
mechanism, not a bulk cipher. The contract therefore pairs it with a KDF and an
AEAD. The simulation names XChaCha20-Poly1305 as the application envelope
contract; final suite selection requires cryptographic review and platform
support analysis.

## Bee “waggle” lobby surface

“Waggle” is treated as the application protocol above libp2p, not a new
cryptographic primitive. A lobby waggle exchanges:

1. PeerID and signed invite capability;
2. current lobby epoch and rules/asset manifest commitments;
3. IPNS directory link;
4. per-member ML-KEM encapsulations of the epoch secret;
5. signed availability and vote events;
6. relay route references.

The fabric method `publish_lobby_peer_bucket()` only accepts relay PeerIDs. It
rejects raw IP literals and seals the peer list into a lobby-tier simulation
envelope. In production, socket addresses may exist transiently inside the
libp2p transport process, but they must not cross into Godot state, IPFS objects,
analytics, crash reports, Hive, or Solana.

An IPNS lobby directory should point to a canonical encrypted object containing
the current peer bucket, epoch, expiry, and previous-object digest. Members reject
expired objects, epoch rollback, non-member signatures, and forks that do not
resolve under the lobby's consensus policy.

## Friends and direct messages

`commit_friend_edge()` sorts two transient PeerIDs and publishes only an edge
commitment and lifecycle status. It does not build or expose a friend graph. A
production design should use keyed/blinded commitments so chain observers cannot
guess common PeerIDs or correlate social edges.

`publish_dm_ciphertext_pointer()` accepts only a ciphertext CID reference, commits
that reference, and then puts the commitment inside a private-tier envelope. It
never accepts a message body. Actual DM ciphertext storage, ratcheting, delivery
receipts, deletion semantics, abuse reporting, and multi-device sync belong to a
separate audited messaging subsystem.

## IPFS, Hive, and Solana responsibilities

IPFS is content transport, not authorization. Anyone who obtains a CID may fetch
its bytes. Confidentiality must come from correctly implemented authenticated
encryption and key distribution, while signatures protect authorship and
integrity.

IPNS supplies a mutable signed pointer. Readers must validate signer, sequence,
expiry, schema, previous digest, and lobby epoch before accepting an update.

Hive and Solana store small commitments and protocol state only:

- directory root digest and previous digest;
- schema/protocol version;
- monotonic nonce or epoch;
- ruleset and asset-manifest commitments;
- optional vote/result commitments;
- revocation or recovery commitments.

They must not store PeerID lists, lobby addresses, friend edges in guessable form,
DM metadata, content keys, or encrypted blobs merely because the blobs are
encrypted. Public-chain metadata is permanent and globally correlatable.

The two chain anchors need an explicit reconciliation rule. Suggested policy:

1. IPNS is the fast availability pointer;
2. a Hive commitment is the social/audit checkpoint;
3. a Solana PDA is the program-verifiable lobby/rules checkpoint;
4. clients accept a new root only when its parent is known and required anchor
   thresholds/finality are met;
5. disagreement freezes mutation activation and opens a recovery review.

## Upcycle catalog

The upcycle surface forms a read model over local and imported node catalogs:

```text
signed remote catalog envelopes
        -> schema / origin / simulation-label validation
        -> raw-IP and sensitive-field rejection
        -> node-partitioned deduplication
        -> tier authorization filter
        -> kind / tier / origin filters
        -> deterministic visible result set
```

`register_remote_catalog()` refuses secret records, origin mismatches, unsupported
schemas, unlabeled mock records, IP literals, and forbidden fields.
`upcycle_query()` checks authorization before returning a record. Visibility
metrics count only records the caller can already see, which avoids turning the
metrics endpoint into an existence oracle.

Production imports additionally require signatures, canonical encoding, replay
windows, maximum object sizes, decompression limits, DAG traversal budgets,
schema version negotiation, and per-peer resource quotas.

## Rule, asset, and lobby governance integration

Rule and asset mutations should be content-addressed immutable proposals. A
proposal contains commitments to:

- base shard and base revision;
- canonical typed rule diff;
- deterministic engine/runtime version;
- asset manifest with media types, sizes, and licenses;
- sanitizer and simulation reports;
- required voter snapshot and lobby epoch;
- vote policy and expiry;
- resulting revision if accepted.

Online-member unanimity, trusted-lobby delegation for offline users, and weighted
voting can all be expressed as signed vote events. Weight calculations must be
snapshotted at proposal creation, deterministic, capped, inspectable, and resistant
to play-time farming. Never let weighting silently override a member's explicit
security veto for permission expansion, executable content, key rotation, or data
visibility changes.

An LLM security reviewer is advisory defense in depth. Even a high-reasoning model
must receive a bounded, redacted proposal rather than private lobby data. Its
output is untrusted input that passes the same schema validator and cannot mint
capabilities, access secrets, cast a human vote, relax sanitization, or bypass a
failed deterministic check. Record model/version/policy commitments, not hidden
reasoning or private prompts, in the audit trail.

## Production sanitizer gates

Before a proposal can be voted on, run independent deterministic gates:

- strict schema allowlists; reject unknown fields and polymorphic ambiguity;
- canonical serialization and digest verification;
- archive path traversal, symlink, expansion-ratio, and file-count limits;
- image/audio decode in a sandbox with dimension and duration limits;
- shader/material complexity budgets;
- no native libraries, scripts, bytecode, external URLs, or dynamic resource
  loading from user assets;
- rule DSL instruction, recursion, allocation, and wall-clock budgets;
- Unicode normalization and confusable-name handling;
- deterministic replay of fixtures and adversarial turns;
- signature, epoch, voter-set, and base-revision validation;
- quarantine on any adapter, scanner, simulation, or consensus disagreement.

## Test contract

Run the focused test with:

```bash
godot --headless --path . --script res://tests/shard_fabric_test.gd
```

The test covers:

- exact initialization-state order and simulation labels;
- root, device, lobby epoch, DM, and content key handles;
- public, lobby, private, and secret catalog behavior;
- protected-envelope creation with no retained payload;
- raw IP, private-key field, plaintext DM, and lobby-IP rejection;
- friend-edge commitment and DM ciphertext-pointer APIs;
- authorization filtering for outsiders, lobby members, private readers, and the
  device-bound secret view;
- authorized aggregation and filtering across two node catalogs;
- absence of rejected/private plaintext values in snapshots and visible catalogs;
- refusal to create protected records after volatile key clearing.

Passing this test proves the simulation contract, not production security.
