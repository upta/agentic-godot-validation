extends Node2D

const HarnessStateHelpers := preload("res://addons/agentic_godot_validation/runtime/support/harness_state_helpers.gd")
const SignalProbe := preload("res://addons/agentic_godot_validation/runtime/support/signal_probe.gd")

@export var actor_path: NodePath = NodePath("PlayerActor")
@export var spawn_point_path: NodePath = NodePath("SpawnPoint")
@export var menu_path: NodePath = NodePath("PauseMenu")

@onready var actor: Node = get_node(actor_path)
@onready var spawn_point: Marker2D = get_node(spawn_point_path)
@onready var menu: Control = get_node(menu_path)

var signal_probe: RefCounted = SignalProbe.new()
var modal_input_block_active: bool = false

func _ready() -> void:
	if not actor.has_method("reset_to_spawn") or not actor.has_method("get_world_position"):
		push_error("Modal pause movement harness actor must expose reset_to_spawn() and get_world_position().")
		return

	var resume_button: Control = _get_resume_button()
	signal_probe.track_signal(menu, "menu_opened", "pause_menu")
	signal_probe.track_signal(menu, "menu_closed", "pause_menu")
	signal_probe.track_signal(menu, "resume_requested", "pause_menu")
	signal_probe.track_signal(resume_button, "focus_entered", "resume_button")
	signal_probe.track_signal(resume_button, "pressed", "resume_button")

	var menu_opened_handler: Callable = Callable(self, "_on_menu_opened")
	if not menu.is_connected("menu_opened", menu_opened_handler):
		menu.connect("menu_opened", menu_opened_handler)

	var menu_closed_handler: Callable = Callable(self, "_on_menu_closed")
	if not menu.is_connected("menu_closed", menu_closed_handler):
		menu.connect("menu_closed", menu_closed_handler)

	reset_harness()

func reset_harness() -> void:
	modal_input_block_active = false
	actor.set_physics_process(true)
	actor.call("reset_to_spawn", spawn_point.global_position)
	if menu.has_method("reset_menu"):
		menu.call("reset_menu")

func get_actor_position() -> Vector2:
	return actor.call("get_world_position")

func get_spawn_position() -> Vector2:
	return spawn_point.global_position

func get_actor_displacement_from_spawn() -> Vector2:
	return get_actor_position() - get_spawn_position()

func get_actor_upward_displacement() -> float:
	return get_spawn_position().y - get_actor_position().y

func get_observed_state() -> Dictionary:
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	var resume_button: Control = _get_resume_button()
	return {
		"harness_path": str(get_path()),
		"actor_path": str(actor.get_path()),
		"spawn_point_path": str(spawn_point.get_path()),
		"menu_path": str(menu.get_path()),
		"resume_button_path": _get_resume_button_path(),
		"spawn_position": get_spawn_position(),
		"actor_position": get_actor_position(),
		"actor_displacement_from_spawn": get_actor_displacement_from_spawn(),
		"actor_upward_displacement": get_actor_upward_displacement(),
		"menu_visible": menu.visible,
		"modal_input_block_active": modal_input_block_active,
		"focused_control_path": "" if focus_owner == null else str(focus_owner.get_path()),
		"signals": signal_probe.get_signal_facts(),
		"metrics": {
			"actor_displacement_from_spawn": get_actor_displacement_from_spawn(),
			"actor_upward_displacement": get_actor_upward_displacement(),
		},
		"nodes": HarnessStateHelpers.build_named_node_facts({
			"actor": actor,
			"spawn_point": spawn_point,
			"pause_menu": menu,
			"resume_button": resume_button,
		}),
	}

func _get_resume_button_path() -> String:
	if menu.has_method("get_resume_button_path"):
		return str(menu.call("get_resume_button_path"))
	return ""

func _get_resume_button() -> Control:
	var resume_button_path: String = _get_resume_button_path()
	if resume_button_path.is_empty():
		return null
	return get_node_or_null(NodePath(resume_button_path))

func _on_menu_opened() -> void:
	modal_input_block_active = true
	actor.set_physics_process(false)

func _on_menu_closed() -> void:
	modal_input_block_active = false
	actor.set_physics_process(true)
