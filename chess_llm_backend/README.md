# Nexus Chess local Gemma backend

This Flutter process is the private, loopback-only inference runtime for the
Godot single-player chess application. On Linux, Windows, and macOS, Godot
starts and owns the bundled desktop executable. It does not use the old Naza
vault or `moto-lens` application state.

## Runtime contract

- Binds only to `127.0.0.1` on `NEXUS_CHESS_LLM_PORT` (default `47621`).
- Requires a fresh 32-256 character RFC 6750 bearer token in
  `NEXUS_CHESS_LLM_TOKEN`; every route, including health, requires it.
- Forces `PreferredBackend.cpu`, disables speculative decoding, images, audio,
  and concurrent sessions, and aborts initialization if the plugin reports any
  backend other than CPU.
- Accepts only the pinned `gemma-4-E2B-it.litertlm` identity: exactly
  `2,583,085,056` bytes and SHA-256
  `ab7838cdfc8f77e54d8ca45eadceb20452d9f01e4bfade03e5dce27911b27e42`.
- A missing model may be downloaded only over credential-free HTTPS from the
  pinned Hugging Face revision and its required Hugging Face/Xet redirect
  hosts. The `.part` file is size-checked and hashed before atomic promotion.

`NEXUS_CHESS_MODEL_PATH` may name the verified model file or a directory that
contains it. A configured local file is never accepted on name alone.

All routes use `POST` and JSON:

- `/health`
- `/v1/chat`
- `/v1/chess/turn`
- `/v1/chess/analyze`
- `/v1/history`
- `/v1/games`
- `/v1/preferences`

Opponent turns use a strict coordinate envelope. The entire model response must
be `[action]`, one reducer-supplied UCI coordinate, and `[/action]` on separate
lines. JSON, prose, multiple coordinates, malformed envelopes, illegal
coordinates, and detected repetition cycles are rejected. Godot retries a
bounded number of times and can recover only by selecting from the reducer's
already-probed allowlist.

The sidecar also owns `nexus_chess_local.sqlite3` in the application-support
directory. Model verification state, chat messages, and reducer move receipts
are stored as authenticated encrypted payloads with strict field allowlists,
bounded text, parameterized SQL, opaque record identifiers, and a bounded
retention window. The model file is hashed on first verification and the
stored identity is reused only while its path, exact size, and modification
identity still match; a changed or missing identity is re-verified or rejected.
Named snapshots and the rolling active-game snapshot use the same store and
validate the reducer state/history shape before they are saved.

When past-game memory is enabled, each move also stores a sanitized
32-dimensional position vector, profile identifiers, the CPU-simulated RGB
gate state, and the final game reward. Recall decrypts a bounded candidate set
in memory, ranks it by cosine similarity, and supplies only the highest-ranked
records as advisory prompt context. Preferences for memory, the seven-color
skill spectrum, the player's White/Black choice, and the 24 playing-style
profiles are stored in the same protected database. The RGB gate is a
deterministic three-qubit mathematical
simulation on the CPU; it reports measurement entropy and entropy gain but is
not quantum hardware and never overrides Chess Core legality.

The default endpoint is `http://127.0.0.1:47621`. The Godot Settings page can
start, stop, restart, and test the owned process without manually launching
Flutter.

Never persist or display the bearer token. Godot should create it for the child
process, keep it in memory, and send `Authorization: Bearer <token>` over the
loopback connection.

## Checks

```bash
flutter analyze
flutter test test/backend_contract_test.dart
flutter test test/local_store_test.dart
```
