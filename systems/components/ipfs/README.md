# IPFS component boundary

These Godot components are production-shaped interfaces for local protocol and
UI work. They do not contact IPFS, IPNS, Kubo, or libp2p, and local signature/CID
previews are explicitly labeled simulations.

## Startup API

Create `IpfsStartupCoordinator` and call:

```gdscript
var result := coordinator.initialize(session_ipfs_settings, now_unix)
```

The settings dictionary uses schema `nexus.settings.ipfs/v1` and requires:

- `node_id`, `lobby_id`, `accepted_member_ids`, and `local_member_id`
- `local_peer_id` and `relay_peer_id` (Peer IDs only; no IP/DNS address)
- `epoch`, `ipns_name`, and an opaque `signing_key_handle`

Optional settings are `capabilities`, `peer_entry_ttl_seconds`, `ipns_ttl_ns`,
and `ipns_validity_seconds`. The result receipt uses stable component ID
`ipfs.startup-coordinator/v1`, is redacted, and contains the six startup stages.
It includes a deterministic CID preview and signed-record simulation, but never
claims publication or production cryptography.

This session overlay should be created only after the global fabric settings
component validates its IPFS/libp2p gates. Membership belongs in ephemeral
session state, not the persistent global profile.

## Lower-level APIs

- `IpfsDagManifest.build()` / `validate_manifest()` provide deterministic,
  bounded canonical bytes and a DAG-CBOR adapter contract.
- `IpfsContentCommitment.commit_manifest()` calculates SHA-256 and a local CID
  preview; a production multicodec/multihash adapter remains required.
- `IpnsRecordAdapter.create_unsigned()`, `simulate_sign()`,
  `sign_with_adapter()`, `verify_record()`, and `select_newer()` enforce expiry,
  monotonic sequences, and injected verification for external signatures.
- `Libp2pRelayPeerDirectory.configure()`, `upsert_peer()`, and
  `export_for_member()` store member commitments and circuit-relay routes only.
- `IpfsCatalogReplication.create_catalog_record()`, `prepare_export()`,
  `ingest_package()`, and `query()` enforce public/lobby/private visibility.
  Host authorization hooks may restrict built-in access, never widen it.

Protected catalog entries contain content pointers and commitments only. Secret
tier records cannot be replicated. All inputs are bounded and reject private-key
fields, recovery material, raw IP literals, and direct IP/DNS multiaddrs.

## Test

```bash
XDG_DATA_HOME=/tmp/multiverse-ipfs-components \
  godot --headless --path . --script res://tests/ipfs_components_test.gd
```
