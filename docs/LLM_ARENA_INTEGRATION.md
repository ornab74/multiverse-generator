# Local chess-agent integration

## Runtime flow

```text
Godot starts
  -> owns one bundled Flutter Linux process
  -> polls authenticated POST /health on 127.0.0.1:47621
  -> passes the reducer's legal Chess Core actions to Gemma
  -> resolves one exact UCI move back to an allowlisted action
  -> reducer validates and commits the move
  -> queues sanitized chat and reducer receipts into the local history store
```

The current user surface is intentionally only single-player Chess Core. The
retired world-generation, asset-forge, and multi-game tabs are not mounted in
the shell.

## Godot side

- [`ui/llm_arena_panel.gd`](../ui/llm_arena_panel.gd) owns the board, chat,
  move log, and agent turn flow.
- [`systems/llm_game_agent.gd`](../systems/llm_game_agent.gd) creates bounded
  prompts and rejects moves that are not exact entries in the legal allowlist.
- [`systems/naza_dart_gemma_bridge.gd`](../systems/naza_dart_gemma_bridge.gd)
  starts/stops the owned sidecar and performs authenticated loopback requests.
- [`game_modules/chess_core.gd`](../game_modules/chess_core.gd) remains the
  sole authority for movement, check, castling, en passant, promotion, and
  game completion.

## Flutter sidecar

The backend binds to `127.0.0.1` on `NEXUS_CHESS_LLM_PORT`, defaulting to
`47621`. Godot supplies a fresh `NEXUS_CHESS_LLM_TOKEN` and the verified model
path to the child process. The sidecar exposes:

- `POST /health`
- `POST /v1/chat`
- `POST /v1/chess/turn`
- `POST /v1/chess/analyze`
- `POST /v1/history`
- `POST /v1/games`

Every request requires the bearer token. Gemma is forced to the CPU backend;
the Flutter window renderer is separate from inference policy.

`/v1/history` accepts only three bounded operations: append a conversation
entry, append a reducer move receipt, or read a bounded recent session. The
sidecar validates the allowlisted fields before using bound SQLite parameters.
SQLite stores opaque record identifiers and encrypted payloads; plaintext chat,
paths, session ids, and move details are not written to the database file.
The model identity is recorded after its first successful verification and is
reused only while the same exact file identity remains present.

The front end keeps one arena instance alive while switching between Play,
Saved Games, and Settings. Reducer snapshots are automatically written to the
active-game slot, while the Saved Games page writes named snapshots. Loading a
named snapshot replays every stored UCI move through Chess Core and refuses the
load if the resulting state hash does not match the stored state.

## Settings and troubleshooting

Open Settings to see the exact endpoint, owned PID, startup phase, progress,
model source, and last error. `TEST /HEALTH` performs the same authenticated
health check used by the bridge. If the process is stopped, use `START
BACKEND`; if it is stuck during initialization, use `RESTART`.

The default model is:

```text
res://chess_llm_backend/models/gemma-4-E2B-it.litertlm
```

The bundled release executable is:

```text
res://chess_llm_backend/build/linux/x64/release/bundle/nexus_chess_llm
```

For a safe UI boot check without model startup, set
`NEXUS_BACKEND_AUTOSTART=0` before launching Godot.
