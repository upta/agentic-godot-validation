extends Node

const PRODUCTION_SCENE := preload("res://game/scenes/main.tscn")
const TEST_SCENE := preload("res://test/bootstrap/test_bootstrap.tscn")
const ACTION_KEYS := {
	"move_up": KEY_W,
	"move_down": KEY_S,
	"move_left": KEY_A,
	"move_right": KEY_D,
	"pause": KEY_ESCAPE,
	"ui_accept": KEY_ENTER,
}

func _ready() -> void:
	_ensure_input_actions()
	var next_scene: PackedScene = TEST_SCENE if _is_test_mode() else PRODUCTION_SCENE
	add_child(next_scene.instantiate())

func _is_test_mode() -> bool:
	return OS.get_cmdline_user_args().has("--test-mode")

func _ensure_input_actions() -> void:
	for action_name in ACTION_KEYS.keys():
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)

		var input_event := _build_key_event(ACTION_KEYS[action_name])
		if not InputMap.action_has_event(action_name, input_event):
			InputMap.action_add_event(action_name, input_event)

func _build_key_event(keycode: int) -> InputEventKey:
	var input_event := InputEventKey.new()
	input_event.physical_keycode = keycode
	return input_event
