extends Node2D
class_name PlayerActor

@export var movement_speed: float = 240.0

var _spawn_position: Vector2

func _ready() -> void:
	_spawn_position = global_position

func _physics_process(delta: float) -> void:
	var movement := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
	)

	if movement.length_squared() == 0.0:
		return

	if movement.length_squared() > 1.0:
		movement = movement.normalized()

	global_position += movement * movement_speed * delta

func reset_to_spawn(spawn_position: Vector2 = _spawn_position) -> void:
	global_position = spawn_position

func get_world_position() -> Vector2:
	return global_position
