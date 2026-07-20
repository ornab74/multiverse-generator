# Game Basket / Shard Contract

This basket is the extension boundary between a generated world, a deterministic multiplayer shard, and AI-authored game rules. Names are deliberately generic so the framework can host familiar rule families without depending on branded game identities.

## Shared shard

Every mounted module receives the same small contract:

```text
WorldState     seed, map_hash, palette, biome, active_mutations
PeerState      signed_peer_id, display_handle, role, latency, ready
GameState      module_id, revision, turn, phase, board, pieces, history_hash
PlayerIntent   peer_id, action, target, client_tick, signature
GameEvent      server_tick, accepted_intent, resulting_state_hash
Mutation       id, precondition, transform, risk, inverse_transform
```

Only deterministic `PlayerIntent` objects enter the simulation. Images, generated terrain, chat, and AI proposals are presentation or authoring inputs; they never become the multiplayer authority.

## Mounted modules

| Generic module | State shape | First multiplayer milestone |
| --- | --- | --- |
| `chess_core` | 8×8 lattice, typed units | legal moves, capture, check state, clocks |
| `four_line` | 7×6 gravity lattice | turn validation, win lines, rematch |
| `draughts` | 8×8 lattice, stackable discs | forced captures, chains, promotion |
| `property_grid` | ring graph, parcels, balances | trades, auctions, event deck, team treasury |
| `territories` | generated region graph | orders, reinforcement, conflict resolution |

Each future module should supply a manifest, state reducer, action validator, renderer adapter, bot policy, test vectors, migration function, and inverse/rollback policy.

## Peer discovery

The username field should resolve to a signed, content-addressed peer record. An IPFS-compatible layer can distribute presence records and world assets; a chain-backed identity can optionally attest ownership or stable identity. Neither belongs in the frame-by-frame game loop. The live session should use an encrypted peer relay or authoritative shard server, exchange signed intents, and periodically agree on state hashes.

```text
display handle → signed peer record → content hash → encrypted handshake
                                          ↓
                                 deterministic game shard
```

## Autonomous morph loop

The morph engine is split into bounded black boxes:

1. **Observe** — summarize tactics, pacing, cooperation, friction, and player preferences.
2. **Propose** — emit a small typed `Mutation`; never free-form runtime code.
3. **Simulate** — replay the mutation against fixtures and recent state history.
4. **Verify** — check determinism, performance budget, exploit surface, and inverse transform.
5. **Consent** — auto-apply only low-risk cosmetic/world mutations; ask players about rule changes.
6. **Commit** — version the mutation, preserve its rollback checkpoint, and broadcast its hash.

Generated code belongs in isolated buckets with explicit capabilities. A bucket cannot access peer identity, wallets, filesystem, or networking unless its manifest grants the capability and the shard host approves it.

## Build buckets

- `multiplayer_core`: peer state, intent log, reconnect, host migration, replay verification.
- `chess_core`: complete legal state reducer and multiplayer clocks.
- `module_sdk`: schema, fixtures, renderer hooks, migration and rollback tests.
- `world_forge`: image/terrain generation, asset hashes, collision and navmesh baking.
- `peer_identity`: signed discovery records, privacy controls, block/report flows.
- `morph_engine`: proposal grammar, sandbox runner, evaluator, consent UX.
- `advanced_worlds`: streamed 3D cells, co-op objectives, agents, procedural narrative.

The practical sequence is multiplayer core → chess → the small lattice games → economic and territory graphs → bounded morphing → streamed 3D worlds.
