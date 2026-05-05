extends Control

signal menu_opened
signal menu_closed
signal resume_requested

@export var resume_button_path: NodePath = NodePath("Panel/ResumeButton")

@onready var resume_button: Button = get_node(resume_button_path)

func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_physics_process(true)
	if not resume_button.pressed.is_connected(_on_resume_button_pressed):
		resume_button.pressed.connect(_on_resume_button_pressed)

func _physics_process(_delta: float) -> void:
	if not visible and Input.is_action_pressed("pause"):
		open_menu()
	elif visible and resume_button.has_focus() and Input.is_action_pressed("ui_accept"):
		request_resume()

func open_menu() -> void:
	if visible:
		return
	visible = true
	resume_button.grab_focus()
	emit_signal("menu_opened")

func close_menu() -> void:
	if not visible:
		return
	visible = false
	resume_button.release_focus()
	emit_signal("menu_closed")

func request_resume() -> void:
	if not visible:
		return
	emit_signal("resume_requested")
	close_menu()

func reset_menu() -> void:
	visible = false
	resume_button.release_focus()

func is_menu_open() -> bool:
	return visible

func get_resume_button_path() -> String:
	return str(resume_button.get_path())

func _on_resume_button_pressed() -> void:
	request_resume()
