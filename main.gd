extends Node3D

## Product entry point.  The active scene contains only the clean AI-chess
## shell; legacy world/module prototypes are not constructed at boot.

const FrontEndScript = preload("res://front_end.gd")

var front_end: NexusFrontEnd


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("#050812"))
	front_end = FrontEndScript.new()
	add_child(front_end)
	var requested_screen := OS.get_environment("NEXUS_SCREEN")
	front_end.open("SETTINGS" if requested_screen == "SETTINGS" else "PLAY")
