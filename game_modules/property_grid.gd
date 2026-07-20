extends "res://game_modules/deterministic_game_module.gd"

const MIN_PLAYERS := 2
const MAX_PLAYERS := 6
const DEFAULT_BALANCE := 1000
const PASS_REWARD := 200


func manifest() -> Dictionary:
	return {
		"id": "property_grid",
		"title": "Property Grid",
		"version": "1.0.0",
		"players": {"min": MIN_PLAYERS, "max": MAX_PLAYERS},
		"deterministic": true,
		"board": {"kind": "loop", "spaces": 16},
		"actions": {
			"roll": {"required": ["actor"]},
			"buy": {"required": ["actor"]},
			"pass": {"required": ["actor"]},
			"end_turn": {"required": ["actor"]},
		},
		"randomness": {
			"kind": "seeded_replay_prng",
			"note": "Use a lobby-agreed randomness beacon to choose the initial seed in production.",
		},
		"rules": {
			"variant": "generic_property_loop_v1",
			"auctions": false,
			"trading": false,
		},
		"rendering": {
			"asset_policy": "procedural_native",
			"space_kinds": ["start", "property", "tax", "grant", "rest"],
		},
	}


func _initial_state(config: Dictionary) -> Dictionary:
	var requested: Array = config.get("players", ["p1", "p2"])
	var ids: Array = []
	for player_variant in requested:
		var player_id := str(player_variant).strip_edges()
		if player_id != "" and player_id not in ids and ids.size() < MAX_PLAYERS:
			ids.append(player_id)
	if ids.size() < MIN_PLAYERS:
		ids = ["p1", "p2"]
	var starting_balance := maxi(1, int(config.get("starting_balance", DEFAULT_BALANCE)))
	var players: Array = []
	for player_id in ids:
		players.append({
			"id": player_id,
			"position": 0,
			"balance": starting_balance,
			"bankrupt": false,
		})
	var seed := int(config.get("seed", 73939133)) & 0x7fffffff
	if seed == 0:
		seed = 1
	return {
		"module_id": "property_grid",
		"revision": 0,
		"players": players,
		"turn_index": 0,
		"phase": "await_roll",
		"board": _default_board(),
		"properties": {},
		"rng_state": seed,
		"pass_reward": maxi(0, int(config.get("pass_reward", PASS_REWARD))),
		"round": 1,
		"last_roll": [],
		"last_event": {"type": "initialized"},
		"status": "active",
		"winner": "",
		"move_count": 0,
	}


func validate_action(state: Dictionary, action: Dictionary) -> Dictionary:
	if str(state.get("status", "")) != "active":
		return _invalid("game_complete", "No actions are accepted after the game completes.")
	if not action.has("actor"):
		return _invalid("actor_required", "A signed actor id is required.")
	var active_player: Dictionary = state.players[int(state.turn_index)]
	if str(action.actor) != str(active_player.id):
		return _invalid("out_of_turn", "Only the active player can act.")
	var action_type := str(action.get("type", ""))
	var phase := str(state.phase)
	match action_type:
		"roll":
			if phase != "await_roll":
				return _invalid("phase", "A roll is not available in the current phase.")
		"buy":
			if phase != "await_purchase":
				return _invalid("phase", "There is no property awaiting purchase.")
			var space: Dictionary = state.board[int(active_player.position)]
			if str(space.kind) != "property" or state.properties.has(str(active_player.position)):
				return _invalid("property_unavailable", "The landed property is no longer available.")
			if int(active_player.balance) < int(space.price):
				return _invalid("insufficient_funds", "Player cannot afford this property.")
		"pass":
			if phase != "await_purchase":
				return _invalid("phase", "Purchase can be passed only when one is pending.")
		"end_turn":
			if phase != "await_end":
				return _invalid("phase", "Resolve the current landing before ending the turn.")
		_:
			return _invalid("action_type", "Unknown Property Grid action.")
	return _valid()


func _reduce_validated(state: Dictionary, action: Dictionary) -> Dictionary:
	var action_type := str(action.type)
	var active_index := int(state.turn_index)
	match action_type:
		"roll":
			_apply_roll(state, active_index)
		"buy":
			var player: Dictionary = state.players[active_index]
			var position := int(player.position)
			var space: Dictionary = state.board[position]
			player.balance = int(player.balance) - int(space.price)
			state.players[active_index] = player
			state.properties[str(position)] = str(player.id)
			state.phase = "await_end"
			state.last_event = {
				"type": "property_bought",
				"actor": str(player.id),
				"space": position,
				"amount": int(space.price),
			}
		"pass":
			state.phase = "await_end"
			state.last_event = {
				"type": "purchase_passed",
				"actor": str(action.actor),
				"space": int(state.players[active_index].position),
			}
		"end_turn":
			_advance_turn(state)
	state.move_count = int(state.move_count) + 1
	return state


func _apply_roll(state: Dictionary, player_index: int) -> void:
	var first_state := _next_rng(int(state.rng_state))
	var second_state := _next_rng(first_state)
	var first_die := first_state % 6 + 1
	var second_die := second_state % 6 + 1
	state.rng_state = second_state
	state.last_roll = [first_die, second_die]

	var player: Dictionary = state.players[player_index]
	var old_position := int(player.position)
	var distance := first_die + second_die
	var board_size: int = state.board.size()
	var raw_position := old_position + distance
	var completed_loops: int = raw_position / board_size
	player.position = raw_position % board_size
	if completed_loops > 0:
		player.balance = int(player.balance) + completed_loops * int(state.pass_reward)
	state.players[player_index] = player
	_resolve_landing(state, player_index)


func _resolve_landing(state: Dictionary, player_index: int) -> void:
	var player: Dictionary = state.players[player_index]
	var position := int(player.position)
	var space: Dictionary = state.board[position]
	match str(space.kind):
		"property":
			var owner := str(state.properties.get(str(position), ""))
			if owner == "":
				state.phase = "await_purchase" if int(player.balance) >= int(space.price) else "await_end"
				state.last_event = {
					"type": "property_available",
					"actor": str(player.id),
					"space": position,
					"price": int(space.price),
				}
			elif owner == str(player.id):
				state.phase = "await_end"
				state.last_event = {"type": "owner_landed", "actor": str(player.id), "space": position}
			else:
				var payment := mini(int(player.balance), int(space.rent))
				player.balance = int(player.balance) - payment
				state.players[player_index] = player
				var owner_index := _player_index(state.players, owner)
				if owner_index >= 0:
					var owner_player: Dictionary = state.players[owner_index]
					owner_player.balance = int(owner_player.balance) + payment
					state.players[owner_index] = owner_player
				state.last_event = {
					"type": "rent_paid",
					"actor": str(player.id),
					"owner": owner,
					"space": position,
					"amount": payment,
				}
				if payment < int(space.rent):
					_bankrupt_player(state, player_index)
				else:
					state.phase = "await_end"
		"tax":
			var charge := int(space.amount)
			var payment := mini(int(player.balance), charge)
			player.balance = int(player.balance) - payment
			state.players[player_index] = player
			state.last_event = {"type": "tax_paid", "actor": str(player.id), "amount": payment}
			if payment < charge:
				_bankrupt_player(state, player_index)
			else:
				state.phase = "await_end"
		"grant":
			player.balance = int(player.balance) + int(space.amount)
			state.players[player_index] = player
			state.phase = "await_end"
			state.last_event = {"type": "grant_received", "actor": str(player.id), "amount": int(space.amount)}
		_:
			state.phase = "await_end"
			state.last_event = {"type": "rested", "actor": str(player.id), "space": position}


func _bankrupt_player(state: Dictionary, player_index: int) -> void:
	var player: Dictionary = state.players[player_index]
	player.balance = 0
	player.bankrupt = true
	state.players[player_index] = player
	for property_key in state.properties.keys():
		if str(state.properties[property_key]) == str(player.id):
			state.properties.erase(property_key)
	var solvent := _solvent_players(state.players)
	if solvent.size() == 1:
		state.status = "won"
		state.winner = str(solvent[0])
		state.phase = "complete"
		state.last_event = {"type": "game_won", "winner": str(solvent[0])}
	else:
		state.phase = "await_end"


func _advance_turn(state: Dictionary) -> void:
	var previous := int(state.turn_index)
	var candidate := previous
	for _offset in range(state.players.size()):
		candidate = (candidate + 1) % state.players.size()
		if not bool(state.players[candidate].bankrupt):
			break
	state.turn_index = candidate
	if candidate <= previous:
		state.round = int(state.round) + 1
	state.phase = "await_roll"
	state.last_roll = []
	state.last_event = {"type": "turn_started", "actor": str(state.players[candidate].id)}


func _next_rng(value: int) -> int:
	return int((value * 1103515245 + 12345) & 0x7fffffff)


func _player_index(players: Array, player_id: String) -> int:
	for index in range(players.size()):
		if str(players[index].id) == player_id:
			return index
	return -1


func _solvent_players(players: Array) -> Array:
	var result: Array = []
	for player in players:
		if not bool(player.bankrupt):
			result.append(str(player.id))
	return result


func _default_board() -> Array:
	return [
		{"name": "Origin Gate", "kind": "start"},
		{"name": "Cyan Field", "kind": "property", "price": 100, "rent": 18},
		{"name": "Relay Grant", "kind": "grant", "amount": 70},
		{"name": "Ember Field", "kind": "property", "price": 120, "rent": 22},
		{"name": "Transit Levy", "kind": "tax", "amount": 60},
		{"name": "Violet Reach", "kind": "property", "price": 150, "rent": 28},
		{"name": "Quiet Node", "kind": "rest"},
		{"name": "Glass Reach", "kind": "property", "price": 170, "rent": 34},
		{"name": "Signal Grant", "kind": "grant", "amount": 90},
		{"name": "Aurora Reach", "kind": "property", "price": 200, "rent": 40},
		{"name": "Archive Levy", "kind": "tax", "amount": 90},
		{"name": "Mycelium Reach", "kind": "property", "price": 220, "rent": 46},
		{"name": "Commons Node", "kind": "rest"},
		{"name": "Obsidian Reach", "kind": "property", "price": 250, "rent": 54},
		{"name": "Forge Grant", "kind": "grant", "amount": 110},
		{"name": "Prism Reach", "kind": "property", "price": 280, "rent": 62},
	]
