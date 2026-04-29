extends Node

var artifacts_dir: String = ""
var scenario_path: String = ""
var scenario_contract: Dictionary = {}
var event_log: Array = []
var checkpoints: Dictionary = {}
var scene_tree_snapshots: Dictionary = {}
var warnings: Array = []
var errors: Array = []
var started_unix_time: int = 0
var started_ticks_msec: int = 0

func configure(config: Dictionary) -> bool:
	artifacts_dir = str(config.get("artifacts_dir", ""))
	scenario_path = str(config.get("scenario_path", ""))
	scenario_contract = config.get("scenario_contract", {})
	started_unix_time = int(Time.get_unix_time_from_system())
	started_ticks_msec = Time.get_ticks_msec()

	if not _ensure_directory(artifacts_dir):
		push_error("Unable to create artifacts directory: %s" % artifacts_dir)
		return false

	if not _ensure_directory(_join_artifact_path("screenshots")):
		push_error("Unable to create screenshots directory under: %s" % artifacts_dir)
		return false

	record_event("inspector_configured", {
		"artifacts_dir": artifacts_dir,
		"scenario_path": scenario_path,
		"scenario_id": str(scenario_contract.get("scenario_id", "unknown")),
	}, 0)
	return true

func record_event(event_type: String, details: Dictionary = {}, physics_frame: int = 0) -> void:
	event_log.append({
		"event": event_type,
		"physics_frame": physics_frame,
		"relative_time_msec": Time.get_ticks_msec() - started_ticks_msec,
		"details": details.duplicate(true),
	})

func record_warning(message: String, physics_frame: int = 0) -> void:
	warnings.append(message)
	record_event("warning", {"message": message}, physics_frame)

func record_error(message: String, physics_frame: int = 0) -> void:
	errors.append(message)
	record_event("error", {"message": message}, physics_frame)

func capture_checkpoint(checkpoint_name: String, harness: Node, physics_frame: int) -> Dictionary:
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw

	var checkpoint_summary: Dictionary = _build_checkpoint_summary(checkpoint_name, harness, physics_frame)
	var screenshot_relative_path: String = "screenshots/%s.png" % checkpoint_name
	var screenshot_saved: bool = await _save_viewport_screenshot(screenshot_relative_path)
	checkpoint_summary["screenshot_relative_path"] = screenshot_relative_path
	checkpoint_summary["screenshot_saved"] = screenshot_saved

	checkpoints[checkpoint_name] = checkpoint_summary
	scene_tree_snapshots[checkpoint_name] = _snapshot_node(get_tree().root)

	record_event("checkpoint_captured", {
		"name": checkpoint_name,
		"screenshot_saved": screenshot_saved,
	}, physics_frame)

	_write_event_log()
	_write_scene_tree()
	_write_summary({
		"status": "running",
		"exit_code": null,
		"message": "Checkpoint captured: %s" % checkpoint_name,
	})

	return checkpoint_summary

func finalize(result: Dictionary) -> Dictionary:
	scene_tree_snapshots["final"] = _snapshot_node(get_tree().root)
	_write_event_log()
	_write_scene_tree()
	_write_summary(result)
	return result

func get_checkpoints() -> Dictionary:
	return checkpoints.duplicate(true)

func get_errors() -> Array:
	return errors.duplicate(true)

func get_warnings() -> Array:
	return warnings.duplicate(true)

func collect_artifact_presence() -> Dictionary:
	var artifact_contract: Dictionary = scenario_contract.get("artifact_contract", {})
	var required_variant: Variant = artifact_contract.get("required_files", [])
	var required_files: Array = []
	var existing_files: Array = []
	var missing_files: Array = []

	if required_variant is Array:
		required_files = required_variant.duplicate(true)

	for required_file_variant in required_files:
		var required_file: String = str(required_file_variant)
		if FileAccess.file_exists(_join_artifact_path(required_file)):
			existing_files.append(required_file)
		else:
			missing_files.append(required_file)

	return {
		"required": required_files,
		"existing": existing_files,
		"missing": missing_files,
	}

func _build_checkpoint_summary(checkpoint_name: String, harness: Node, physics_frame: int) -> Dictionary:
	var harness_state: Dictionary = {}
	if harness != null and is_instance_valid(harness) and harness.has_method("get_observed_state"):
		var harness_state_variant: Variant = harness.call("get_observed_state")
		if harness_state_variant is Dictionary:
			harness_state = harness_state_variant.duplicate(true)

	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	var tracked_nodes: Array = []
	tracked_nodes.append(_build_node_state(harness))

	var actor_relative_path: String = str(scenario_contract.get("done_contract", {}).get("controlled_actor_relative_path", ""))
	if harness != null and is_instance_valid(harness) and not actor_relative_path.is_empty():
		tracked_nodes.append(_build_node_state(harness.get_node_or_null(NodePath(actor_relative_path))))

	return {
		"name": checkpoint_name,
		"physics_frame": physics_frame,
		"current_scene_path": _node_path_or_empty(get_tree().current_scene),
		"current_scene_name": "" if get_tree().current_scene == null else str(get_tree().current_scene.name),
		"focused_control_path": _node_path_or_empty(focus_owner),
		"tracked_node_paths": _tracked_node_paths(tracked_nodes),
		"tracked_nodes": tracked_nodes,
		"harness_state": harness_state,
		"warning_count": warnings.size(),
		"error_count": errors.size(),
	}

func _tracked_node_paths(tracked_nodes: Array) -> Array:
	var paths: Array = []
	for tracked_node_variant in tracked_nodes:
		if tracked_node_variant is Dictionary:
			var tracked_node: Dictionary = tracked_node_variant
			if tracked_node.has("path"):
				paths.append(str(tracked_node.get("path", "")))
	return paths

func _build_node_state(node: Node) -> Dictionary:
	if node == null:
		return {
			"exists": false,
			"path": "",
		}

	var node_state: Dictionary = {
		"exists": true,
		"path": str(node.get_path()),
		"type": node.get_class(),
		"name": str(node.name),
	}

	if node is CanvasItem:
		node_state["visible_in_tree"] = node.is_visible_in_tree()

	if node is Node2D:
		node_state["global_position"] = node.global_position

	if node is Control:
		node_state["has_focus"] = node.has_focus()

	return node_state

func _snapshot_node(node: Node) -> Dictionary:
	var snapshot: Dictionary = {
		"name": str(node.name),
		"type": node.get_class(),
		"path": str(node.get_path()),
		"children": [],
	}

	if node is CanvasItem:
		snapshot["visible_in_tree"] = node.is_visible_in_tree()

	if node is Node2D:
		snapshot["global_position"] = node.global_position

	for child in node.get_children():
		if child is Node:
			snapshot["children"].append(_snapshot_node(child))

	return snapshot

func _write_event_log() -> bool:
	return _write_json("event_log.json", {
		"scenario_id": str(scenario_contract.get("scenario_id", "unknown")),
		"events": event_log,
	})

func _write_scene_tree() -> bool:
	return _write_json("scene_tree.json", {
		"scenario_id": str(scenario_contract.get("scenario_id", "unknown")),
		"snapshots": scene_tree_snapshots,
	})

func _write_summary(result: Dictionary) -> bool:
	var summary: Dictionary = {
		"scenario_id": str(scenario_contract.get("scenario_id", "unknown")),
		"scenario_version": int(scenario_contract.get("version", 0)),
		"scenario_path": scenario_path,
		"artifacts_dir": artifacts_dir,
		"status": result.get("status", "running"),
		"exit_code": result.get("exit_code", null),
		"message": str(result.get("message", "")),
		"started_unix_time": started_unix_time,
		"elapsed_msec": Time.get_ticks_msec() - started_ticks_msec,
		"current_scene_path": _node_path_or_empty(get_tree().current_scene),
		"current_scene_name": "" if get_tree().current_scene == null else str(get_tree().current_scene.name),
		"done_contract": scenario_contract.get("done_contract", {}).duplicate(true),
		"artifact_contract": scenario_contract.get("artifact_contract", {}).duplicate(true),
		"steps": scenario_contract.get("steps", []),
		"checkpoints": checkpoints,
		"failed_assertion": result.get("failed_assertion", null),
		"errors": errors,
		"warnings": warnings,
		"event_count": event_log.size(),
		"result": result.duplicate(true),
	}
	return _write_json("summary.json", summary)

func _save_viewport_screenshot(relative_path: String) -> bool:
	if DisplayServer.get_name() == "headless":
		record_warning("Screenshot capture was skipped in headless mode for %s." % relative_path)
		return false

	var absolute_path: String = _join_artifact_path(relative_path)
	if not _ensure_directory(absolute_path.get_base_dir()):
		record_error("Unable to create screenshot directory for %s." % relative_path)
		return false

	var viewport_texture: ViewportTexture = get_viewport().get_texture()
	var image: Image = viewport_texture.get_image()
	if image == null or image.get_width() <= 0 or image.get_height() <= 0:
		record_error("Screenshot capture returned an empty image for %s." % relative_path)
		return false

	var save_result: int = image.save_png(absolute_path)
	if save_result != OK:
		record_error("Screenshot capture failed for %s with error code %d." % [relative_path, save_result])
		return false

	return true

func _write_json(relative_path: String, payload: Variant) -> bool:
	var absolute_path: String = _join_artifact_path(relative_path)
	if not _ensure_directory(absolute_path.get_base_dir()):
		push_error("Unable to create artifact directory for %s." % absolute_path)
		return false

	var artifact_file: FileAccess = FileAccess.open(absolute_path, FileAccess.WRITE)
	if artifact_file == null:
		push_error("Unable to open artifact file for writing: %s" % absolute_path)
		return false

	artifact_file.store_string(JSON.stringify(_json_safe(payload), "\t"))
	return true

func _ensure_directory(path: String) -> bool:
	return DirAccess.make_dir_recursive_absolute(path) == OK

func _join_artifact_path(relative_path: String) -> String:
	if relative_path.contains(":\\") or relative_path.contains(":/") or relative_path.begins_with("/"):
		return relative_path
	return artifacts_dir.path_join(relative_path)

func _node_path_or_empty(node: Node) -> String:
	if node == null:
		return ""
	return str(node.get_path())

func _json_safe(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_VECTOR2:
			return {
				"x": value.x,
				"y": value.y,
			}
		TYPE_VECTOR2I:
			return {
				"x": value.x,
				"y": value.y,
			}
		TYPE_NODE_PATH:
			return str(value)
		TYPE_ARRAY:
			var safe_array: Array = []
			for item in value:
				safe_array.append(_json_safe(item))
			return safe_array
		TYPE_DICTIONARY:
			var safe_dictionary: Dictionary = {}
			for key in value.keys():
				safe_dictionary[str(key)] = _json_safe(value[key])
			return safe_dictionary
		_:
			return str(value)
