# Asset manifest

The active Nexus surface uses native Godot controls and procedural chess
pieces. No generated world plates, board-game art, asset-forge previews, or
third-party packs are mounted by the product shell.

The authoritative visual/game boundary is:

- `ui/llm_arena_panel.gd` draws the chess board and pieces as accessible native
  controls;
- `game_modules/chess_core.gd` owns all legal movement and state;
- `systems/llm_game_agent.gd` owns the bounded model response boundary;
- `systems/naza_dart_gemma_bridge.gd` owns the local backend transport.

Legacy concept images and generated game plates were removed from the active
project assets. The repository now keeps only this manifest and the native
runtime path above.
