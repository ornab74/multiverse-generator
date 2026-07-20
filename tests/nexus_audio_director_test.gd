extends SceneTree

const AudioDirectorScript = preload("res://systems/nexus_audio_director.gd")

const EXPECTED_STREAMS := [
	"ui_hover",
	"ui_press",
	"select",
	"legal_move",
	"reject",
	"commit",
	"capture",
	"module_mount",
	"forge",
	"peer_link",
	"ambience",
]

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var director = AudioDirectorScript.new()
	director.name = "AudioDirectorUnderTest"
	root.add_child(director)
	await process_frame

	var snapshot: Dictionary = director.get_debug_snapshot()
	_expect(snapshot.get("initialized", false), "director did not initialize")
	_expect(snapshot.get("stream_count", 0) == EXPECTED_STREAMS.size(), "unexpected stream count")
	_expect(not snapshot.get("external_assets_used", true), "director claimed an external asset")
	_expect(not snapshot.get("network_calls_performed", true), "director claimed a network call")
	for bus_index in snapshot.get("bus_indexes", {}).values():
		_expect(int(bus_index) >= 0, "required audio bus was not created")

	var manifest: Dictionary = snapshot.get("stream_manifest", {})
	for cue in EXPECTED_STREAMS:
		_expect(manifest.has(cue), "missing procedural cue: " + cue)
		if manifest.has(cue):
			var entry: Dictionary = manifest[cue]
			_expect(entry.get("byte_count", 0) > 100, cue + " PCM payload was empty")
			_expect(entry.get("mix_rate", 0) == AudioDirectorScript.SAMPLE_RATE, cue + " mix rate changed")
			_expect(String(entry.get("sha256", "")).length() == 64, cue + " hash was invalid")
	var ambience := director.get_stream("ambience")
	_expect(ambience != null and ambience.stereo, "ambience was not stereo")
	_expect(ambience != null and ambience.loop_mode == AudioStreamWAV.LOOP_FORWARD, "ambience did not loop")
	_expect(ambience != null and ambience.loop_end == int(AudioDirectorScript.AMBIENCE_SECONDS * AudioDirectorScript.SAMPLE_RATE), "ambience loop boundary changed")

	var deterministic_copy = AudioDirectorScript.new()
	var second_manifest: Dictionary = deterministic_copy.build_streams()
	for cue in EXPECTED_STREAMS:
		_expect(second_manifest.get(cue, {}).get("sha256", "") == manifest.get(cue, {}).get("sha256", ""), cue + " was not deterministic")
	deterministic_copy.free()

	var old_levels: Dictionary = director.get_levels()
	var invalid_level: Dictionary = director.set_levels({"ui": 1.5})
	_expect(not invalid_level.get("ok", true), "out-of-range level was accepted")
	_expect(director.get_levels() == old_levels, "invalid level changed live settings")
	var valid_level: Dictionary = director.set_levels({"master": 0.7, "ui": 0.6, "sfx": 0.8, "ambience": 0.3})
	_expect(valid_level.get("ok", false), "valid levels were rejected")
	_expect(is_equal_approx(float(director.get_levels()["music"]), 0.3), "ambience alias did not control music")

	var panel := VBoxContainer.new()
	var first_button := Button.new()
	var second_button := Button.new()
	second_button.set_meta("nexus_audio_press", "press")
	panel.add_child(first_button)
	panel.add_child(second_button)
	root.add_child(panel)
	_expect(director.bind_ui(panel) == 2, "bind_ui did not bind both buttons")
	_expect(director.bind_ui(panel) == 0, "bind_ui connected duplicate handlers")
	first_button.mouse_entered.emit()
	first_button.pressed.emit()
	await process_frame
	var played: Dictionary = director.get_debug_snapshot().get("play_counts", {})
	_expect(played.get("hover", 0) == 1, "bound hover did not play exactly once")
	_expect(played.get("press", 0) == 1, "bound press did not play exactly once")
	_expect(director.play_sfx("legal move"), "normalized SFX cue did not play")
	_expect(not director.play_sfx("unknown"), "unknown SFX cue was accepted")
	_expect(director.start_ambience(), "ambience did not start")
	_expect(director.is_ambience_playing(), "ambience player did not report playing")
	director.stop_ambience()

	panel.queue_free()
	director.queue_free()
	await process_frame
	# Give the audio mixer one cycle to release stopped playback references before
	# the SceneTree exits; this keeps headless leak diagnostics meaningful.
	await create_timer(0.12).timeout
	if failures.is_empty():
		print("NEXUS_AUDIO_DIRECTOR_TEST: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("NEXUS_AUDIO_DIRECTOR_TEST: " + failure)
		quit(1)


func _expect(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)
