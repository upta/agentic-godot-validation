extends Node

const HarnessStateHelpers := preload("res://test/scripts/harness_support/harness_state_helpers.gd")
const SignalProbe := preload("res://test/scripts/harness_support/signal_probe.gd")

@export var menu_path: NodePath = NodePath("PauseMenu")

@onready var menu: Control = get_node(menu_path)

var signal_probe: RefCounted = SignalProbe.new()

func _ready() -> void:
	var resume_button: Control = _get_resume_button()
	signal_probe.track_signal(menu, "menu_opened", "pause_menu")
	signal_probe.track_signal(menu, "menu_closed", "pause_menu")
	signal_probe.track_signal(menu, "resume_requested", "pause_menu")
	signal_probe.track_signal(resume_button, "focus_entered", "resume_button")
	signal_probe.track_signal(resume_button, "pressed", "resume_button")
	reset_harness()

func reset_harness() -> void:
	if menu.has_method("reset_menu"):
		menu.call("reset_menu")

func get_observed_state() -> Dictionary:
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	var resume_button: Control = _get_resume_button()
	return {
		"harness_path": str(get_path()),
		"menu_path": str(menu.get_path()),
		"menu_visible": menu.visible,
		"resume_button_path": _get_resume_button_path(),
		"focused_control_path": "" if focus_owner == null else str(focus_owner.get_path()),
		"signals": signal_probe.get_signal_facts(),
		"nodes": HarnessStateHelpers.build_named_node_facts({
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
