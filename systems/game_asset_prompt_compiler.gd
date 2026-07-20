extends RefCounted
class_name GameAssetPromptCompiler

## Deterministic, fail-closed creative brief compiler for community-authored assets.
##
## This component only prepares JSON-safe drafts. It never invokes a model,
## opens a URL, pins to IPFS, signs a transaction, or treats stake as consent.

const SCHEMA_VERSION := 1
const COMPILER_VERSION := "1.0.0"
const DOMAIN_SEPARATOR := "NEXUS_GAME_ASSET_PROMPT_V1"
const GODOT_VERSION_CONTRACT := "4.7"

const MAX_REQUEST_BYTES := 16_384
const MAX_DEPTH := 4
const MAX_MAP_KEYS := 32
const MAX_LIST_ITEMS := 16
const MAX_COMPILED_NEGATIVE_ITEMS := 32
const MAX_FIELD_CHARS := 512
const MAX_CREATIVE_BRIEF_CHARS := 6_000
const MAX_CREATIVE_BRIEF_LINES := 64
const MAX_PROMPT_CHARS := 14_000
const MAX_NEGATIVE_PROMPT_CHARS := 2_048

const GAME_ALIASES := {
	"chess": "chess_core",
	"chess core": "chess_core",
	"chess_core": "chess_core",
	"connect 4": "four_line",
	"connect four": "four_line",
	"connect4": "four_line",
	"four in a row": "four_line",
	"four line": "four_line",
	"four_line": "four_line",
	"checkers": "draughts",
	"draughts": "draughts",
	"monopoly": "property_grid",
	"property grid": "property_grid",
	"property trading": "property_grid",
	"property_grid": "property_grid",
	"generic": "generic_world",
	"generic world": "generic_world",
	"generic_world": "generic_world",
	"world": "generic_world",
}

const MODALITY_ALIASES := {
	"audio": "audio",
	"bark": "audio",
	"bark audio": "audio",
	"music": "audio",
	"sound": "audio",
	"image": "image",
	"illustration": "image",
	"voice to text": "voice_to_text",
	"voice-to-text": "voice_to_text",
	"speech to text": "voice_to_text",
	"stt": "voice_to_text",
	"transcription": "voice_to_text",
	"hud": "ui_kit",
	"ui": "ui_kit",
	"ui kit": "ui_kit",
	"ui_kit": "ui_kit",
	"board": "board_texture",
	"board texture": "board_texture",
	"board_texture": "board_texture",
	"piece sheet": "piece_sheet",
	"pieces": "piece_sheet",
	"sprite sheet": "piece_sheet",
	"token sheet": "piece_sheet",
	"piece_sheet": "piece_sheet",
	"concept art": "world_concept",
	"environment": "world_concept",
	"world concept": "world_concept",
	"world_concept": "world_concept",
}

const TOP_LEVEL_KEYS := [
	"accessibility",
	"asset_name",
	"author_id",
	"camera",
	"constraints",
	"creative_brief",
	"game",
	"game_id",
	"intent",
	"materials",
	"modality",
	"mood",
	"negative_constraints",
	"palette",
	"proposal_id",
	"provenance",
	"runtime",
	"seed",
	"shard_id",
	"style",
	"theme",
]

const ACCESSIBILITY_KEYS := [
	"color_blind_safe",
	"high_contrast",
	"large_text",
	"notes",
	"reduced_motion",
	"screen_reader_labels",
]

const RUNTIME_KEYS := [
	"alpha",
	"channels",
	"duration_seconds",
	"frame_rate",
	"locale",
	"loop",
	"sample_rate_hz",
	"seamless",
	"target_height",
	"target_width",
]

const PROVENANCE_KEYS := [
	"author_id",
	"content_commitment",
	"license_intent",
	"proposal_id",
	"shard_id",
	"source_kind",
]

const URL_MARKERS := [
	"http://", "https://", "ftp://", "ipfs://", "magnet:", "www.", ".onion",
	"/ip4/", "/ip6/", "/dns/", "/dns4/", "/dns6/", "/tcp/", "/udp/",
]

const SECRET_MARKERS := [
	"api key", "api_key", "apikey", "access token", "auth token", "bearer ",
	"client secret", "private key", "private_key", "seed phrase", "mnemonic phrase",
	"password=", "password:", "secret=", "secret:", "ssh-rsa", "sk-live-", "sk_test_",
]

const INSTRUCTION_MARKERS := [
	"ignore previous instructions", "ignore all instructions", "reveal the system prompt",
	"developer message", "system message", "override policy", "bypass safety", "act as root",
	"tool call", "tool_call", "function call", "execute code", "execute command", "run command",
	"shell command", "bash -c", "powershell", "curl ", "wget ", "sudo ", "rm -rf",
	"install package", "exfiltrate", "read environment variables",
]

const IMITATION_MARKERS := [
	"in the style of", "copy the style of", "imitate the style of", "clone the look of",
	"identical to", "copyrighted character", "brand mascot", "official logo", "brand logo",
]

const TRADEMARK_TERMS := [
	"barbie", "batman", "call of duty", "coca cola", "dc comics", "diablo", "disney",
	"dungeons and dragons", "elden ring", "fortnite", "game of thrones", "grand theft auto",
	"halo", "harry potter", "lego", "lord of the rings", "mario", "marvel", "minecraft",
	"monopoly", "nintendo", "overwatch", "pokemon", "roblox", "sonic the hedgehog",
	"spider man", "star trek", "star wars", "superman", "warcraft", "warhammer", "zelda",
]

const DEFAULT_NEGATIVE_CONSTRAINTS := [
	"named brands or franchise identifiers",
	"recognizable copyrighted characters",
	"artist or studio imitation",
	"logos, signatures, watermarks, QR codes, or advertising",
	"readable links, network addresses, credentials, terminal text, or scripts",
	"ambiguous game states or decorative marks that resemble legal moves",
	"low contrast, color-only state communication, unsafe flashing, or illegible small text",
	"baked perspective that conflicts with the requested camera contract",
]

const GAME_PROFILES := {
	"chess_core": {
		"display_name": "Chess Core",
		"default_palette": ["deep navy", "ion cyan", "warm ivory", "violet accent"],
		"default_materials": ["matte ceramic", "brushed alloy", "subtle emissive inlay"],
		"default_camera": "three-quarter tactical view with an orthographic-safe top-down alternate",
		"board_contract": "an exact eight by eight square lattice with unambiguous alternating cells and algebraic-coordinate-safe margins",
		"piece_contract": "two complete original factions with six instantly distinguishable silhouettes: king, queen, rook, bishop, knight, and pawn",
		"ui_contract": "turn, clock, captured material, legal move, preview, commit, cancel, draw, check, and terminal-state surfaces",
		"interaction_contract": "selection, legal targets, captures, castling, en passant, promotion, check, checkmate, draw, preview, and rollback must remain visually distinct",
	},
	"four_line": {
		"display_name": "Four Line",
		"default_palette": ["midnight blue", "electric cyan", "signal violet", "soft graphite"],
		"default_materials": ["translucent polymer", "powder-coated alloy", "soft emissive rings"],
		"default_camera": "front-biased three-quarter view with all seven columns readable",
		"board_contract": "an exact seven-column by six-row vertical lattice with open, readable drop lanes",
		"piece_contract": "two original token families with shape, value, and luminance differences in addition to color",
		"ui_contract": "active player, column hover, legal drop, landing preview, commit, undo proposal, win trace, and draw surfaces",
		"interaction_contract": "every column target, lowest open landing cell, four-token win line, full column, preview, and rollback must be immediately legible",
	},
	"draughts": {
		"display_name": "Draughts",
		"default_palette": ["obsidian", "pale stone", "ember red", "aqua signal"],
		"default_materials": ["carved stone", "anodized alloy", "woven edge trim"],
		"default_camera": "stable three-quarter tactical view with a distortion-free top-down alternate",
		"board_contract": "an exact eight by eight square lattice with playable dark cells and coordinate-safe borders",
		"piece_contract": "two original token families with unmistakable single-piece and crowned-piece silhouettes",
		"ui_contract": "turn, selectable piece, forced capture, multi-jump path, crown state, preview, commit, cancel, win, and draw surfaces",
		"interaction_contract": "diagonal movement, forced capture, chained capture, crowning, selected source, legal path, preview, and rollback must remain distinct",
	},
	"property_grid": {
		"display_name": "Property Grid",
		"default_palette": ["space black", "teal ledger", "amber credit", "orchid district", "ivory type"],
		"default_materials": ["recycled paper composite", "etched alloy", "holographic foil accents"],
		"default_camera": "clean isometric tabletop view with a readable perimeter and central dashboard",
		"board_contract": "an original sixteen-space perimeter economy board with clear corners, property groups, event spaces, and a reserved central information field",
		"piece_contract": "up to six original player pawns plus ownership markers, currency symbols, event tokens, and upgrade markers",
		"ui_contract": "turn order, balances, ownership, rent, trade offer, roll, buy, pass, end turn, proposal review, commit, and rollback surfaces",
		"interaction_contract": "movement, landing resolution, affordability, ownership, rent, trade terms, voting state, preview, and rollback must be readable without relying on color alone",
	},
	"generic_world": {
		"display_name": "Original World",
		"default_palette": ["deep space", "cool cyan", "living violet", "mineral amber"],
		"default_materials": ["weathered stone", "reclaimed alloy", "bioluminescent glass"],
		"default_camera": "layered wide establishing view with gameplay-scale foreground references",
		"board_contract": "a modular world lattice with readable traversal, social, resource, hazard, and sanctuary zones",
		"piece_contract": "original inhabitants, landmarks, resources, tools, and environmental storytelling families with a coherent shape language",
		"ui_contract": "navigation, objective, party, shard state, proposal, vote, safety review, generation budget, and rollback surfaces",
		"interaction_contract": "interactive, decorative, hazardous, collaborative, private, and public states must be separable at a glance",
	},
}

var _ipv4_regex := RegEx.new()
var _ipv6_regex := RegEx.new()


func _init() -> void:
	_ipv4_regex.compile("(^|[^0-9])([0-9]{1,3}\\.){3}[0-9]{1,3}([^0-9]|$)")
	_ipv6_regex.compile("(^|[^0-9a-f])([0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}([^0-9a-f]|$)")


func compile(raw_spec: Dictionary) -> Dictionary:
	var serialized := JSON.stringify(raw_spec)
	if serialized.to_utf8_buffer().size() > MAX_REQUEST_BYTES:
		return _failure("request_too_large", "$", "Request exceeds the bounded compiler envelope.")

	var shape_check := _validate_json_shape(raw_spec, 0, "$")
	if not shape_check.ok:
		return shape_check
	for raw_key in raw_spec.keys():
		if str(raw_key) not in TOP_LEVEL_KEYS:
			return _failure("unknown_field", "$." + str(raw_key), "Unknown compiler field.")

	var game_result := _resolve_game(raw_spec)
	if not game_result.ok:
		return game_result
	var modality_id := normalize_modality(str(raw_spec.get("modality", "image")))
	if modality_id.is_empty():
		return _failure("unsupported_modality", "$.modality", "Unsupported asset modality.")

	var normalized_result := _normalize_spec(raw_spec, str(game_result.game_id), modality_id)
	if not normalized_result.ok:
		return normalized_result
	var normalized: Dictionary = normalized_result.value
	var request_hash := hash_value(normalized)
	var profile: Dictionary = GAME_PROFILES[normalized.game_id]
	var runtime_metadata := _build_runtime_metadata(normalized, profile)
	var prompt_sections := _build_prompt_sections(normalized, profile, runtime_metadata)
	var prompt := "\n\n".join(PackedStringArray(prompt_sections))
	var negative_prompt := "; ".join(PackedStringArray(normalized.negative_constraints)) + "."
	if prompt.length() > MAX_PROMPT_CHARS:
		return _failure("compiled_prompt_too_long", "$.prompt", "Compiled prompt exceeds the fixed output limit.")
	if negative_prompt.length() > MAX_NEGATIVE_PROMPT_CHARS:
		return _failure("compiled_negative_prompt_too_long", "$.negative_constraints", "Compiled negative prompt exceeds the fixed output limit.")

	var prompt_hash := hash_value({"negative_prompt": negative_prompt, "prompt": prompt})
	var asset_id := "nexus-asset-" + hash_value({
		"domain": DOMAIN_SEPARATOR,
		"prompt_hash": prompt_hash,
		"request_hash": request_hash,
	}).left(24)
	var generation_spec := _build_generation_spec(normalized, profile, runtime_metadata, prompt, negative_prompt)
	var content_manifest := _build_content_manifest(asset_id, normalized, runtime_metadata)
	var provenance_manifest := _build_provenance_manifest(asset_id, normalized, request_hash, prompt_hash)
	var manifest_hash := hash_value({
		"content_manifest": content_manifest,
		"provenance_manifest": provenance_manifest,
	})
	var bundle := {
		"asset_id": asset_id,
		"code": "compiled",
		"compiler": {
			"domain": DOMAIN_SEPARATOR,
			"schema_version": SCHEMA_VERSION,
			"version": COMPILER_VERSION,
		},
		"content_manifest": content_manifest,
		"generation_spec": generation_spec,
		"manifest_hash": manifest_hash,
		"negative_prompt": negative_prompt,
		"normalized_request": normalized,
		"ok": true,
		"prompt": prompt,
		"prompt_hash": prompt_hash,
		"prompt_sections": prompt_sections,
		"provenance_manifest": provenance_manifest,
		"request_hash": request_hash,
		"runtime_metadata": runtime_metadata,
	}
	bundle["bundle_hash"] = hash_value(bundle)
	return bundle


func compile_asset_prompt(raw_spec: Dictionary) -> Dictionary:
	return compile(raw_spec)


func normalize_game_id(raw_value: String) -> String:
	var alias := _normalize_alias(raw_value)
	return str(GAME_ALIASES.get(alias, ""))


func normalize_modality(raw_value: String) -> String:
	var alias := _normalize_alias(raw_value)
	return str(MODALITY_ALIASES.get(alias, ""))


func supported_games() -> PackedStringArray:
	return PackedStringArray(["chess_core", "four_line", "draughts", "property_grid", "generic_world"])


func supported_modalities() -> PackedStringArray:
	return PackedStringArray(["image", "audio", "voice_to_text", "ui_kit", "board_texture", "piece_sheet", "world_concept"])


func _resolve_game(raw_spec: Dictionary) -> Dictionary:
	var game_from_id := ""
	var game_from_alias := ""
	if raw_spec.has("game_id"):
		game_from_id = normalize_game_id(str(raw_spec.game_id))
		if game_from_id.is_empty():
			return _failure("unsupported_game", "$.game_id", "Unsupported game family.")
	if raw_spec.has("game"):
		game_from_alias = normalize_game_id(str(raw_spec.game))
		if game_from_alias.is_empty():
			return _failure("unsupported_game", "$.game", "Unsupported game family.")
	if not game_from_id.is_empty() and not game_from_alias.is_empty() and game_from_id != game_from_alias:
		return _failure("ambiguous_game", "$.game", "Game aliases resolve to different modules.")
	var resolved := game_from_id if not game_from_id.is_empty() else game_from_alias
	if resolved.is_empty():
		resolved = "generic_world"
	return {"game_id": resolved, "ok": true}


func _normalize_spec(raw: Dictionary, game_id: String, modality_id: String) -> Dictionary:
	var profile: Dictionary = GAME_PROFILES[game_id]
	var fields := {
		"asset_name": [raw.get("asset_name", profile.display_name + " community asset"), "$.asset_name", 120],
		"intent": [raw.get("intent", "create a reviewable original asset draft"), "$.intent", 240],
		"theme": [raw.get("theme", "community-forged interstellar workshop"), "$.theme", 240],
		"style": [raw.get("style", "clean original science-fiction tabletop design"), "$.style", 240],
		"mood": [raw.get("mood", "focused, collaborative, optimistic, and mysterious"), "$.mood", 180],
	}
	var normalized_fields: Dictionary = {}
	for key in fields.keys():
		var descriptor: Array = fields[key]
		if not descriptor[0] is String:
			return _failure("field_type", str(descriptor[1]), "Expected a string.")
		var clean := _sanitize_text(str(descriptor[0]), str(descriptor[1]), int(descriptor[2]))
		if not clean.ok:
			return clean
		normalized_fields[key] = clean.value

	var palette := _normalize_string_list(raw.get("palette", profile.default_palette), "$.palette", profile.default_palette, 96)
	if not palette.ok:
		return palette
	var materials := _normalize_string_list(raw.get("materials", profile.default_materials), "$.materials", profile.default_materials, 120)
	if not materials.ok:
		return materials
	var constraints := _normalize_string_list(raw.get("constraints", []), "$.constraints", [], 240)
	if not constraints.ok:
		return constraints
	var user_negative := _normalize_string_list(raw.get("negative_constraints", []), "$.negative_constraints", [], 180)
	if not user_negative.ok:
		return user_negative
	var negatives: Array[String] = []
	for default_constraint in DEFAULT_NEGATIVE_CONSTRAINTS:
		negatives.append(default_constraint)
	for constraint in user_negative.value:
		if constraint.to_lower() not in _lowercase_list(negatives):
			negatives.append(constraint)
	if negatives.size() > MAX_COMPILED_NEGATIVE_ITEMS:
		return _failure("too_many_items", "$.negative_constraints", "Combined negative constraints exceed the fixed list limit.")

	var accessibility := _normalize_accessibility(raw.get("accessibility", {}))
	if not accessibility.ok:
		return accessibility
	var camera := _normalize_camera(raw.get("camera", profile.default_camera), str(profile.default_camera))
	if not camera.ok:
		return camera
	var runtime := _normalize_runtime(raw.get("runtime", {}), modality_id)
	if not runtime.ok:
		return runtime
	var provenance := _normalize_provenance(raw)
	if not provenance.ok:
		return provenance
	var creative_brief := ""
	if raw.has("creative_brief"):
		if not raw.creative_brief is String:
			return _failure("field_type", "$.creative_brief", "Creative brief must be a string.")
		var creative_result := _sanitize_multiline(str(raw.creative_brief), "$.creative_brief")
		if not creative_result.ok:
			return creative_result
		creative_brief = creative_result.value

	var seed_value = raw.get("seed", 0)
	if not seed_value is int and not seed_value is float:
		return _failure("field_type", "$.seed", "Seed must be an integer.")
	var seed := int(seed_value)
	if seed < 0 or seed > 2_147_483_647 or float(seed_value) != float(seed):
		return _failure("field_range", "$.seed", "Seed must be a non-negative 32-bit integer.")

	return {
		"ok": true,
		"value": {
			"accessibility": accessibility.value,
			"asset_name": normalized_fields.asset_name,
			"camera": camera.value,
			"constraints": constraints.value,
			"creative_brief": creative_brief,
			"game_id": game_id,
			"intent": normalized_fields.intent,
			"materials": materials.value,
			"modality": modality_id,
			"mood": normalized_fields.mood,
			"negative_constraints": negatives,
			"palette": palette.value,
			"provenance": provenance.value,
			"runtime": runtime.value,
			"seed": seed,
			"style": normalized_fields.style,
			"theme": normalized_fields.theme,
		},
	}


func _normalize_accessibility(raw_value) -> Dictionary:
	var normalized := {
		"color_blind_safe": true,
		"high_contrast": true,
		"large_text": true,
		"notes": [],
		"reduced_motion": true,
		"screen_reader_labels": true,
	}
	if raw_value == null:
		return {"ok": true, "value": normalized}
	if raw_value is String or raw_value is Array:
		var notes := _normalize_string_list(raw_value, "$.accessibility", [], 200)
		if not notes.ok:
			return notes
		normalized.notes = notes.value
		return {"ok": true, "value": normalized}
	if not raw_value is Dictionary:
		return _failure("field_type", "$.accessibility", "Accessibility must be a string, list, or object.")
	for key in raw_value.keys():
		if str(key) not in ACCESSIBILITY_KEYS:
			return _failure("unknown_field", "$.accessibility." + str(key), "Unknown accessibility field.")
	for key in ["color_blind_safe", "high_contrast", "large_text", "reduced_motion", "screen_reader_labels"]:
		if raw_value.has(key):
			if not raw_value[key] is bool:
				return _failure("field_type", "$.accessibility." + key, "Accessibility switches must be boolean.")
			normalized[key] = raw_value[key]
	if raw_value.has("notes"):
		var notes := _normalize_string_list(raw_value.notes, "$.accessibility.notes", [], 200)
		if not notes.ok:
			return notes
		normalized.notes = notes.value
	return {"ok": true, "value": normalized}


func _normalize_camera(raw_value, fallback: String) -> Dictionary:
	if raw_value == null:
		return {"ok": true, "value": fallback}
	if raw_value is String:
		return _sanitize_text(raw_value, "$.camera", 240)
	if not raw_value is Dictionary:
		return _failure("field_type", "$.camera", "Camera must be a string or a bounded descriptor object.")
	var allowed := ["framing", "projection", "view"]
	var parts: Array[String] = []
	for key in raw_value.keys():
		if str(key) not in allowed:
			return _failure("unknown_field", "$.camera." + str(key), "Unknown camera descriptor field.")
	for key in allowed:
		if raw_value.has(key):
			if not raw_value[key] is String:
				return _failure("field_type", "$.camera." + key, "Camera descriptors must be strings.")
			var clean := _sanitize_text(str(raw_value[key]), "$.camera." + key, 100)
			if not clean.ok:
				return clean
			parts.append(key.replace("_", " ") + " " + str(clean.value))
	if parts.is_empty():
		return {"ok": true, "value": fallback}
	return {"ok": true, "value": ", ".join(PackedStringArray(parts))}


func _normalize_runtime(raw_value, modality_id: String) -> Dictionary:
	if raw_value == null:
		raw_value = {}
	if not raw_value is Dictionary:
		return _failure("field_type", "$.runtime", "Runtime metadata overrides must be an object.")
	for key in raw_value.keys():
		if str(key) not in RUNTIME_KEYS:
			return _failure("unknown_field", "$.runtime." + str(key), "Unknown runtime field.")

	var defaults := _runtime_defaults(modality_id)
	var ranges := {
		"channels": [1, 2],
		"duration_seconds": [1, 300],
		"frame_rate": [1, 120],
		"sample_rate_hz": [16_000, 96_000],
		"target_height": [64, 8_192],
		"target_width": [64, 8_192],
	}
	for key in ranges.keys():
		if raw_value.has(key):
			var value = raw_value[key]
			if not value is int and not value is float:
				return _failure("field_type", "$.runtime." + key, "Runtime numeric fields require whole numbers.")
			var integer := int(value)
			var bounds: Array = ranges[key]
			if float(value) != float(integer) or integer < int(bounds[0]) or integer > int(bounds[1]):
				return _failure("field_range", "$.runtime." + key, "Runtime field is outside the accepted range.")
			defaults[key] = integer
	for key in ["alpha", "loop", "seamless"]:
		if raw_value.has(key):
			if not raw_value[key] is bool:
				return _failure("field_type", "$.runtime." + key, "Runtime switches must be boolean.")
			defaults[key] = raw_value[key]
	if raw_value.has("locale"):
		if not raw_value.locale is String:
			return _failure("field_type", "$.runtime.locale", "Locale must be a string.")
		var locale := _sanitize_text(str(raw_value.locale), "$.runtime.locale", 32)
		if not locale.ok:
			return locale
		defaults.locale = locale.value
	return {"ok": true, "value": defaults}


func _runtime_defaults(modality_id: String) -> Dictionary:
	match modality_id:
		"audio":
			return {"channels": 2, "duration_seconds": 12, "loop": false, "sample_rate_hz": 48_000, "seamless": false}
		"voice_to_text":
			return {"channels": 1, "duration_seconds": 120, "locale": "auto", "sample_rate_hz": 16_000}
		"ui_kit":
			return {"alpha": true, "target_height": 2048, "target_width": 2048}
		"board_texture":
			return {"alpha": false, "seamless": true, "target_height": 4096, "target_width": 4096}
		"piece_sheet":
			return {"alpha": true, "target_height": 4096, "target_width": 4096}
		"world_concept":
			return {"alpha": false, "target_height": 2160, "target_width": 3840}
		_:
			return {"alpha": false, "target_height": 2048, "target_width": 2048}


func _normalize_provenance(raw: Dictionary) -> Dictionary:
	var combined: Dictionary = {}
	var nested = raw.get("provenance", {})
	if nested == null:
		nested = {}
	if not nested is Dictionary:
		return _failure("field_type", "$.provenance", "Provenance must be an object.")
	for key in nested.keys():
		if str(key) not in PROVENANCE_KEYS:
			return _failure("unknown_field", "$.provenance." + str(key), "Unknown provenance field.")
		combined[key] = nested[key]
	for key in ["author_id", "proposal_id", "shard_id"]:
		if raw.has(key):
			if combined.has(key) and str(combined[key]) != str(raw[key]):
				return _failure("ambiguous_field", "$.provenance." + key, "Conflicting provenance identifiers.")
			combined[key] = raw[key]

	var defaults := {
		"author_id": "anonymous-community-member",
		"content_commitment": "original-community-draft",
		"license_intent": "community-review-required",
		"proposal_id": "unassigned-proposal",
		"shard_id": "local-draft-shard",
		"source_kind": "player-authored-prompt",
	}
	for key in defaults.keys():
		var value = combined.get(key, defaults[key])
		if not value is String:
			return _failure("field_type", "$.provenance." + key, "Provenance values must be strings.")
		var clean := _sanitize_text(str(value), "$.provenance." + key, 120)
		if not clean.ok:
			return clean
		defaults[key] = clean.value
	return {"ok": true, "value": defaults}


func _build_prompt_sections(normalized: Dictionary, profile: Dictionary, runtime: Dictionary) -> Array[String]:
	var sections: Array[String] = []
	sections.append(
		"ORIGINAL COMMUNITY ASSET BRIEF — %s — %s. Create an entirely original design with no copied franchise, brand, character, artist, studio, logo, or commercial board presentation. This is a reviewable draft, not a published or chain-approved asset."
		% [str(profile.display_name).to_upper(), str(normalized.modality).replace("_", " ").to_upper()]
	)
	sections.append(
		"Intent and identity: %s. Asset name: %s. Theme: %s. Visual or sonic language: %s. Mood: %s."
		% [normalized.intent, normalized.asset_name, normalized.theme, normalized.style, normalized.mood]
	)
	if not str(normalized.creative_brief).is_empty():
		sections.append("Player-authored creative direction:\n" + str(normalized.creative_brief))
	sections.append(
		"Rules-first game contract: %s. %s. %s."
		% [profile.board_contract, profile.piece_contract, profile.interaction_contract]
	)
	sections.append(_modality_prompt(str(normalized.modality), profile, runtime.output))
	sections.append(
		"Art direction: use this bounded palette — %s. Express surfaces through %s. Camera and framing contract: %s."
		% [", ".join(PackedStringArray(normalized.palette)), ", ".join(PackedStringArray(normalized.materials)), normalized.camera]
	)
	var access: Dictionary = normalized.accessibility
	var access_states: Array[String] = []
	for key in ["high_contrast", "color_blind_safe", "large_text", "screen_reader_labels", "reduced_motion"]:
		access_states.append(key.replace("_", " ") + " " + ("required" if bool(access[key]) else "optional"))
	if not access.notes.is_empty():
		access_states.append("additional notes " + ", ".join(PackedStringArray(access.notes)))
	sections.append(
		"Accessibility contract: %s. Important state changes need at least two cues selected from shape, value, icon, label, outline, position, or sound."
		% ", ".join(PackedStringArray(access_states))
	)
	if not normalized.constraints.is_empty():
		sections.append("Player constraints: " + "; ".join(PackedStringArray(normalized.constraints)) + ".")
	sections.append(
		"Native Godot contract: target Godot %s; use import-ready resources with stable pivots, transparent padding where requested, no baked interface copy, no hidden scripts, and no external dependency. Preserve the exact runtime metadata supplied beside this brief."
		% GODOT_VERSION_CONTRACT
	)
	sections.append(
		"Hive collaboration boundary: preserve editable layers and semantic component names so player proposals can be diffed, previewed, voted on, rolled back, content-addressed, and mounted only after deterministic review. Stake may prioritize review but never substitutes for member consent or safety checks."
	)
	sections.append("Deterministic variation seed: %d." % int(normalized.seed))
	return sections


func _modality_prompt(modality_id: String, profile: Dictionary, runtime: Dictionary) -> String:
	match modality_id:
		"audio":
			return (
				"Bark-compatible audio brief: compose original non-lyrical game audio at %d Hz, %d channel output, target %d seconds, loop %s, seamless edge %s. Build a readable foreground cue, restrained mid-layer response, and quiet environmental bed with headroom for voice and accessibility cues. Supply a dry master and separable semantic stems; do not imitate a known recording, performer, or composition."
				% [runtime.sample_rate_hz, runtime.channels, runtime.duration_seconds, str(runtime.loop), str(runtime.seamless)]
			)
		"voice_to_text":
			return (
				"Voice-to-text interface brief: define a privacy-first transcription surface for %d Hz mono input up to %d seconds, locale %s. Show recording consent, local buffering, partial transcript, confidence, speaker-neutral labels, correction, discard, and explicit publish controls. Treat transcripts as private drafts by default and never place credentials or network coordinates in visible examples."
				% [runtime.sample_rate_hz, runtime.duration_seconds, runtime.locale]
			)
		"ui_kit":
			return (
				"UI kit brief: design a %d by %d transparent component atlas and individual lossless exports. Include %s. Provide default, hover, focus, pressed, selected, disabled, warning, pending vote, approved, quarantined, and rollback states; nine-patch-safe panels; keyboard focus rings; icon-plus-label redundancy; and legibility at 0.75, 1, 1.5, and 2 interface scale."
				% [runtime.target_width, runtime.target_height, profile.ui_contract]
			)
		"board_texture":
			return (
				"Board texture brief: create a %d by %d lossless surface, seamless %s, aligned to %s. Keep gameplay cells, lanes, coordinates, ownership, and legal-target overlays in separate semantic layers. Avoid decorative marks that could be mistaken for pieces or moves; retain a neutral albedo pass for dynamic Godot lighting."
				% [runtime.target_width, runtime.target_height, str(runtime.seamless), profile.board_contract]
			)
		"piece_sheet":
			return (
				"Token and piece sheet brief: create a %d by %d transparent, lossless atlas containing %s. Use equal cell bounds, consistent ground contact, generous transparent gutters, stable pivots, front and selected variants, silhouette separation at thumbnail size, and no text embedded in the pieces."
				% [runtime.target_width, runtime.target_height, profile.piece_contract]
			)
		"world_concept":
			return (
				"World concept brief: create a %d by %d establishing image with foreground interaction scale, midground traversal logic, background identity, and clear modular boundaries. Show how %s can exist inside a coherent social world while reserving uncluttered regions for native interface overlays."
				% [runtime.target_width, runtime.target_height, profile.interaction_contract]
			)
		_:
			return (
				"Image brief: create a %d by %d lossless original composition with alpha %s. Use strong silhouette hierarchy, restrained detail at interaction targets, clean edge separation, physically plausible material response, and space for native Godot labels and state overlays."
				% [runtime.target_width, runtime.target_height, str(runtime.alpha)]
			)


func _build_runtime_metadata(normalized: Dictionary, profile: Dictionary) -> Dictionary:
	var modality_id := str(normalized.modality)
	var output: Dictionary = normalized.runtime.duplicate(true)
	var resource_type := "Texture2D"
	var import_preset := "Lossless 2D"
	var expected_formats: Array[String] = ["png"]
	match modality_id:
		"audio":
			resource_type = "AudioStreamWAV"
			import_preset = "PCM master with optional Godot stream derivative"
			expected_formats = ["wav", "json"]
		"voice_to_text":
			resource_type = "Dictionary transcript envelope"
			import_preset = "UTF-8 structured transcript"
			expected_formats = ["json"]
		"ui_kit":
			resource_type = "AtlasTexture and StyleBox resources"
			import_preset = "Lossless 2D pixel and vector-safe UI"
			expected_formats = ["png", "json"]
		"board_texture":
			resource_type = "Texture2D and StandardMaterial3D"
			import_preset = "Lossless albedo with optional normal and roughness maps"
			expected_formats = ["png", "json"]
		"piece_sheet":
			resource_type = "AtlasTexture or SpriteFrames"
			import_preset = "Lossless alpha atlas"
			expected_formats = ["png", "json"]
		"world_concept":
			resource_type = "Texture2D reference with semantic layer manifest"
			import_preset = "Lossless concept reference"
			expected_formats = ["png", "json"]
	return {
		"color_space": "sRGB for color, linear for data maps",
		"engine": "Godot",
		"engine_version_contract": GODOT_VERSION_CONTRACT,
		"expected_formats": expected_formats,
		"game_display_name": profile.display_name,
		"import_preset": import_preset,
		"integration": {
			"external_dependency_required": false,
			"naming": "snake_case semantic resources",
			"pivot_contract": "stable and documented",
			"runtime_labels": "native Godot controls, never baked into generated pixels",
		},
		"modality": modality_id,
		"output": output,
		"renderer_contract": "Forward Plus and Compatibility safe",
		"resource_type": resource_type,
	}


func _build_generation_spec(normalized: Dictionary, profile: Dictionary, runtime: Dictionary, prompt: String, negative_prompt: String) -> Dictionary:
	var kind_by_modality := {
		"audio": "bark_compatible_audio_brief",
		"board_texture": "board_texture_brief",
		"image": "image_generation_brief",
		"piece_sheet": "token_piece_sheet_brief",
		"ui_kit": "godot_ui_kit_brief",
		"voice_to_text": "privacy_first_transcription_brief",
		"world_concept": "world_concept_brief",
	}
	return {
		"adapter_binding": "unbound_local_or_consented_adapter",
		"game_family": normalized.game_id,
		"kind": kind_by_modality[normalized.modality],
		"negative_prompt": negative_prompt,
		"originality_contract": "original_design_only",
		"profile_label": profile.display_name,
		"prompt": prompt,
		"runtime": runtime.duplicate(true),
		"seed": normalized.seed,
		"side_effects": "none_compiler_only",
	}


func _build_content_manifest(asset_id: String, normalized: Dictionary, runtime: Dictionary) -> Dictionary:
	return {
		"acceptance_checks": [
			"dimensions_or_duration_match_runtime_contract",
			"gameplay_geometry_matches_module_contract",
			"accessibility_states_are_distinguishable",
			"output_contains_no_brand_or_character_imitation",
			"output_contains_no_links_addresses_credentials_or_scripts",
			"output_hash_and_model_receipt_are_attached_before_publication",
		],
		"asset_id": asset_id,
		"content_state": "generation_pending",
		"game_id": normalized.game_id,
		"modality": normalized.modality,
		"output_hash": "pending_verified_generation",
		"required_files": runtime.expected_formats.duplicate(),
		"semantic_layers_required": true,
		"third_party_assets": [],
	}


func _build_provenance_manifest(asset_id: String, normalized: Dictionary, request_hash: String, prompt_hash: String) -> Dictionary:
	return {
		"asset_id": asset_id,
		"authorship": normalized.provenance.duplicate(true),
		"collaboration": {
			"community_design_target_ppm": 999_990,
			"harness_seed_target_ppm": 10,
			"stake_effect": "advisory_priority_only",
			"unanimous_online_vote_policy_supported": true,
		},
		"distribution": {
			"chain_checkpoint": "not_committed",
			"content_address": "not_assigned",
			"ipfs_pin": "not_pinned",
			"network_coordinate_included": false,
			"publication_state": "local_draft",
		},
		"generator_receipt": {
			"adapter": "unbound",
			"model": "unassigned",
			"output_hash": "pending",
			"receipt_hash": "pending",
		},
		"governance": {
			"automatic_authority": false,
			"consent_state": "not_requested",
			"deterministic_review_state": "pending",
			"rollback_required": true,
		},
		"originality": {
			"existing_asset_references": [],
			"named_brand_references": [],
			"original_design_required": true,
		},
		"prompt_hash": prompt_hash,
		"request_hash": request_hash,
		"schema": "nexus.asset.provenance.v1",
	}


func _normalize_string_list(raw_value, path: String, defaults: Array, max_item_chars: int) -> Dictionary:
	if raw_value == null:
		raw_value = defaults
	var source: Array = []
	if raw_value is String:
		source = [raw_value]
	elif raw_value is Array or raw_value is PackedStringArray:
		for item in raw_value:
			source.append(item)
	else:
		return _failure("field_type", path, "Expected a string or list of strings.")
	if source.size() > MAX_LIST_ITEMS:
		return _failure("too_many_items", path, "List exceeds the fixed item limit.")
	var output: Array[String] = []
	var seen: Dictionary = {}
	for index in range(source.size()):
		if not source[index] is String:
			return _failure("field_type", path + "[%d]" % index, "List items must be strings.")
		var clean := _sanitize_text(str(source[index]), path + "[%d]" % index, max_item_chars)
		if not clean.ok:
			return clean
		var key := str(clean.value).to_lower()
		if not seen.has(key):
			seen[key] = true
			output.append(clean.value)
	if output.is_empty() and not defaults.is_empty():
		for item in defaults:
			output.append(str(item))
	return {"ok": true, "value": output}


func _sanitize_text(raw_value: String, path: String, limit: int = MAX_FIELD_CHARS) -> Dictionary:
	if raw_value.length() > limit:
		return _failure("field_too_long", path, "Text exceeds the fixed field limit.")
	var violation := _unsafe_code(raw_value)
	if not violation.is_empty():
		return _failure(violation, path, "Unsafe or non-original prompt material was quarantined.")
	var filtered := ""
	for index in range(raw_value.length()):
		var code := raw_value.unicode_at(index)
		if code == 9 or code == 10 or code == 13:
			filtered += " "
		elif code >= 32 and code <= 126 and _allowed_ascii(code):
			filtered += char(code)
		elif code > 126:
			filtered += " "
	var words := filtered.split(" ", false)
	var clean := " ".join(words).strip_edges()
	if clean.is_empty():
		return _failure("empty_field", path, "Text is empty after sanitization.")
	return {"ok": true, "value": clean}


func _sanitize_multiline(raw_value: String, path: String) -> Dictionary:
	if raw_value.length() > MAX_CREATIVE_BRIEF_CHARS:
		return _failure("field_too_long", path, "Creative brief exceeds the fixed field limit.")
	var violation := _unsafe_code(raw_value)
	if not violation.is_empty():
		return _failure(violation, path, "Unsafe or non-original prompt material was quarantined.")
	var normalized_newlines := raw_value.replace("\r\n", "\n").replace("\r", "\n")
	var raw_lines := normalized_newlines.split("\n", true)
	if raw_lines.size() > MAX_CREATIVE_BRIEF_LINES:
		return _failure("too_many_lines", path, "Creative brief exceeds the fixed line limit.")
	var clean_lines: Array[String] = []
	var previous_blank := false
	for raw_line in raw_lines:
		var filtered := ""
		var line := str(raw_line)
		for index in range(line.length()):
			var code := line.unicode_at(index)
			if code == 9:
				filtered += " "
			elif code >= 32 and code <= 126 and _allowed_ascii(code):
				filtered += char(code)
			elif code > 126:
				filtered += " "
		var clean_line := " ".join(filtered.split(" ", false)).strip_edges()
		if clean_line.is_empty():
			if not previous_blank and not clean_lines.is_empty():
				clean_lines.append("")
			previous_blank = true
		else:
			clean_lines.append(clean_line)
			previous_blank = false
	while not clean_lines.is_empty() and clean_lines.back().is_empty():
		clean_lines.pop_back()
	var clean := "\n".join(PackedStringArray(clean_lines))
	if clean.is_empty():
		return _failure("empty_field", path, "Creative brief is empty after sanitization.")
	return {"ok": true, "value": clean}


func _allowed_ascii(code: int) -> bool:
	if code >= 48 and code <= 57:
		return true
	if code >= 65 and code <= 90:
		return true
	if code >= 97 and code <= 122:
		return true
	return code in [32, 33, 35, 37, 38, 39, 40, 41, 43, 44, 45, 46, 47, 58, 59, 61, 63, 95]


func _unsafe_code(raw_value: String) -> String:
	var lowered := raw_value.to_lower()
	for marker in URL_MARKERS:
		if lowered.contains(marker):
			return "network_coordinate_forbidden"
	for network_term in ["http", "https", "ftp", "www", "onion", "ip4", "ip6", "dns4", "dns6"]:
		if _contains_term(lowered, network_term):
			return "network_coordinate_forbidden"
	if _ipv4_regex.search(lowered) != null or _ipv6_regex.search(lowered) != null or lowered.contains("::"):
		return "network_coordinate_forbidden"
	for marker in SECRET_MARKERS:
		if lowered.contains(marker) or _contains_term(lowered, marker):
			return "secret_material_forbidden"
	for marker in INSTRUCTION_MARKERS:
		if lowered.contains(marker) or _contains_term(lowered, marker):
			return "instruction_material_forbidden"
	for marker in IMITATION_MARKERS:
		if lowered.contains(marker) or _contains_term(lowered, marker):
			return "imitation_request_forbidden"
	for term in TRADEMARK_TERMS:
		if _contains_term(lowered, term):
			return "trademark_reference_forbidden"
	return ""


func _contains_term(text: String, term: String) -> bool:
	var padded := " " + _word_normalize(text) + " "
	var needle := " " + _word_normalize(term) + " "
	return padded.contains(needle)


func _word_normalize(value: String) -> String:
	var output := ""
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if (code >= 48 and code <= 57) or (code >= 97 and code <= 122):
			output += char(code)
		else:
			output += " "
	return " ".join(output.split(" ", false))


func _normalize_alias(raw_value: String) -> String:
	return " ".join(raw_value.strip_edges().to_lower().replace("-", " ").split(" ", false))


func _validate_json_shape(value, depth: int, path: String) -> Dictionary:
	if depth > MAX_DEPTH:
		return _failure("maximum_depth_exceeded", path, "Input nesting exceeds the compiler limit.")
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return {"ok": true}
		TYPE_FLOAT:
			if is_nan(value) or is_inf(value):
				return _failure("non_finite_number", path, "Non-finite numbers are not JSON-safe.")
			return {"ok": true}
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY:
			if value.size() > MAX_LIST_ITEMS:
				return _failure("too_many_items", path, "Array exceeds the fixed item limit.")
			for index in range(value.size()):
				var child := _validate_json_shape(value[index], depth + 1, path + "[%d]" % index)
				if not child.ok:
					return child
			return {"ok": true}
		TYPE_DICTIONARY:
			if value.size() > MAX_MAP_KEYS:
				return _failure("too_many_fields", path, "Object exceeds the fixed field limit.")
			for key in value.keys():
				if not key is String:
					return _failure("non_string_key", path, "JSON object keys must be strings.")
				var child := _validate_json_shape(value[key], depth + 1, path + "." + key)
				if not child.ok:
					return child
			return {"ok": true}
		_:
			return _failure("non_json_value", path, "Input contains a non-JSON value.")


func _failure(code: String, path: String, summary: String) -> Dictionary:
	return {
		"code": code,
		"errors": [{"code": code, "path": path, "summary": summary}],
		"ok": false,
		"quarantined": true,
	}


func _lowercase_list(values: Array[String]) -> Array[String]:
	var lowered: Array[String] = []
	for value in values:
		lowered.append(value.to_lower())
	return lowered


static func canonical_json(value) -> String:
	return JSON.stringify(_canonicalize(value))


static func hash_value(value) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(canonical_json(value).to_utf8_buffer())
	return context.finish().hex_encode()


static func _canonicalize(value):
	match typeof(value):
		TYPE_DICTIONARY:
			var keys: Array = value.keys()
			keys.sort_custom(func(left, right): return str(left) < str(right))
			var output: Dictionary = {}
			for key in keys:
				output[str(key)] = _canonicalize(value[key])
			return output
		TYPE_ARRAY:
			var output: Array = []
			for item in value:
				output.append(_canonicalize(item))
			return output
		TYPE_PACKED_STRING_ARRAY:
			var output: Array = []
			for item in value:
				output.append(str(item))
			return output
		_:
			return value
