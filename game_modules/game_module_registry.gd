extends RefCounted

const ChessCore = preload("res://game_modules/chess_core.gd")
const FourLine = preload("res://game_modules/four_line.gd")
const Draughts = preload("res://game_modules/draughts.gd")
const PropertyGrid = preload("res://game_modules/property_grid.gd")

const MODULE_IDS := ["chess_core", "draughts", "four_line", "property_grid"]
const ALIASES := {
	"chess": "chess_core",
	"chess_core": "chess_core",
	"checkers": "draughts",
	"draughts": "draughts",
	"connect_four": "four_line",
	"connect_4": "four_line",
	"four_line": "four_line",
	"property": "property_grid",
	"property_grid": "property_grid",
	"property_loop": "property_grid",
}


static func create(requested_id: String) -> RefCounted:
	match normalize_id(requested_id):
		"chess_core":
			return ChessCore.new()
		"draughts":
			return Draughts.new()
		"four_line":
			return FourLine.new()
		"property_grid":
			return PropertyGrid.new()
		_:
			return null


static func has_module(requested_id: String) -> bool:
	return normalize_id(requested_id) in MODULE_IDS


static func normalize_id(requested_id: String) -> String:
	var key := requested_id.strip_edges().to_lower().replace("-", "_").replace(" ", "_")
	while "__" in key:
		key = key.replace("__", "_")
	return str(ALIASES.get(key, key))


static func list_ids() -> Array:
	return MODULE_IDS.duplicate()


static func list_manifests() -> Array:
	var manifests: Array = []
	for module_id in MODULE_IDS:
		var module := create(module_id)
		manifests.append(module.manifest())
	return manifests
