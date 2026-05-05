extends Node

@export_file("*.tscn") var production_scene_path: String = "res://game/scenes/main.tscn"
@export_file("*.tscn") var test_scene_path: String = "res://addons/agentic_godot_validation/runtime/scenes/test_bootstrap.tscn"
@export var action_keys: Dictionary = {
	"move_up": KEY_W,
	"move_down": KEY_S,
	"move_left": KEY_A,
	"move_right": KEY_D,
	"pause": KEY_ESCAPE,
	"ui_accept": KEY_ENTER,
}

func _ready() -> void:
	_ensure_input_actions()
	var next_scene_path: String = test_scene_path if _is_test_mode() else production_scene_path
	var packed_scene: PackedScene = load(next_scene_path) as PackedScene
	if packed_scene == null:
		push_error("Validation router could not load scene: %s" % next_scene_path)
		return
	add_child(packed_scene.instantiate())

func _is_test_mode() -> bool:
	return OS.get_cmdline_user_args().has("--test-mode")

func _ensure_input_actions() -> void:
	for action_name_variant in action_keys.keys():
		var action_name: String = str(action_name_variant)
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)

		var input_event: InputEventKey = _build_key_event(int(action_keys[action_name_variant]))
		if not InputMap.action_has_event(action_name, input_event):
			InputMap.action_add_event(action_name, input_event)

func _build_key_event(keycode: int) -> InputEventKey:
	var input_event: InputEventKey = InputEventKey.new()
	input_event.physical_keycode = keycode
	return input_event
