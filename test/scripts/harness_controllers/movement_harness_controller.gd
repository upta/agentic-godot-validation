extends Node2D

const HarnessStateHelpers := preload("res://test/scripts/harness_support/harness_state_helpers.gd")

@export var actor_path: NodePath = NodePath("PlayerActor")
@export var spawn_point_path: NodePath = NodePath("SpawnPoint")

@onready var actor: Node = get_node(actor_path)
@onready var spawn_point: Marker2D = get_node(spawn_point_path)

func _ready() -> void:
	if not actor.has_method("reset_to_spawn") or not actor.has_method("get_world_position"):
		push_error("Movement harness actor must expose reset_to_spawn() and get_world_position().")
		return

	reset_harness()

func reset_harness() -> void:
	actor.call("reset_to_spawn", spawn_point.global_position)

func get_actor_position() -> Vector2:
	return actor.call("get_world_position")

func get_spawn_position() -> Vector2:
	return spawn_point.global_position

func get_actor_displacement_from_spawn() -> Vector2:
	return get_actor_position() - get_spawn_position()

func get_actor_upward_displacement() -> float:
	return get_spawn_position().y - get_actor_position().y

func get_observed_state() -> Dictionary:
	return {
		"harness_path": str(get_path()),
		"actor_path": str(actor.get_path()),
		"spawn_point_path": str(spawn_point.get_path()),
		"spawn_position": get_spawn_position(),
		"actor_position": actor.call("get_world_position"),
		"actor_displacement_from_spawn": get_actor_displacement_from_spawn(),
		"actor_upward_displacement": get_actor_upward_displacement(),
		"signals": {},
		"metrics": {
			"actor_displacement_from_spawn": get_actor_displacement_from_spawn(),
			"actor_upward_displacement": get_actor_upward_displacement(),
		},
		"nodes": HarnessStateHelpers.build_named_node_facts({
			"actor": actor,
			"spawn_point": spawn_point,
		}),
	}
