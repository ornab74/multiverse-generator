# Community Asset Forge

## Product thesis

Nexus / Forge supplies the smallest useful harness: deterministic reducers, capability boundaries, content addressing, review, consent, rollback, and adapters. Communities supply the themes, assets, voices, worlds, tests, and mutations that keep a shard evolving.

The `0.001% harness / 99.999% community` language is a creative-direction goal, not a literal ownership, token-allocation, or voting promise. Ownership and licensing still require explicit, versioned policy outside the game client.

## Non-negotiable boundaries

- A generated image, model, sound, transcript, or LLM response is never authoritative game state.
- Contribution stake ranks work for review; it cannot buy approval or replace member consent.
- Compute contribution is opt-in, bounded, revocable, metered, and isolated. A lobby cannot silently harvest a member's machine.
- Workers receive capability-scoped immutable inputs, never private keys, wallet credentials, plaintext direct messages, raw IP addresses, or arbitrary executable payloads.
- Generated work remains staged until content scanning, provenance review, deterministic validation where applicable, and the lobby's required vote complete.
- The current Godot slice creates local interface receipts and offline chain drafts only. It performs no live IPFS publication, Hive broadcast, Solana submission, model inference, or remote worker execution.

## Per-game generation surfaces

| Module | Image/UI generation | Audio generation | Rule-safe output |
| --- | --- | --- | --- |
| Chess Core | board materials, piece families, move-path language, HUD theme, accessible contrast variants | selection, check, capture, clock, ambience, optional piece voice set | cosmetic package referencing the unchanged Chess reducer |
| Four Line | rail, well, token, drop-trail, board-frame, HUD, colorblind symbol variants | drop, collision, alignment, victory, ambience | cosmetic package referencing the unchanged 7×6 reducer |
| Draughts | tile materials, disc and king families, capture-path language, HUD, contrast variants | move, crown, chain capture, victory, ambience | cosmetic package referencing the unchanged 8×8 reducer |
| Property Grid | parcel families, pawn families, ownership bands, event cards, economy HUD | roll, purchase, event, turn, ambience, optional narrator | cosmetic package referencing the unchanged 16-space reducer |

Rule mutations are separate typed proposals. They require fixtures, replay hashes, inverse transforms, rollback state, deterministic security review, and the configured consent policy.

## Generation job lifecycle

```text
player intent
  -> bounded prompt compiler
  -> policy and secret scan
  -> immutable draft + contribution budget
  -> lobby proposal
  -> direct consent / scoped delegation
  -> deterministic compute partition plan
  -> isolated model adapters
  -> quorum comparison and artifact scan
  -> provenance manifest + content commitment
  -> IPFS staging draft
  -> Hive/Solana commitment drafts
  -> native Godot preview
  -> explicit publish/mount vote
  -> reversible shard release
```

Each artifact manifest should bind:

- source prompt hash and compiler version;
- model family, adapter version, policy, seed when available, and license declaration;
- contributor IDs represented as pseudonymous member handles;
- worker capability receipts without raw network coordinates;
- input/output hashes, media type, dimensions/duration, and safety-scan receipts;
- target module, presentation slot, accessibility variants, and fallback asset;
- proposal, vote, epoch, rollback, and publication commitment IDs.

## Compute-hive accounting

Raw RAM is useful capacity telemetry, but it does not automatically become one large machine. Distributed inference also depends on accelerator memory, interconnect bandwidth, topology, compatible runtimes, model licensing, worker availability, verification overhead, and the model's partitioning strategy.

Capacity math must remain literal:

- `100 × 4 GB = 400 GB` raw offered RAM;
- `1,000 × 4 GB = 4,000 GB` raw, approximately `4 TB` decimal;
- `10,000 × 4 GB = 40,000 GB` raw, approximately `40 TB` decimal;
- `50,000 × 20 GB = 1,000,000 GB` raw, approximately `1 PB` decimal—not `24 TB`.

The scheduler reports raw offered capacity separately from estimated usable capacity:

```text
usable = raw
       × availability factor
       × contribution limit
       × scheduler headroom
       ÷ replication / verification factor
```

No UI may translate a RAM total directly into claims such as “can train a 1.5T model” or “can generate a complete AAA game.” Those outcomes need measured model-specific plans and benchmark receipts.

## Governance

Three independent signals are retained:

1. **Contribution budget** limits what a member is willing to spend.
2. **Advisory stake score** helps order competing proposals and can include bounded prior shard activity.
3. **Consent** authorizes the mutation or publication.

The first two never manufacture the third. Online members must directly consent where unanimity is configured. Offline members may opt into a narrow, expiring delegation for a known proposal class; delegation is revocable and cannot authorize secret access, executable code, or expanded external writes.

## Multi-chain publication map

- **IPFS/IPNS:** immutable artifact bytes, manifests, public catalogs, and mutable directory pointers. Protected catalogs contain encrypted capability envelopes rather than plaintext membership or addresses.
- **Hive:** compact `custom_json` commitment and community discovery metadata; never the asset body, friend graph, or DM content.
- **Solana:** program-derived checkpoint commitment for shard revision, rules commitment, directory commitment, and rollback epoch; never raw media or secrets.
- **Local device tier:** non-exportable key handles, drafts, cached protected assets, and secret-tier data excluded from upcycle queries.

The same artifact may therefore have a public content commitment, a lobby-sealed catalog entry, and a device-private draft without collapsing their access tiers.

## Model adapter policy

Adapters may eventually target image generators, Bark-compatible audio/voice generation, speech-to-text, vision review, code generation, world synthesis, and local/open-weight models. The core accepts declarative job specifications only. Provider SDKs, credentials, downloads, licenses, and network consent belong in separately audited host adapters.

Every adapter must support cancellation, resource ceilings, no-secret logging, provenance receipts, safe output formats, deterministic seeds where possible, and a local fallback. Generated code is treated as an untrusted proposal and never executed by the generation worker.
