extends RefCounted
class_name NexusChessHistory

## Bounded, reducer-receipt-backed chess timeline.
##
## This object never decides whether a move is legal.  Call `commit()` only with
## the result returned by Chess Core's deterministic reducer.  Undo and redo
## return snapshots for the host to reconcile; they do not mutate the reducer or
## presentation layer themselves.

signal changed(summary: Dictionary)

const SCHEMA := "nexus.chess-history/1"
const DEFAULT_MAX_RECORDS := 256
const MIN_MAX_RECORDS := 8
const HARD_MAX_RECORDS := 2048
const MAX_NOTE_LENGTH := 320
const FILES := "abcdefgh"
const PIECE_NAMES := {
	"K": "King",
	"Q": "Queen",
	"R": "Rook",
	"B": "Bishop",
	"N": "Knight",
	"P": "Pawn",
}

var _max_records := DEFAULT_MAX_RECORDS
var _records: Array[Dictionary] = []
var _redo_records: Array[Dictionary] = []
var _new_game_snapshot: Dictionary = {}
var _base_snapshot: Dictionary = {}
var _current_snapshot: Dictionary = {}
var _current_hash := ""
var _total_plies := 0


func _init(max_records: int = DEFAULT_MAX_RECORDS) -> void:
	_max_records = clampi(max_records, MIN_MAX_RECORDS, HARD_MAX_RECORDS)


func new_game(initial_state: Dictionary, state_hash: String = "") -> Dictionary:
	var verdict := _validate_state(initial_state)
	if not verdict.ok:
		return verdict
	_records.clear()
	_redo_records.clear()
	_new_game_snapshot = initial_state.duplicate(true)
	_base_snapshot = initial_state.duplicate(true)
	_current_snapshot = initial_state.duplicate(true)
	_current_hash = state_hash.strip_edges()
	_total_plies = 0
	_emit_changed()
	return {
		"ok": true,
		"code": "new_game",
		"state": _current_snapshot.duplicate(true),
		"state_hash": _current_hash,
	}


## Accepts only a successful reducer receipt whose previous hash/revision still
## matches the current timeline.  The exact reducer action and both snapshots
## are retained, so the renderer can restore captures, castling, and promotion.
func commit(
	before_state: Dictionary,
	action: Dictionary,
	reducer_result: Dictionary,
	metadata: Dictionary = {}
) -> Dictionary:
	if _current_snapshot.is_empty():
		return _invalid("history_not_started", "Call new_game() before recording moves.")
	var before_verdict := _validate_state(before_state)
	if not before_verdict.ok:
		return before_verdict
	if not reducer_result.get("ok", false):
		return _invalid("reducer_rejected", "A rejected reducer result cannot enter authoritative history.")
	if not reducer_result.get("state", null) is Dictionary:
		return _invalid("receipt_state", "The reducer receipt has no chess state.")
	var after_state: Dictionary = Dictionary(reducer_result.state)
	var after_verdict := _validate_state(after_state)
	if not after_verdict.ok:
		return after_verdict
	var action_verdict := _validate_action(action)
	if not action_verdict.ok:
		return action_verdict
	if not _same_position(before_state, _current_snapshot):
		return _invalid("history_conflict", "The supplied before-state is not the history head.")
	var before_revision := int(before_state.get("revision", -1))
	var after_revision := int(after_state.get("revision", -1))
	if after_revision != before_revision + 1:
		return _invalid("receipt_revision", "A committed move must advance the reducer revision exactly once.")
	var receipt_previous_hash := str(reducer_result.get("previous_hash", "")).strip_edges()
	if not _current_hash.is_empty() and not receipt_previous_hash.is_empty() and receipt_previous_hash != _current_hash:
		return _invalid("receipt_previous_hash", "The reducer receipt does not extend the current history hash.")

	var uci := uci_for_action(action)
	if uci.is_empty():
		return _invalid("action_uci", "The reducer action cannot be represented as a UCI move.")
	var after_hash := str(reducer_result.get("state_hash", "")).strip_edges()
	var record := {
		"schema": SCHEMA,
		"ply": _total_plies + 1,
		"move_number": int(before_state.get("fullmove_number", (_total_plies / 2) + 1)),
		"side": str(before_state.get("turn", "")),
		"actor": str(action.get("actor", "")),
		"uci": uci,
		"algebraic": algebraic_for_action(before_state, action, after_state),
		"action": action.duplicate(true),
		"before_revision": before_revision,
		"after_revision": after_revision,
		"before_hash": receipt_previous_hash if not receipt_previous_hash.is_empty() else _current_hash,
		"after_hash": after_hash,
		"before_state": before_state.duplicate(true),
		"after_state": after_state.duplicate(true),
		"message": _bounded_text(metadata.get("message", ""), MAX_NOTE_LENGTH),
		"style": _bounded_text(metadata.get("style", ""), 80),
		"evaluation": _bounded_text(metadata.get("evaluation", ""), 160),
		"source": _bounded_text(metadata.get("source", "reducer"), 48),
	}

	_redo_records.clear()
	_records.append(record)
	_total_plies += 1
	_current_snapshot = after_state.duplicate(true)
	_current_hash = after_hash
	while _records.size() > _max_records:
		var retired: Dictionary = _records.pop_front()
		_base_snapshot = Dictionary(retired.after_state).duplicate(true)
	_emit_changed()
	return {
		"ok": true,
		"code": "recorded",
		"record": record.duplicate(true),
		"state": _current_snapshot.duplicate(true),
		"state_hash": _current_hash,
	}


func can_undo() -> bool:
	return not _records.is_empty()


func can_redo() -> bool:
	return not _redo_records.is_empty()


func undo() -> Dictionary:
	if _records.is_empty():
		return _invalid("undo_unavailable", "No retained move can be undone.")
	var record: Dictionary = _records.pop_back()
	_redo_records.append(record)
	_current_snapshot = Dictionary(record.before_state).duplicate(true)
	_current_hash = str(record.get("before_hash", ""))
	_emit_changed()
	return {
		"ok": true,
		"code": "undone",
		"record": record.duplicate(true),
		"state": _current_snapshot.duplicate(true),
		"state_hash": _current_hash,
	}


func redo() -> Dictionary:
	if _redo_records.is_empty():
		return _invalid("redo_unavailable", "No undone move can be restored.")
	var record: Dictionary = _redo_records.pop_back()
	if not _same_position(_current_snapshot, Dictionary(record.before_state)):
		_redo_records.append(record)
		return _invalid("redo_conflict", "The current snapshot no longer matches the redo branch.")
	_records.append(record)
	_current_snapshot = Dictionary(record.after_state).duplicate(true)
	_current_hash = str(record.get("after_hash", ""))
	while _records.size() > _max_records:
		var retired: Dictionary = _records.pop_front()
		_base_snapshot = Dictionary(retired.after_state).duplicate(true)
	_emit_changed()
	return {
		"ok": true,
		"code": "redone",
		"record": record.duplicate(true),
		"state": _current_snapshot.duplicate(true),
		"state_hash": _current_hash,
	}


## Restores the exact position originally supplied to new_game(), and begins a
## clean authoritative timeline for another game with the same seats/options.
func restart() -> Dictionary:
	if _new_game_snapshot.is_empty():
		return _invalid("history_not_started", "There is no new-game snapshot to restore.")
	var state := _new_game_snapshot.duplicate(true)
	return new_game(state)


func current_snapshot() -> Dictionary:
	return _current_snapshot.duplicate(true)


func new_game_snapshot() -> Dictionary:
	return _new_game_snapshot.duplicate(true)


func retained_base_snapshot() -> Dictionary:
	return _base_snapshot.duplicate(true)


func records() -> Array[Dictionary]:
	return _records.duplicate(true)


func recent(limit: int = 16) -> Array[Dictionary]:
	var count := clampi(limit, 0, _records.size())
	return _records.slice(_records.size() - count, _records.size()).duplicate(true)


## Small LLM-safe history projection: full board snapshots never enter prompts.
func prompt_context(limit: int = 16) -> Array[Dictionary]:
	var compact: Array[Dictionary] = []
	for record in recent(limit):
		compact.append({
			"ply": int(record.get("ply", 0)),
			"side": str(record.get("side", "")),
			"uci": str(record.get("uci", "")),
			"algebraic": str(record.get("algebraic", "")),
			"message": _bounded_text(record.get("message", ""), 160),
		})
	return compact


func summary() -> Dictionary:
	return {
		"schema": SCHEMA,
		"initialized": not _current_snapshot.is_empty(),
		"retained_moves": _records.size(),
		"redo_moves": _redo_records.size(),
		"total_plies": _total_plies,
		"revision": int(_current_snapshot.get("revision", -1)),
		"state_hash": _current_hash,
		"can_undo": can_undo(),
		"can_redo": can_redo(),
	}


static func square_name(square: int) -> String:
	if square < 0 or square >= 64:
		return ""
	return FILES.substr(square % 8, 1) + str(8 - (square / 8))


static func uci_for_action(action: Dictionary) -> String:
	if not action.get("from", null) is int or not action.get("to", null) is int:
		return ""
	var origin := square_name(int(action.from))
	var destination := square_name(int(action.to))
	if origin.is_empty() or destination.is_empty():
		return ""
	var promotion := str(action.get("promotion", "")).strip_edges().to_lower()
	if not promotion.is_empty() and promotion not in ["q", "r", "b", "n"]:
		return ""
	return origin + destination + promotion


## Deterministic long algebraic notation.  It intentionally includes the origin
## square (for example Ng1-f3), avoiding SAN ambiguity without another legal-move
## probe.  UCI remains the machine action identifier.
static func algebraic_for_action(before_state: Dictionary, action: Dictionary, after_state: Dictionary = {}) -> String:
	var uci := uci_for_action(action)
	if uci.is_empty() or not before_state.get("board", null) is Array:
		return uci
	var from_square := int(action.from)
	var to_square := int(action.to)
	var board: Array = before_state.board
	if board.size() != 64:
		return uci
	var moving_piece := str(board[from_square])
	if moving_piece.length() != 2:
		return uci
	var kind := moving_piece.substr(1, 1)
	var label := ""
	if kind == "K" and absi((to_square % 8) - (from_square % 8)) == 2:
		label = "O-O" if to_square % 8 == 6 else "O-O-O"
	else:
		var target := str(board[to_square])
		var pawn_diagonal := kind == "P" and (from_square % 8) != (to_square % 8)
		var is_capture := not target.is_empty() or pawn_diagonal
		label = ("" if kind == "P" else kind) + square_name(from_square)
		label += "x" if is_capture else "-"
		label += square_name(to_square)
		var promotion := str(action.get("promotion", "")).strip_edges().to_upper()
		if not promotion.is_empty():
			label += "=" + promotion
	if not after_state.is_empty():
		if str(after_state.get("status", "")) == "won" and str(after_state.get("result", "")) == "checkmate":
			label += "#"
		elif bool(after_state.get("check", false)):
			label += "+"
	return label


static func describe_action(state: Dictionary, action: Dictionary) -> Dictionary:
	var from_square := int(action.get("from", -1))
	var piece_code := ""
	if state.get("board", null) is Array and from_square >= 0 and from_square < state.board.size():
		piece_code = str(state.board[from_square])
	var kind := piece_code.substr(1, 1) if piece_code.length() == 2 else ""
	return {
		"uci": uci_for_action(action),
		"algebraic": algebraic_for_action(state, action),
		"piece": PIECE_NAMES.get(kind, "Piece"),
		"from": square_name(from_square),
		"to": square_name(int(action.get("to", -1))),
	}


func _validate_state(state: Dictionary) -> Dictionary:
	if str(state.get("module_id", "")) != "chess_core":
		return _invalid("state_module", "History accepts only Chess Core state.")
	if not state.get("board", null) is Array or state.board.size() != 64:
		return _invalid("state_board", "Chess history requires exactly 64 board squares.")
	if not state.get("revision", null) is int:
		return _invalid("state_revision", "Chess history requires an integer reducer revision.")
	return {"ok": true, "code": "valid"}


func _validate_action(action: Dictionary) -> Dictionary:
	if str(action.get("type", "move")) != "move":
		return _invalid("action_type", "Chess history accepts only reducer move actions.")
	if not action.get("from", null) is int or not action.get("to", null) is int:
		return _invalid("action_squares", "Chess move squares must be integers.")
	if int(action.from) < 0 or int(action.from) >= 64 or int(action.to) < 0 or int(action.to) >= 64:
		return _invalid("action_range", "Chess move squares are outside the board.")
	return {"ok": true, "code": "valid"}


func _same_position(left: Dictionary, right: Dictionary) -> bool:
	return (
		int(left.get("revision", -1)) == int(right.get("revision", -2))
		and str(left.get("turn", "")) == str(right.get("turn", "#"))
		and left.get("board", []) == right.get("board", ["different"])
		and left.get("castling", {}) == right.get("castling", {"different": true})
		and int(left.get("en_passant", -2)) == int(right.get("en_passant", -3))
		and str(left.get("status", "")) == str(right.get("status", "#"))
	)


func _emit_changed() -> void:
	changed.emit(summary())


static func _bounded_text(value: Variant, maximum: int) -> String:
	var source := str(value)
	var clean := ""
	for index in range(source.length()):
		if source.unicode_at(index) != 0:
			clean += source.substr(index, 1)
	clean = clean.strip_edges()
	return clean.left(maximum)


static func _invalid(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
