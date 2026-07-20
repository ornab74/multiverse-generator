# Nexus / Chess Agent

Nexus is a Godot single-player chess client with a private local Gemma agent.
Godot owns the board and the rules reducer. The model can chat about the
position and select a move only from the reducer's current legal-move list.

## Run

Open the project in Godot 4.6+ or run:

```bash
godot --path .
```

Godot starts the bundled Flutter desktop sidecar automatically. The local
backend listens on:

```text
http://127.0.0.1:47621
```

When no model is installed, first launch downloads the pinned 2.5 GB Gemma
model into the operating system's application-support directory. The download
is streamed through exact-size and SHA-256 checks before atomic installation.
An unchanged installed file reuses its remembered verification instead of
being hashed on every boot. Godot shows a spinning chess-piece startup screen
with live progress, then opens Play only after the backend is ready.

Use Settings to choose White or Black for the next game, edit the port or an
optional model path, test `POST /health`, start/stop/restart the backend, or run
the automatic install/repair flow again.

For a parser-only boot check without starting the model:

```bash
NEXUS_BACKEND_AUTOSTART=0 godot --headless --path . --quit-after 2
```

## Controls

- Click one of your pieces, then a highlighted square, to make a legal move.
- Choosing Black in Settings rotates the board and lets Caissa move first.
- Use the chat box to ask about the current position or a previous move.
- `NEW GAME` resets the deterministic Chess Core state.
- `Saved Games` at the lower left opens named local save slots.

## Backend contract

The sidecar is in [`chess_llm_backend`](chess_llm_backend/README.md). It binds
only to loopback, requires a process-scoped bearer token, exposes `/health`,
`/v1/chat`, `/v1/chess/turn`, `/v1/chess/analyze`, `/v1/history`, and
`/v1/games`, and rejects non-CPU inference. Local model verification state,
chat, reducer move receipts, and named saved games are retained in the
protected local history store. The bridge never discovers or kills an
unrelated process by port.

## Checks

```bash
godot --headless --path . --editor --quit
godot --headless --path . --script res://tests/llm_arena_gate_test.gd
godot --headless --path . --script res://tests/chess_boot_loading_test.gd
godot --headless --path . --script res://tests/llm_game_agent_test.gd
godot --headless --path . --script res://tests/naza_dart_gemma_bridge_test.gd
godot --headless --path . --script res://tests/chess_board_presenter_test.gd
godot --headless --path . --script res://tests/chess_history_test.gd
```

## Release builds

`.github/workflows/nexus-chess-release.yml` validates source boundaries and
builds Linux, Windows, macOS, Android, and unsigned iOS artifacts. Desktop
archives combine the Godot game with the matching Flutter backend under the
layout expected by the launcher. Models, runtime databases, key material,
partial downloads, and files over the repository size limit are rejected from
source and export artifacts.

Android and iOS jobs currently publish the responsive Godot shell and Flutter
model host as separate platform artifacts. Desktop can launch a sidecar
process; mobile app sandboxes require a native embedded host/plugin before
those two artifacts can be shipped as one production app.
