extends Node

const ScenarioDriverScript := preload("res://addons/agentic_godot_validation/runtime/drivers/scenario_driver.gd")
const RuntimeInspectorScript := preload("res://addons/agentic_godot_validation/runtime/inspector/runtime_inspector.gd")
const ScenarioVerifierScript := preload("res://addons/agentic_godot_validation/runtime/verifiers/scenario_verifier.gd")

const DEFAULT_SCENARIO_PATH := "res://validation/scenarios/move_up_smoke.json"
const DEFAULT_SCENARIO_FALLBACK_PATH := "res://examples/minimal_poc/validation/scenarios/move_up_smoke.json"
const DEFAULT_ARTIFACTS_DIR := "user://artifacts/dev"
const FIXED_RANDOM_SEED := 4601
const FIXED_WINDOW_SIZE := Vector2i(1280, 720)
const FIXED_PHYSICS_TPS := 60

const EXIT_PASS := 0
const EXIT_ASSERTION_FAILURE := 1
const EXIT_RUNTIME_ERROR := 2
const EXIT_TIMEOUT := 3
const EXIT_ARTIFACT_GENERATION_ERROR := 4

var scenario_path: String = ""
var artifacts_dir: String = DEFAULT_ARTIFACTS_DIR
var scenario_contract: Dictionary = {}
var runtime_inspector: Node
var scenario_driver: Node
var scenario_verifier: RefCounted
var timeout_timer: Timer
var did_finish: bool = false

func _ready() -> void:
	var cli: Dictionary = _parse_cli_args(OS.get_cmdline_user_args())
	scenario_path = str(cli.get("scenario_path", _resolve_default_scenario_path()))
	artifacts_dir = _globalize_path(str(cli.get("artifacts_dir", DEFAULT_ARTIFACTS_DIR)))

	_apply_deterministic_settings()

	if not _ensure_artifacts_dir(artifacts_dir):
		_finish_without_inspector(EXIT_ARTIFACT_GENERATION_ERROR, "artifact_generation_error", "Unable to create artifacts directory: %s" % artifacts_dir)
		return

	scenario_contract = _load_json_dictionary(scenario_path)
	if scenario_contract.is_empty():
		_finish_without_inspector(EXIT_RUNTIME_ERROR, "runtime_error", "Unable to load scenario contract: %s" % scenario_path)
		return

	runtime_inspector = RuntimeInspectorScript.new()
	add_child(runtime_inspector)
	if not runtime_inspector.configure({
		"artifacts_dir": artifacts_dir,
		"scenario_path": scenario_path,
		"scenario_contract": scenario_contract,
	}):
		_finish_without_inspector(EXIT_ARTIFACT_GENERATION_ERROR, "artifact_generation_error", "Runtime inspector could not initialize artifacts under: %s" % artifacts_dir)
		return

	scenario_verifier = ScenarioVerifierScript.new()
	scenario_driver = ScenarioDriverScript.new()
	add_child(scenario_driver)

	timeout_timer = Timer.new()
	timeout_timer.one_shot = true
	timeout_timer.timeout.connect(_on_timeout)
	add_child(timeout_timer)

	var timeout_seconds: float = _derive_timeout_seconds(scenario_contract)
	runtime_inspector.record_event("timeout_scheduled", {
		"timeout_seconds": timeout_seconds,
	}, 0)
	timeout_timer.start(timeout_seconds)

	var scenario_result: Dictionary = await scenario_driver.run_scenario(scenario_contract, runtime_inspector, scenario_verifier)
	if did_finish:
		return

	timeout_timer.stop()
	_complete_scenario_run(scenario_result)

func _parse_cli_args(user_args: PackedStringArray) -> Dictionary:
	var parsed: Dictionary = {
		"scenario_path": _resolve_default_scenario_path(),
		"artifacts_dir": DEFAULT_ARTIFACTS_DIR,
	}
	var index: int = 0

	while index < user_args.size():
		var argument: String = user_args[index]
		match argument:
			"--scenario":
				index += 1
				if index < user_args.size():
					parsed["scenario_path"] = user_args[index]
			"--artifacts":
				index += 1
				if index < user_args.size():
					parsed["artifacts_dir"] = user_args[index]
		index += 1

	return parsed

func _resolve_default_scenario_path() -> String:
	if FileAccess.file_exists(DEFAULT_SCENARIO_PATH):
		return DEFAULT_SCENARIO_PATH
	if FileAccess.file_exists(DEFAULT_SCENARIO_FALLBACK_PATH):
		return DEFAULT_SCENARIO_FALLBACK_PATH
	return DEFAULT_SCENARIO_PATH

func _apply_deterministic_settings() -> void:
	seed(FIXED_RANDOM_SEED)
	Engine.physics_ticks_per_second = FIXED_PHYSICS_TPS
	Engine.max_fps = FIXED_PHYSICS_TPS

	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(FIXED_WINDOW_SIZE)

	var master_bus_index: int = AudioServer.get_bus_index("Master")
	if master_bus_index >= 0:
		AudioServer.set_bus_mute(master_bus_index, true)

func _ensure_artifacts_dir(path: String) -> bool:
	var absolute_path: String = _globalize_path(path)
	return DirAccess.make_dir_recursive_absolute(absolute_path) == OK

func _globalize_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	if path.contains(":\\") or path.contains(":/") or path.begins_with("/"):
		return path
	return ProjectSettings.globalize_path("res://%s" % path)

func _load_json_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("Scenario file does not exist: %s" % path)
		return {}

	var scenario_file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if scenario_file == null:
		push_error("Scenario file could not be opened: %s" % path)
		return {}

	var parsed_json: Variant = JSON.parse_string(scenario_file.get_as_text())
	if typeof(parsed_json) != TYPE_DICTIONARY:
		push_error("Scenario file must contain a JSON object: %s" % path)
		return {}

	var parsed_dictionary: Dictionary = parsed_json
	return parsed_dictionary

func _derive_timeout_seconds(contract: Dictionary) -> float:
	var wait_frames: int = 0
	var steps_variant: Variant = contract.get("steps", [])
	if steps_variant is Array:
		for step_variant in steps_variant:
			if step_variant is Dictionary and str(step_variant.get("op", "")) == "wait_frames":
				wait_frames += int(step_variant.get("frames", 0))

	var done_contract: Dictionary = contract.get("done_contract", {})
	var frame_budget: int = int(done_contract.get("frame_budget", FIXED_PHYSICS_TPS))
	var relevant_frames: int = maxi(wait_frames, frame_budget)
	return maxf(5.0, (float(relevant_frames) / float(FIXED_PHYSICS_TPS)) + 3.0)

func _on_timeout() -> void:
	if did_finish:
		return

	if scenario_driver != null:
		scenario_driver.request_stop()

	if runtime_inspector != null:
		runtime_inspector.record_error("Scenario timed out before completion.", _get_current_physics_frame())

	_complete_scenario_run({
		"status": "timeout",
		"exit_code": EXIT_TIMEOUT,
		"message": "Scenario timed out before completion.",
		"physics_frames": _get_current_physics_frame(),
	})

func _complete_scenario_run(result: Dictionary) -> void:
	if did_finish:
		return

	did_finish = true

	var provisional_result: Dictionary = result.duplicate(true)
	if not provisional_result.has("status"):
		provisional_result["status"] = _status_for_exit_code(int(provisional_result.get("exit_code", EXIT_RUNTIME_ERROR)))
	if not provisional_result.has("exit_code"):
		provisional_result["exit_code"] = EXIT_RUNTIME_ERROR
	if not provisional_result.has("message"):
		provisional_result["message"] = "Scenario finished."

	if runtime_inspector != null:
		runtime_inspector.finalize(provisional_result)
		var final_result: Dictionary = scenario_verifier.finalize_run(scenario_contract, runtime_inspector, provisional_result)
		runtime_inspector.finalize(final_result)
		get_tree().quit(int(final_result.get("exit_code", EXIT_RUNTIME_ERROR)))
		return

	_finish_without_inspector(int(provisional_result.get("exit_code", EXIT_RUNTIME_ERROR)), str(provisional_result.get("status", "runtime_error")), str(provisional_result.get("message", "Scenario finished.")))

func _finish_without_inspector(exit_code: int, status: String, message: String) -> void:
	did_finish = true
	push_error("[%s] %s" % [status, message])
	get_tree().quit(exit_code)

func _status_for_exit_code(exit_code: int) -> String:
	match exit_code:
		EXIT_PASS:
			return "pass"
		EXIT_ASSERTION_FAILURE:
			return "assertion_failure"
		EXIT_RUNTIME_ERROR:
			return "runtime_error"
		EXIT_TIMEOUT:
			return "timeout"
		EXIT_ARTIFACT_GENERATION_ERROR:
			return "artifact_generation_error"
		_:
			return "runtime_error"

func _get_current_physics_frame() -> int:
	if scenario_driver != null and scenario_driver.has_method("get_current_physics_frame"):
		return int(scenario_driver.get_current_physics_frame())
	return 0

