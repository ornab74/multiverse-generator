# Governance and AI Review

This foundation governs mutations that can change a shared Nexus / Forge shard. It is deliberately conservative: untrusted proposals become typed, hashed manifests; deterministic replay and a security review can quarantine them; and verified human consent is the only path to approval.

The implementation is isolated in:

- `systems/governance_engine.gd`
- `systems/security_review_agent.gd`
- `tests/governance_engine_test.gd`
- `tests/security_review_agent_test.gd`

The Fabric screen exercises this layer through a fixed safe proposal: it builds
three deterministic replay receipts, constructs the exact model request contract,
runs only the local mock reviewer, and displays the non-authoritative result. The
shared-world mutation workbench remains the human consent surface; no front-end
button can bypass `finalize()` or sign on a member's behalf.

## Authority model

The order of authority is fixed:

1. Local schema, capability, manifest, and deterministic checks fail closed.
2. A host-supplied cryptographic verifier authenticates delegations, revocations, and consent records.
3. Online lobby members make the authoritative decision for rule, asset, and code changes.
4. The security-review agent is advisory. It may cause quarantine, but an `allow` result can never approve a proposal.
5. The weighted activity score is advisory. It is displayed as context and is never consulted by `finalize()`.

Neither proposal text nor model output may override these rules.

## Threat model

The layer assumes every proposal field, asset description, generated rule, model response, peer record, and replay report may be hostile or malformed. Defenses include:

- bounded string, array, dictionary, nesting, identifier, and path handling;
- exact capability allowlists and least-privilege checks;
- rejection of traversal, absolute paths, URLs, non-finite numbers, control characters, and unsupported Variant types;
- prompt-injection marker detection before any model contract is built;
- stable canonical serialization and SHA-256 digests for content, manifests, proposals, reviews, and replay fingerprints;
- domain separation between a manifest digest and a proposal digest;
- at least three identical replay results bound to the proposal hash;
- strict structured output for the future Responses boundary;
- no tools, network client, environment-key access, or API execution in the review agent;
- quarantine on missing evidence, malformed output, digest mismatch, unsafe capability, injection marker, or nondeterminism.

The marker scan is defense in depth, not a complete prompt-injection detector. The durable protection is that untrusted bytes are delimited as data, the model receives no tools, its output is schema-validated, and its decision has no approval authority.

## Typed proposal diff

Each change is represented by `GovernanceEngine.ProposalDiff` with:

- `change_type`: cosmetic, rule, asset, or code;
- `operation`: add, replace, or remove;
- `target`: a relative logical target such as `rules/bridge_memory`;
- `before_value` and `after_value`: sanitized bounded values kept locally;
- `before_hash` and `after_hash`: SHA-256 digests committed to the manifest;
- `capability`: the one capability needed for the diff;
- `metadata`: rollback checkpoints, reducer versions, or asset provenance.

The manifest contains hashes rather than executable values. The current capability mapping is:

| Change | Required capability | Consent scope |
| --- | --- | --- |
| Cosmetic | `world.visual.write` | author consent |
| Rule | `rules.propose` | `rule` |
| Asset | `assets.mount` | `asset` |
| Code | `code.module.mount` | `code` |

`world.read` and `telemetry.aggregate` are available to future read-only workflows, but a mutation requesting capabilities not required by its diff is quarantined as overprivileged.

## Proposal state machine

```text
DRAFT
  ├─ invalid schema/capability/hash/injection ──> QUARANTINED
  └─ sanitized + manifested ────────────────────> AWAITING_REVIEW
                                                     │
                         deterministic replay PASS ──┤
                         mock security allow ────────┤
                                                     v
                                             AWAITING_CONSENT
                                                     │
                           unanimous verified vote ──> APPROVED
                           verified rejection ───────> REJECTED

Any live state ── expiry ──> EXPIRED
Any integrity or review failure ──> QUARANTINED
```

Quarantine is intentionally sticky in this slice. There is no automatic release method. A production release path should require a separately audited human-security resolution, a new manifest/proposal hash, and fresh consent rather than mutating the quarantined object in place.

## Deterministic replay contract

`verify_deterministic_replays()` expects at least three replay records. Every record must contain:

- the exact `proposal_hash`;
- `input_hash`;
- `output_state_hash`;
- `event_log_hash`;
- `reducer_version`;
- `tick_count`.

All stable fields must match across replays. A mismatch quarantines the proposal. Replay workers should execute in a deterministic sandbox with network, wall-clock, random-device, and ambient filesystem access disabled. This class verifies their signed/hashed reports; it is not itself a code sandbox.

## Consent and lobby membership

For any proposal containing a rule, asset, or code diff:

- every online member must submit a direct `approve` proof bound to the lobby, member, decision, and proposal hash;
- any verified rejection moves the proposal to `REJECTED`;
- a missing online approval prevents finalization;
- an advisory score cannot substitute for a missing approval.

The engine does not implement public-key cryptography. Construct it with a host-owned `Callable` that verifies the proof against the exact expected payload. With no verifier, all proofs fail closed.

```gdscript
var governance := GovernanceEngine.new(Callable(crypto_boundary, "verify_record"))
var proposal := governance.create_proposal(spec, Time.get_unix_time_from_system())

var replay_report := governance.verify_deterministic_replays(proposal, replay_records)
var envelope := security_agent.build_review_envelope(
    proposal.proposal_hash,
    proposal.manifest_hash,
    proposal.manifest,
    replay_report
)
governance.attach_security_review(proposal, security_agent.mock_review(envelope))

# `proof` must be created by the member and verified by `crypto_boundary`.
governance.record_consent(proposal, "q7", "approve", proof, now_unix)
var result := governance.finalize(proposal, now_unix)
```

## Offline trusted-lobby delegation

An offline member is not silently represented. They may explicitly opt into delegation with a verified authorization containing:

- exact lobby ID;
- delegator and delegate IDs;
- one or more of `rule`, `asset`, and `code`;
- an expiry no more than 30 days away;
- the purpose string `trusted_lobby_delegation`.

Delegation works only while the delegate is an online member of that same lobby and its scope covers every sensitive change in the proposal. It is never cross-lobby, transitive, implied by friendship, or permanent.

Revocation is immediate and requires a verified record bound to the delegation authorization hash. Revoked or expired delegations disappear from subsequent consent requirements. Audit storage should retain their authorization and revocation hashes.

## Advisory weighting without capture

Historical playtime is bounded at 500 hours and historical activity at 1,000 events. The normalized influence of any member is then capped at `0.35`. If the capped member shares total less than one, the unassigned share contributes a neutral `0.5`, rather than being redistributed to the most active members.

This produces a useful “experienced lobby sentiment” signal while preventing one high-playtime account from dominating it. The report always contains `authoritative: false`, and the governance state cannot change when the score is attached.

## Security review agent contract

`SecurityReviewAgent.build_responses_request()` returns a serializable request contract for the OpenAI Responses API with:

- model `gpt-5.6-sol`;
- `reasoning: { "effort": "max" }`;
- `store: false`;
- no tools;
- stable developer instructions before dynamic data;
- untrusted JSON enclosed by explicit delimiters;
- a strict `text.format` JSON Schema.

This shape follows the official [Responses structured-output format](https://developers.openai.com/api/docs/guides/structured-outputs), and the selected model/effort are supported by the current [OpenAI model catalog](https://developers.openai.com/api/docs/models).

The class only builds a dictionary. It contains no `HTTPRequest`, socket, SDK, API-key lookup, environment-variable lookup, or send method. In this repository, only `mock_review()` is executed.

The mock reviewer deterministically checks manifest hashes, capability entries, typed diff fields, safe targets, content hashes, lifecycle fields, replay evidence, and injection markers. Its output is tagged:

```json
{
  "source": "mock",
  "authoritative": false,
  "disposition": "allow | quarantine | reject"
}
```

`GovernanceEngine.attach_security_review()` accepts only that mock source in this slice. A future network adapter must live outside these files and must not become an approval oracle. It should validate refusals and strict schema output, bind the response to the exact proposal/manifest hashes, stamp its own local audit digest, and feed findings into quarantine review. The unanimous verified human vote remains mandatory.

## Test commands

```bash
godot --headless --log-file /tmp/nexus-governance-test.log --path . \
  --script tests/governance_engine_test.gd

godot --headless --log-file /tmp/nexus-security-review-test.log --path . \
  --script tests/security_review_agent_test.gd
```

The explicit `/tmp` log paths avoid writing editor logs outside restricted workspaces.

## Production follow-ups

Before mounting this into live gameplay:

1. Implement the injected verifier with the project’s real member keys and replay-protected signatures.
2. Persist manifests, proofs, delegation events, review findings, and state transitions in an append-only audit log.
3. Run rule and code proposals in a deterministic sandbox before producing replay records.
4. Resolve assets by content hash and verify size, media type, parser safety, license/provenance, and decompression limits.
5. Add a human security-release flow that creates a fresh proposal instead of unquarantining mutable bytes.
6. Fuzz nested Variant values, malformed Unicode, duplicate JSON keys, large inputs, signature replay, and membership churn.
7. Define membership snapshots so a member going online or offline cannot race an in-progress vote.
