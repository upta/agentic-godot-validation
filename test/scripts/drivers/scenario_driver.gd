extends Node

var current_physics_frame: int = 0
var loaded_harness: Node
var stop_requested: bool = false
var pressed_actions: Dictionary = {}
var verification_results: Array = []
var inspector: Node
var verifier: RefCounted
var contract: Dictionary = {}

func run_scenario(scenario_contract: Dictionary, runtime_inspector: Node, scenario_verifier: RefCounted) -> Dictionary:
	contract = scenario_contract
	inspector = runtime_inspector
	verifier = scenario_verifier
	current_physics_frame = 0
	stop_requested = false
	pressed_actions.clear()
	verification_results.clear()
	loaded_harness = null

	var steps_variant: Variant = contract.get("steps", [])
	if not (steps_variant is Array) or steps_variant.is_empty():
		inspector.record_error("Scenario contract did not define any executable steps.", current_physics_frame)
		return _stop_with_result("runtime_error", 2, "Scenario contract did not define any executable steps.")

	inspector.record_event("scenario_started", {
		"scenario_id": str(contract.get("scenario_id", "unknown")),
		"step_count": steps_variant.size(),
	}, current_physics_frame)

	for index in range(steps_variant.size()):
		if stop_requested:
			_release_all_actions()
			return _stop_with_result("timeout", 3, "Scenario execution was stopped before completion.")

		var step_variant: Variant = steps_variant[index]
		if not (step_variant is Dictionary):
			inspector.record_error("Scenario step %d was not a JSON object." % index, current_physics_frame)
			_release_all_actions()
			return _stop_with_result("runtime_error", 2, "Scenario step %d was not a JSON object." % index)

		var step: Dictionary = step_variant
		var step_result: Dictionary = await _execute_step(step, index)
		if bool(step_result.get("should_stop", false)):
			_release_all_actions()
			return step_result

	_release_all_actions()
	return _stop_with_result("pass", 0, "Scenario completed successfully.")

func request_stop() -> void:
	stop_requested = true

func get_current_physics_frame() -> int:
	return current_physics_frame

func _execute_step(step: Dictionary, step_index: int) -> Dictionary:
	var op: String = str(step.get("op", ""))
	inspector.record_event("step_started", {
		"step_index": step_index,
		"op": op,
		"step": step,
	}, current_physics_frame)

	match op:
		"load_harness":
			var load_result: Dictionary = await _step_load_harness(step)
			return _complete_step(step_index, op, load_result)
		"checkpoint":
			var checkpoint_result: Dictionary = await _step_checkpoint(step)
			return _complete_step(step_index, op, checkpoint_result)
		"press_action":
			var press_result: Dictionary = _step_press_action(step)
			return _complete_step(step_index, op, press_result)
		"release_action":
			var release_result: Dictionary = _step_release_action(step)
			return _complete_step(step_index, op, release_result)
		"wait_frames":
			var wait_result: Dictionary = await _step_wait_frames(step)
			return _complete_step(step_index, op, wait_result)
		"assert_pipeline":
			var pipeline_assertion_result: Dictionary = _step_assert_pipeline(step, step_index)
			return _complete_step(step_index, op, pipeline_assertion_result)
		"assert_value":
			var value_assertion_result: Dictionary = _step_assert_value(step, step_index)
			return _complete_step(step_index, op, value_assertion_result)
		"quit":
			return _complete_step(step_index, op, _stop_with_result("pass", 0, "Scenario completed successfully."))
		_:
			inspector.record_error("Unknown scenario operation: %s" % op, current_physics_frame)
			return _complete_step(step_index, op, _stop_with_result("runtime_error", 2, "Unknown scenario operation: %s" % op))

func _complete_step(step_index: int, op: String, result: Dictionary) -> Dictionary:
	inspector.record_event("step_completed", {
		"step_index": step_index,
		"op": op,
		"status": str(result.get("status", "ok")),
		"message": str(result.get("message", "")),
	}, current_physics_frame)
	return result

func _step_load_harness(step: Dictionary) -> Dictionary:
	var harness_scene_path: String = str(step.get("scene", contract.get("harness_scene", "")))
	if harness_scene_path.is_empty():
		inspector.record_error("load_harness step is missing a scene path.", current_physics_frame)
		return _stop_with_result("runtime_error", 2, "load_harness step is missing a scene path.")

	var packed_scene: PackedScene = load(harness_scene_path) as PackedScene
	if packed_scene == null:
		inspector.record_error("Harness scene could not be loaded: %s" % harness_scene_path, current_physics_frame)
		return _stop_with_result("runtime_error", 2, "Harness scene could not be loaded: %s" % harness_scene_path)

	if loaded_harness != null and is_instance_valid(loaded_harness):
		loaded_harness.queue_free()
		await get_tree().process_frame

	loaded_harness = packed_scene.instantiate()
	get_parent().add_child(loaded_harness)

	if loaded_harness.has_method("reset_harness"):
		loaded_harness.call("reset_harness")

	return {
		"status": "ok",
		"message": "Harness loaded.",
		"loaded_harness_path": str(loaded_harness.get_path()),
		"should_stop": false,
	}

func _step_checkpoint(step: Dictionary) -> Dictionary:
	if loaded_harness == null or not is_instance_valid(loaded_harness):
		inspector.record_error("checkpoint step requires a loaded harness.", current_physics_frame)
		return _stop_with_result("runtime_error", 2, "checkpoint step requires a loaded harness.")

	var checkpoint_name: String = str(step.get("name", ""))
	if checkpoint_name.is_empty():
		inspector.record_error("checkpoint step requires a name.", current_physics_frame)
		return _stop_with_result("runtime_error", 2, "checkpoint step requires a name.")

	await inspector.capture_checkpoint(checkpoint_name, loaded_harness, current_physics_frame)
	return {
		"status": "ok",
		"message": "Checkpoint captured: %s" % checkpoint_name,
		"checkpoint": checkpoint_name,
		"should_stop": false,
	}

func _step_press_action(step: Dictionary) -> Dictionary:
	var action_name: String = str(step.get("action", ""))
	if action_name.is_empty() or not InputMap.has_action(action_name):
		inspector.record_error("press_action step referenced unknown action: %s" % action_name, current_physics_frame)
		return _stop_with_result("runtime_error", 2, "press_action step referenced unknown action: %s" % action_name)

	_dispatch_action_event(action_name, true)
	Input.action_press(action_name)
	pressed_actions[action_name] = true
	return {
		"status": "ok",
		"message": "Pressed action %s." % action_name,
		"action": action_name,
		"should_stop": false,
	}

func _step_release_action(step: Dictionary) -> Dictionary:
	var action_name: String = str(step.get("action", ""))
	if action_name.is_empty() or not InputMap.has_action(action_name):
		inspector.record_error("release_action step referenced unknown action: %s" % action_name, current_physics_frame)
		return _stop_with_result("runtime_error", 2, "release_action step referenced unknown action: %s" % action_name)

	_dispatch_action_event(action_name, false)
	Input.action_release(action_name)
	pressed_actions.erase(action_name)
	return {
		"status": "ok",
		"message": "Released action %s." % action_name,
		"action": action_name,
		"should_stop": false,
	}

func _step_wait_frames(step: Dictionary) -> Dictionary:
	var frame_count: int = int(step.get("frames", 0))
	if frame_count < 0:
		inspector.record_error("wait_frames step requires a non-negative frame count.", current_physics_frame)
		return _stop_with_result("runtime_error", 2, "wait_frames step requires a non-negative frame count.")

	for _frame_index in range(frame_count):
		if stop_requested:
			return _stop_with_result("timeout", 3, "Scenario execution was stopped during wait_frames.")
		await get_tree().physics_frame
		current_physics_frame += 1

	return {
		"status": "ok",
		"message": "Waited %d physics frames." % frame_count,
		"frames": frame_count,
		"should_stop": false,
	}

func _step_assert_pipeline(step: Dictionary, step_index: int) -> Dictionary:
	var verification: Dictionary = verifier.verify_pipeline(contract, inspector.get_checkpoints(), step)
	return _build_assertion_step_result(verification, step_index, step, "Pipeline assertion failed.", "Pipeline assertion passed.")

func _step_assert_value(step: Dictionary, step_index: int) -> Dictionary:
	var verification: Dictionary = verifier.verify_value(inspector.get_checkpoints(), step)
	return _build_assertion_step_result(verification, step_index, step, "Value assertion failed.", "Value assertion passed.")

func _build_assertion_step_result(verification: Dictionary, step_index: int, step: Dictionary, default_failure_message: String, default_success_message: String) -> Dictionary:
	var enriched_verification: Dictionary = verification.duplicate(true)
	enriched_verification["step_index"] = step_index
	enriched_verification["step_op"] = str(step.get("op", ""))
	enriched_verification["step"] = step.duplicate(true)

	verification_results.append(enriched_verification.duplicate(true))
	if not bool(enriched_verification.get("passed", false)):
		var failure_message: String = str(enriched_verification.get("message", default_failure_message))
		var failure_status: String = str(enriched_verification.get("status", "assertion_failure"))
		var failure_exit_code: int = int(enriched_verification.get("exit_code", 1))
		inspector.record_error(failure_message, current_physics_frame)
		return {
			"status": failure_status,
			"exit_code": failure_exit_code,
			"message": failure_message,
			"verification": enriched_verification,
			"should_stop": true,
		}

	return {
		"status": "ok",
		"message": str(enriched_verification.get("message", default_success_message)),
		"verification": enriched_verification,
		"should_stop": false,
	}

func _release_all_actions() -> void:
	for action_name in pressed_actions.keys():
		_dispatch_action_event(str(action_name), false)
		Input.action_release(str(action_name))
	pressed_actions.clear()

func _dispatch_action_event(action_name: String, pressed: bool) -> void:
	var action_event: InputEventAction = InputEventAction.new()
	action_event.action = action_name
	action_event.pressed = pressed
	Input.parse_input_event(action_event)

func _stop_with_result(status: String, exit_code: int, message: String) -> Dictionary:
	var result: Dictionary = {
		"status": status,
		"exit_code": exit_code,
		"message": message,
		"physics_frames": current_physics_frame,
		"loaded_harness_path": "" if loaded_harness == null else str(loaded_harness.get_path()),
		"should_stop": true,
	}
	if not verification_results.is_empty():
		result["verifications"] = verification_results.duplicate(true)
		result["verification"] = verification_results[verification_results.size() - 1]
	return result
