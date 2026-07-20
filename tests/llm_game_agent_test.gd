extends SceneTree

const Agent = preload("res://systems/llm_game_agent.gd")
const ChessCore = preload("res://game_modules/chess_core.gd")


func _initialize() -> void:
	var chess := ChessCore.new()
	var state: Dictionary = chess.initial_state({"players": {"white": "vexel", "black": "player"}})
	var legal := [
		{"type": "move", "actor": "vexel", "from": 52, "to": 36},
		{"type": "move", "actor": "vexel", "from": 52, "to": 44},
		{"type": "move", "actor": "vexel", "from": 62, "to": 45},
	]
	state["legal_actions"] = legal

	var prompt := Agent.build_opponent_prompt(
		state,
		legal,
		[{"ply": 1, "uci": "e2e4", "algebraic": "e2-e4"}],
		{"style": "patient positional rival"}
	)
	assert("schema=nexus.chess-agent/3" in prompt)
	assert("[legalmoves]" in prompt and "e2e4" in prompt)
	assert("[pastmovecontext]" in prompt and "[boardstate]" in prompt)
	assert("[rgb_quantum_gate]" in prompt and "quantum_state=" in prompt)
	assert("[action]" in prompt and "[/action]" in prompt)
	assert(prompt.length() <= Agent.MAX_PROMPT_CHARS)

	var valid := Agent.parse_response(
		"[action]\ne2e4\n[/action]",
		legal,
		"opponent"
	)
	assert(valid.ok and valid.uci == "e2e4")
	assert(valid.action is Dictionary and int(valid.action.from) == 52 and int(valid.action.to) == 36)
	assert(valid.message.is_empty())

	var illegal := Agent.parse_response("[action]\ne2e5\n[/action]", legal, "opponent")
	assert(not illegal.ok and illegal.code == "illegal_agent_move")
	var prose := Agent.parse_response("I choose g1f3 because it develops.", legal, "opponent")
	assert(not prose.ok and prose.code == "action_envelope_required")
	var json := Agent.parse_response("{\"move\":\"e2e4\"}", legal, "opponent")
	assert(not json.ok and json.code == "action_envelope_required")
	var ambiguous := Agent.parse_response("[action]\ne2e4 e2e3\n[/action]", legal, "opponent")
	assert(not ambiguous.ok and ambiguous.code == "action_envelope_required")

	var tutor := Agent.parse_response("{\"move\":\"\",\"message\":\"Look for checks first.\"}", legal, "tutor")
	assert(tutor.ok and tutor.code == "message_only" and tutor.action.is_empty())
	var chat_prompt := Agent.build_chat_prompt(state, legal, [], "Why is the center important?")
	assert("mode=chat" in chat_prompt and "Why is the center important?" in chat_prompt)
	var tutor_prompt := Agent.build_tutor_prompt(state, legal, [], "Give me a hint")
	assert("mode=tutor" in tutor_prompt)
	var style_prompt := Agent.build_style_prompt(state, legal, [], "Help me play actively")
	assert("mode=style" in style_prompt)

	var compatible := Agent.parse_action("[action]\ne2e3\n[/action]", state)
	assert(compatible.ok and compatible.action is Dictionary and int(compatible.action.to) == 44)
	var no_fallback := Agent.fallback_action("chess_core", state)
	assert(not no_fallback.ok and no_fallback.code == "model_required")
	var vector := Agent.position_vector(state, [])
	assert(vector.size() == Agent.POSITION_VECTOR_DIMENSIONS)
	var entropy := Agent.rgb_quantum_state(vector, "yellow", "tal")
	assert(float(entropy.quantum_state) >= 0.0 and float(entropy.quantum_state) <= 1.0)
	assert(Array(entropy.measurement_probabilities).size() == 8)
	assert(Agent.skill_profiles().size() == 7)
	assert(Agent.style_profiles().size() >= 24)
	assert(Agent.normalized_preferences({"player_side": "black"}).player_side == "black")
	assert(Agent.normalized_preferences({"player_side": "invalid"}).player_side == "white")
	var cycle := Agent.repetition_cycle_moves([
		{"actor": "CAISSA", "uci": "a8b8"},
		{"actor": "YOU", "uci": "a2a3"},
		{"actor": "CAISSA", "uci": "b8a8"},
	])
	assert("a8b8" in cycle)

	print("LLM_GAME_AGENT_TEST: PASS")
	quit(0)
