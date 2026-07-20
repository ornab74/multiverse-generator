extends Node
class_name NexusAudioDirector

## Original, deterministic procedural audio for the Nexus interface.
##
## No files, network services, model outputs, microphones, or random generators are
## used. Every cue is rendered to PCM16 AudioStreamWAV data in memory. The small
## player pools permit overlapping feedback without relying on an audio plug-in.

signal cue_played(category: String, cue: String)
signal ambience_changed(playing: bool)

const COMPONENT_ID := "nexus.audio-director/v1"
const SAMPLE_RATE := 22_050
const AMBIENCE_SECONDS := 8.0
const BUS_MASTER := "NEXUS"
const BUS_UI := "NEXUS UI"
const BUS_SFX := "NEXUS SFX"
const BUS_MUSIC := "NEXUS MUSIC"

const UI_CUES := ["hover", "press"]
const SFX_CUES := [
	"select",
	"legal_move",
	"reject",
	"commit",
	"capture",
	"module_mount",
	"forge",
	"peer_link",
]

const EFFECT_DURATIONS := {
	"ui_hover": 0.060,
	"ui_press": 0.095,
	"select": 0.160,
	"legal_move": 0.210,
	"reject": 0.235,
	"commit": 0.440,
	"capture": 0.300,
	"module_mount": 0.520,
	"forge": 0.650,
	"peer_link": 0.380,
}

const DEFAULT_LEVELS := {
	"master": 0.82,
	"ui": 0.78,
	"sfx": 0.84,
	"music": 0.42,
}

var _streams: Dictionary = {}
var _ui_players: Array[AudioStreamPlayer] = []
var _sfx_players: Array[AudioStreamPlayer] = []
var _music_player: AudioStreamPlayer
var _ui_cursor := 0
var _sfx_cursor := 0
var _initialized := false
var _bound_control_ids: Dictionary = {}
var _play_counts: Dictionary = {}
var _last_category := ""
var _last_cue := ""
var _levels: Dictionary = DEFAULT_LEVELS.duplicate(true)
var _bus_receipt: Dictionary = {}


func _ready() -> void:
	initialize()


func _exit_tree() -> void:
	stop_ambience()
	for player in _ui_players:
		player.stop()
		player.stream = null
	for player in _sfx_players:
		player.stop()
		player.stream = null
	if _music_player:
		_music_player.stop()
		_music_player.stream = null
	_ui_players.clear()
	_sfx_players.clear()
	_music_player = null
	_streams.clear()
	_bound_control_ids.clear()
	_initialized = false


## Idempotently creates the audio buses, streams, and lightweight player pools.
func initialize() -> Dictionary:
	if _initialized:
		return get_debug_snapshot()
	_bus_receipt = ensure_audio_buses()
	build_streams()
	_ensure_players()
	_initialized = true
	return get_debug_snapshot()


## Adds only missing Nexus buses. Existing buses with these names are preserved.
func ensure_audio_buses() -> Dictionary:
	var created: Array[String] = []
	_ensure_bus(BUS_MASTER, "Master", created)
	_ensure_bus(BUS_UI, BUS_MASTER, created)
	_ensure_bus(BUS_SFX, BUS_MASTER, created)
	_ensure_bus(BUS_MUSIC, BUS_MASTER, created)
	for level_name in DEFAULT_LEVELS.keys():
		var bus_name := _bus_for_level(String(level_name))
		if bus_name in created:
			_set_bus_linear(bus_name, float(DEFAULT_LEVELS[level_name]))
	return {
		"ok": true,
		"created": created,
		"bus_indexes": _bus_indexes(),
		"global_master_untouched": true,
	}


## Deterministically renders every built-in cue. Repeated calls are no-ops.
func build_streams() -> Dictionary:
	if not _streams.is_empty():
		return get_stream_manifest()
	for cue_value in EFFECT_DURATIONS.keys():
		var cue := String(cue_value)
		_streams[cue] = _render_effect(cue, float(EFFECT_DURATIONS[cue]))
	_streams["ambience"] = _render_ambience()
	return get_stream_manifest()


## Plays hover or press feedback. "ui_hover" and "ui_press" are accepted aliases.
func play_ui(cue: String = "press") -> bool:
	_ensure_initialized()
	var normalized := _normalize_cue(cue)
	if normalized.begins_with("ui_"):
		normalized = normalized.trim_prefix("ui_")
	if normalized not in UI_CUES:
		return false
	return _play_from_pool(_ui_players, "ui_" + normalized, "ui")


## Plays a game/system cue. Names are normalized to lower snake_case.
func play_sfx(cue: String) -> bool:
	_ensure_initialized()
	var normalized := _normalize_cue(cue)
	if normalized not in SFX_CUES:
		return false
	return _play_from_pool(_sfx_players, normalized, "sfx")


## Starts the seamless procedural bed. Calling twice does not restart it unless asked.
func start_ambience(restart: bool = false) -> bool:
	_ensure_initialized()
	if not is_inside_tree() or _music_player == null:
		return false
	if _music_player.playing and not restart:
		return true
	_music_player.stream = _streams["ambience"]
	_music_player.play()
	_play_counts["ambience"] = int(_play_counts.get("ambience", 0)) + 1
	_last_category = "music"
	_last_cue = "ambience"
	cue_played.emit("music", "ambience")
	ambience_changed.emit(true)
	return true


func stop_ambience() -> void:
	if _music_player != null and _music_player.playing:
		_music_player.stop()
		ambience_changed.emit(false)


func is_ambience_playing() -> bool:
	return _music_player != null and _music_player.playing


## Applies isolated Nexus levels in linear 0..1 units. Invalid input changes nothing.
## Accepted keys: master, ui, sfx, music, and ambience (an alias for music).
func set_levels(levels: Dictionary) -> Dictionary:
	_ensure_initialized()
	var validated: Dictionary = {}
	for key_value in levels.keys():
		var key := String(key_value).strip_edges().to_lower()
		if key == "ambience":
			key = "music"
		if key not in DEFAULT_LEVELS:
			return {"ok": false, "reason": "unknown_level_" + key}
		var value: Variant = levels[key_value]
		if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
			return {"ok": false, "reason": "level_must_be_numeric_" + key}
		var linear := float(value)
		if not is_finite(linear) or linear < 0.0 or linear > 1.0:
			return {"ok": false, "reason": "level_out_of_range_" + key}
		validated[key] = linear
	for key_value in validated.keys():
		var key := String(key_value)
		_levels[key] = float(validated[key])
		_set_bus_linear(_bus_for_level(key), float(validated[key]))
	return {"ok": true, "levels": _levels.duplicate(true)}


func get_levels() -> Dictionary:
	return _levels.duplicate(true)


## Connects all BaseButton descendants to original hover/press cues.
## Metadata nexus_audio_hover / nexus_audio_press may override a button's cue.
func bind_ui(root_node: Node) -> int:
	if root_node == null:
		return 0
	_ensure_initialized()
	var pending: Array[Node] = [root_node]
	var bound_count := 0
	while not pending.is_empty():
		var current: Node = pending.pop_back()
		for child in current.get_children():
			pending.append(child)
		if not current is BaseButton:
			continue
		var button := current as BaseButton
		var instance_id := button.get_instance_id()
		if _bound_control_ids.has(instance_id):
			continue
		var hover_cue := String(button.get_meta("nexus_audio_hover", "hover"))
		var press_cue := String(button.get_meta("nexus_audio_press", "press"))
		button.mouse_entered.connect(_on_bound_hover.bind(hover_cue))
		button.pressed.connect(_on_bound_press.bind(press_cue))
		button.tree_exiting.connect(_on_bound_control_exiting.bind(instance_id), CONNECT_ONE_SHOT)
		_bound_control_ids[instance_id] = true
		bound_count += 1
	return bound_count


func get_stream(cue: String) -> AudioStreamWAV:
	if _streams.is_empty():
		build_streams()
	var normalized := _normalize_cue(cue)
	if normalized in UI_CUES:
		normalized = "ui_" + normalized
	return _streams.get(normalized) as AudioStreamWAV


func get_stream_manifest() -> Dictionary:
	var manifest: Dictionary = {}
	for cue_value in _streams.keys():
		var cue := String(cue_value)
		var stream := _streams[cue] as AudioStreamWAV
		var bytes_per_frame := 4 if stream.stereo else 2
		manifest[cue] = {
			"sha256": _digest_bytes(stream.data),
			"byte_count": stream.data.size(),
			"frame_count": stream.data.size() / bytes_per_frame,
			"mix_rate": stream.mix_rate,
			"stereo": stream.stereo,
			"looped": stream.loop_mode != AudioStreamWAV.LOOP_DISABLED,
		}
	return manifest


func get_debug_snapshot() -> Dictionary:
	return {
		"component_id": COMPONENT_ID,
		"initialized": _initialized,
		"stream_count": _streams.size(),
		"stream_manifest": get_stream_manifest(),
		"bus_indexes": _bus_indexes(),
		"bus_receipt": _bus_receipt.duplicate(true),
		"levels": _levels.duplicate(true),
		"bound_button_count": _bound_control_ids.size(),
		"play_counts": _play_counts.duplicate(true),
		"last_category": _last_category,
		"last_cue": _last_cue,
		"external_assets_used": false,
		"network_calls_performed": false,
		"deterministic_pcm": true,
	}


func _ensure_initialized() -> void:
	if not _initialized:
		initialize()


func _ensure_bus(bus_name: String, send_name: String, created: Array[String]) -> int:
	var index := AudioServer.get_bus_index(bus_name)
	if index >= 0:
		return index
	AudioServer.add_bus()
	index = AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus_name)
	if send_name != "":
		AudioServer.set_bus_send(index, send_name)
	created.append(bus_name)
	return index


func _bus_indexes() -> Dictionary:
	return {
		"master": AudioServer.get_bus_index(BUS_MASTER),
		"ui": AudioServer.get_bus_index(BUS_UI),
		"sfx": AudioServer.get_bus_index(BUS_SFX),
		"music": AudioServer.get_bus_index(BUS_MUSIC),
	}


func _bus_for_level(level_name: String) -> String:
	match level_name:
		"master":
			return BUS_MASTER
		"ui":
			return BUS_UI
		"sfx":
			return BUS_SFX
		"music", "ambience":
			return BUS_MUSIC
	return BUS_MASTER


func _set_bus_linear(bus_name: String, linear: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	var decibels := -80.0 if linear <= 0.0 else maxf(-80.0, 20.0 * log(linear) / log(10.0))
	AudioServer.set_bus_volume_db(index, decibels)


func _ensure_players() -> void:
	if _music_player != null:
		return
	for index in 3:
		var player := AudioStreamPlayer.new()
		player.name = "UIVoice%02d" % index
		player.bus = BUS_UI
		_ui_players.append(player)
		add_child(player)
	for index in 5:
		var player := AudioStreamPlayer.new()
		player.name = "SFXVoice%02d" % index
		player.bus = BUS_SFX
		_sfx_players.append(player)
		add_child(player)
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "AmbienceVoice"
	_music_player.bus = BUS_MUSIC
	add_child(_music_player)


func _play_from_pool(pool: Array[AudioStreamPlayer], stream_key: String, category: String) -> bool:
	if not is_inside_tree() or pool.is_empty() or not _streams.has(stream_key):
		return false
	var cursor := _ui_cursor if category == "ui" else _sfx_cursor
	var player := pool[cursor % pool.size()]
	if category == "ui":
		_ui_cursor = (_ui_cursor + 1) % pool.size()
	else:
		_sfx_cursor = (_sfx_cursor + 1) % pool.size()
	player.stream = _streams[stream_key]
	player.play()
	var public_cue := stream_key.trim_prefix("ui_") if category == "ui" else stream_key
	_play_counts[public_cue] = int(_play_counts.get(public_cue, 0)) + 1
	_last_category = category
	_last_cue = public_cue
	cue_played.emit(category, public_cue)
	return true


func _on_bound_hover(cue: String) -> void:
	play_ui(cue)


func _on_bound_press(cue: String) -> void:
	play_ui(cue)


func _on_bound_control_exiting(instance_id: int) -> void:
	_bound_control_ids.erase(instance_id)


func _normalize_cue(cue: String) -> String:
	return cue.strip_edges().to_lower().replace("-", "_").replace(" ", "_")


func _render_effect(cue: String, duration: float) -> AudioStreamWAV:
	var frame_count := int(ceil(duration * SAMPLE_RATE))
	var pcm := PackedByteArray()
	pcm.resize(frame_count * 2)
	for frame in frame_count:
		var time := float(frame) / float(SAMPLE_RATE)
		var sample := clampf(_effect_sample(cue, time, duration, frame), -0.98, 0.98)
		pcm.encode_s16(frame * 2, int(round(sample * 32_767.0)))
	var stream := AudioStreamWAV.new()
	stream.resource_name = "Nexus Procedural " + cue
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	stream.data = pcm
	return stream


func _effect_sample(cue: String, time: float, duration: float, frame: int) -> float:
	var envelope := _fade_envelope(time, duration, 0.006, minf(0.090, duration * 0.48))
	match cue:
		"ui_hover":
			var hover := _chirp(time, duration, 880.0, 1_180.0)
			return envelope * exp(-time * 24.0) * (0.24 * hover + 0.035 * _noise(frame, 11))
		"ui_press":
			var press := 0.28 * _chirp(time, duration, 510.0, 285.0)
			press += 0.10 * sin(TAU * 940.0 * time) * exp(-time * 28.0)
			press += 0.045 * _noise(frame, 19) * exp(-time * 55.0)
			return envelope * press
		"select":
			var select_tone := 0.25 * sin(TAU * 660.0 * time)
			select_tone += 0.15 * sin(TAU * 990.0 * time + 0.25)
			select_tone += 0.08 * _chirp(time, duration, 420.0, 840.0)
			return envelope * exp(-time * 5.0) * select_tone
		"legal_move":
			var move := 0.22 * _chirp(time, duration, 330.0, 660.0)
			move += 0.14 * _chirp(time, duration, 495.0, 990.0)
			move += 0.055 * sin(TAU * 1_320.0 * time) * exp(-time * 12.0)
			return envelope * move
		"reject":
			var reject := 0.22 * _chirp(time, duration, 240.0, 118.0)
			reject += 0.15 * sin(TAU * 173.0 * time)
			reject -= 0.12 * sin(TAU * 184.0 * time)
			reject += 0.04 * _noise(frame, 31) * exp(-time * 8.0)
			return envelope * reject
		"commit":
			var impact := (0.20 * sin(TAU * 82.5 * time) + 0.08 * _noise(frame, 41)) * exp(-time * 15.0)
			var rise := 0.18 * _chirp(time, duration, 220.0, 880.0)
			var seal := 0.15 * sin(TAU * 1_100.0 * maxf(0.0, time - 0.24))
			seal *= _pulse(time, 0.24, 0.19)
			return envelope * (impact + rise + seal)
		"capture":
			var hit := 0.24 * _noise(frame, 53) * exp(-time * 24.0)
			hit += 0.27 * _chirp(time, duration, 190.0, 62.0) * exp(-time * 7.0)
			hit += 0.09 * sin(TAU * 740.0 * time) * exp(-time * 18.0)
			return envelope * hit
		"module_mount":
			var scan := 0.16 * _chirp(time, duration, 90.0, 1_240.0)
			scan += 0.10 * sin(TAU * 440.0 * time) * sin(PI * time / duration)
			var ready_ping := 0.20 * sin(TAU * 1_320.0 * maxf(0.0, time - 0.35))
			ready_ping *= _pulse(time, 0.35, 0.16)
			return envelope * (scan + ready_ping)
		"forge":
			var metal := 0.17 * sin(TAU * 271.0 * time) * exp(-time * 3.8)
			metal += 0.13 * sin(TAU * 433.0 * time + 0.4) * exp(-time * 4.6)
			metal += 0.10 * sin(TAU * 701.0 * time + 1.1) * exp(-time * 5.5)
			metal += 0.18 * _noise(frame, 67) * exp(-time * 32.0)
			metal += 0.11 * _chirp(time, duration, 120.0, 720.0)
			return envelope * metal
		"peer_link":
			var call := 0.22 * sin(TAU * 520.0 * time) * _pulse(time, 0.00, 0.14)
			call += 0.13 * sin(TAU * 780.0 * time) * _pulse(time, 0.04, 0.12)
			var response_time := maxf(0.0, time - 0.18)
			var response := 0.22 * sin(TAU * 650.0 * response_time) * _pulse(time, 0.18, 0.18)
			response += 0.12 * sin(TAU * 975.0 * response_time) * _pulse(time, 0.21, 0.15)
			return envelope * (call + response)
	return 0.0


func _render_ambience() -> AudioStreamWAV:
	var frame_count := int(AMBIENCE_SECONDS * SAMPLE_RATE)
	var pcm := PackedByteArray()
	pcm.resize(frame_count * 4)
	var notes := [164.81, 220.00, 246.94, 329.63, 220.00, 293.66, 246.94, 196.00]
	for frame in frame_count:
		var loop_phase := float(frame) / float(frame_count)
		var slow_mod := 0.72 + 0.16 * sin(TAU * 2.0 * loop_phase)
		slow_mod += 0.06 * sin(TAU * 3.0 * loop_phase + 0.7)
		var left := 0.105 * sin(TAU * 440.0 * loop_phase)
		left += 0.060 * sin(TAU * 660.0 * loop_phase + 0.35)
		left += 0.030 * sin(TAU * 1_357.0 * loop_phase + 1.1)
		var right := 0.105 * sin(TAU * 440.0 * loop_phase + 0.12)
		right += 0.060 * sin(TAU * 660.0 * loop_phase + 0.70)
		right += 0.030 * sin(TAU * 1_363.0 * loop_phase + 1.7)
		var step_phase: float = loop_phase * 8.0
		var step := mini(7, int(floor(step_phase)))
		var local_phase: float = step_phase - floor(step_phase)
		var local_time: float = local_phase * (AMBIENCE_SECONDS / 8.0)
		var note_envelope := pow(sin(PI * local_phase), 2.0)
		var note := float(notes[step])
		var arp := sin(TAU * note * local_time) + 0.32 * sin(TAU * note * 2.0 * local_time)
		left = slow_mod * left + 0.034 * arp * note_envelope
		right = slow_mod * right + 0.034 * arp * note_envelope * (0.72 + 0.28 * sin(PI * local_phase))
		pcm.encode_s16(frame * 4, int(round(clampf(left, -0.95, 0.95) * 32_767.0)))
		pcm.encode_s16(frame * 4 + 2, int(round(clampf(right, -0.95, 0.95) * 32_767.0)))
	var stream := AudioStreamWAV.new()
	stream.resource_name = "Nexus Procedural Ambience"
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = true
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = frame_count
	stream.data = pcm
	return stream


func _fade_envelope(time: float, duration: float, attack: float, release: float) -> float:
	var attack_gain := _smooth(clampf(time / maxf(attack, 0.0001), 0.0, 1.0))
	var release_gain := _smooth(clampf((duration - time) / maxf(release, 0.0001), 0.0, 1.0))
	return minf(attack_gain, release_gain)


func _smooth(value: float) -> float:
	return value * value * (3.0 - 2.0 * value)


func _chirp(time: float, duration: float, start_hz: float, end_hz: float) -> float:
	var sweep := (end_hz - start_hz) / maxf(duration, 0.0001)
	return sin(TAU * (start_hz * time + 0.5 * sweep * time * time))


func _pulse(time: float, start: float, length: float) -> float:
	if time < start or time >= start + length:
		return 0.0
	var phase := (time - start) / length
	return pow(sin(PI * phase), 2.0)


func _noise(frame: int, salt: int) -> float:
	var value: int = (frame * 1_664_525 + salt * 374_761_393 + 1_013_904_223) & 0x7fffffff
	value = value ^ (value >> 13)
	value = (value * 1_274_126_177) & 0x7fffffff
	value = value ^ (value >> 16)
	return float(value) / 1_073_741_823.5 - 1.0


func _digest_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()
