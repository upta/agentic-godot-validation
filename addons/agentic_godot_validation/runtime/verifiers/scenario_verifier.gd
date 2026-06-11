extends RefCounted

const SUPPORTED_VALUE_COMPARATORS := [
	"eq",
	"neq",
	"gt",
	"gte",
	"lt",
	"lte",
	"contains",
	"starts_with",
	"ends_with",
]

const SUPPORTED_PIPELINE_OPERATIONS := [
	"add",
	"subtract",
	"abs",
]

func is_supported_comparator(comparator: String) -> bool:
	return SUPPORTED_VALUE_COMPARATORS.has(comparator)

func evaluate_live_condition(live_root: Dictionary, path: String, comparator: String, expected_value: Variant) -> Dictionary:
	var resolution: Dictionary = _resolve_root_value(live_root, path, "Path %s was not available in the live sample." % path)
	if not bool(resolution.get("found", false)):
		return {
			"found": false,
			"passed": false,
			"observed": null,
			"message": str(resolution.get("message", "Live path could not be resolved.")),
		}

	var observed_value: Variant = resolution.get("value", null)
	var comparison: Dictionary = _compare_values(observed_value, comparator, expected_value)
	return {
		"found": true,
		"passed": bool(comparison.get("comparable", true)) and bool(comparison.get("passed", false)),
		"observed": observed_value,
		"message": str(comparison.get("message", "")),
	}

func verify_value(checkpoints: Dictionary, step: Dictionary) -> Dictionary:
	var checkpoint_name: String = str(step.get("checkpoint", "after"))
	var path: String = str(step.get("path", ""))
	var comparator: String = str(step.get("comparator", "eq"))
	var expected_value: Variant = step.get("expected", null)

	if path.is_empty():
		return {
			"passed": false,
			"status": "runtime_error",
			"exit_code": 2,
			"assertion": "value",
			"message": "Value assertion requires a non-empty path.",
		}

	var resolution: Dictionary = _resolve_checkpoint_value(checkpoints, checkpoint_name, path)
	if not bool(resolution.get("found", false)):
		return {
			"passed": false,
			"status": "assertion_failure",
			"exit_code": 1,
			"assertion": "value",
			"checkpoint": checkpoint_name,
			"path": path,
			"comparator": comparator,
			"expected": expected_value,
			"message": str(resolution.get("message", "Value assertion could not resolve the requested path.")),
		}

	var observed_value: Variant = resolution.get("value", null)
	var comparison: Dictionary = _compare_values(observed_value, comparator, expected_value)
	if not bool(comparison.get("comparable", true)):
		return {
			"passed": false,
			"status": "runtime_error",
			"exit_code": 2,
			"assertion": "value",
			"checkpoint": checkpoint_name,
			"path": path,
			"comparator": comparator,
			"expected": expected_value,
			"observed": observed_value,
			"message": str(comparison.get("message", "Value assertion comparator could not be applied.")),
		}

	return {
		"passed": bool(comparison.get("passed", false)),
		"assertion": "value",
		"checkpoint": checkpoint_name,
		"path": path,
		"comparator": comparator,
		"expected": expected_value,
		"observed": observed_value,
		"related_checkpoints": [checkpoint_name],
		"message": "Observed %s at %s using %s against %s." % [str(observed_value), path, comparator, str(expected_value)],
	}

func verify_pipeline(scenario_contract: Dictionary, checkpoints: Dictionary, step: Dictionary) -> Dictionary:
	var sources_variant: Variant = step.get("sources", {})
	if not (sources_variant is Dictionary) or sources_variant.is_empty():
		return {
			"passed": false,
			"status": "runtime_error",
			"exit_code": 2,
			"assertion": "pipeline",
			"message": "Pipeline assertion requires a non-empty sources object.",
		}

	var pipeline_variant: Variant = step.get("pipeline", [])
	if not (pipeline_variant is Array):
		return {
			"passed": false,
			"status": "runtime_error",
			"exit_code": 2,
			"assertion": "pipeline",
			"message": "Pipeline assertion requires pipeline to be an array when provided.",
		}

	var assert_variant: Variant = step.get("assert", {})
	if not (assert_variant is Dictionary):
		return {
			"passed": false,
			"status": "runtime_error",
			"exit_code": 2,
			"assertion": "pipeline",
			"message": "Pipeline assertion requires an assert object.",
		}

	var resolved_sources: Dictionary = {}
	var available_values: Dictionary = {}
	var related_checkpoints: Array = []
	for source_name_variant in sources_variant.keys():
		var source_name: String = str(source_name_variant)
		var descriptor_variant: Variant = sources_variant[source_name_variant]
		if not (descriptor_variant is Dictionary):
			return {
				"passed": false,
				"status": "runtime_error",
				"exit_code": 2,
				"assertion": "pipeline",
				"message": "Pipeline source %s must be a JSON object." % source_name,
			}

		var descriptor: Dictionary = descriptor_variant
		var source_resolution: Dictionary = _resolve_pipeline_source(scenario_contract, checkpoints, source_name, descriptor)
		if not bool(source_resolution.get("found", false)):
			return source_resolution

		resolved_sources[source_name] = source_resolution
		available_values[source_name] = source_resolution.get("value", null)
		if source_resolution.has("checkpoint"):
			related_checkpoints.append(str(source_resolution.get("checkpoint", "")))

	var computed_values: Dictionary = {}
	var pipeline_results: Array = []
	for pipeline_index in range(pipeline_variant.size()):
		var pipeline_step_variant: Variant = pipeline_variant[pipeline_index]
		if not (pipeline_step_variant is Dictionary):
			return {
				"passed": false,
				"status": "runtime_error",
				"exit_code": 2,
				"assertion": "pipeline",
				"message": "Pipeline step %d must be a JSON object." % pipeline_index,
			}

		var pipeline_step: Dictionary = pipeline_step_variant
		var pipeline_result: Dictionary = _execute_pipeline_step(available_values, pipeline_step)
		if not bool(pipeline_result.get("ok", false)):
			pipeline_result["assertion"] = "pipeline"
			return pipeline_result

		var output_name: String = str(pipeline_result.get("output", ""))
		var output_value: Variant = pipeline_result.get("value", null)
		available_values[output_name] = output_value
		computed_values[output_name] = output_value
		pipeline_results.append({
			"op": str(pipeline_step.get("op", "")),
			"output": output_name,
			"value": output_value,
		})

	var assert_spec: Dictionary = assert_variant
	var actual_name: String = str(assert_spec.get("actual", ""))
	var comparator: String = str(assert_spec.get("comparator", "eq"))
	if actual_name.is_empty():
		return {
			"passed": false,
			"status": "runtime_error",
			"exit_code": 2,
			"assertion": "pipeline",
			"message": "Pipeline assertion requires assert.actual.",
		}

	var actual_resolution: Dictionary = _resolve_named_value(available_values, actual_name, "actual")
	if not bool(actual_resolution.get("found", false)):
		return {
			"passed": false,
			"status": "runtime_error",
			"exit_code": 2,
			"assertion": "pipeline",
			"message": str(actual_resolution.get("message", "Pipeline actual value could not be resolved.")),
		}

	var expected_source: String = str(assert_spec.get("expected_source", ""))
	var expected_value: Variant = null
	if not expected_source.is_empty():
		var expected_resolution: Dictionary = _resolve_named_value(available_values, expected_source, "expected_source")
		if not bool(expected_resolution.get("found", false)):
			return {
				"passed": false,
				"status": "runtime_error",
				"exit_code": 2,
				"assertion": "pipeline",
				"message": str(expected_resolution.get("message", "Pipeline expected source could not be resolved.")),
			}
		expected_value = expected_resolution.get("value", null)
	elif assert_spec.has("expected"):
		expected_value = assert_spec.get("expected", null)
	else:
		return {
			"passed": false,
			"status": "runtime_error",
			"exit_code": 2,
			"assertion": "pipeline",
			"message": "Pipeline assertion requires either assert.expected_source or assert.expected.",
		}

	var actual_value: Variant = actual_resolution.get("value", null)
	var comparison: Dictionary = _compare_values(actual_value, comparator, expected_value)
	if not bool(comparison.get("comparable", true)):
		return {
			"passed": false,
			"status": "runtime_error",
			"exit_code": 2,
			"assertion": "pipeline",
			"actual": actual_name,
			"actual_value": actual_value,
			"comparator": comparator,
			"expected_source": expected_source,
			"expected": expected_value,
			"message": str(comparison.get("message", "Pipeline comparison could not be applied.")),
		}

	return {
		"passed": bool(comparison.get("passed", false)),
		"assertion": "pipeline",
		"actual": actual_name,
		"actual_value": actual_value,
		"comparator": comparator,
		"expected_source": expected_source,
		"expected": expected_value,
		"sources": resolved_sources,
		"computed_values": computed_values,
		"pipeline_results": pipeline_results,
		"related_checkpoints": _dedupe_strings(related_checkpoints),
		"message": "Computed %s=%s and compared it using %s against %s." % [actual_name, str(actual_value), comparator, str(expected_value)],
	}

func finalize_run(scenario_contract: Dictionary, runtime_inspector: Node, provisional_result: Dictionary) -> Dictionary:
	var final_result: Dictionary = provisional_result.duplicate(true)
	var runtime_errors: Array = runtime_inspector.get_errors()
	var runtime_warnings: Array = runtime_inspector.get_warnings()
	var artifact_presence: Dictionary = runtime_inspector.collect_artifact_presence()
	var exit_code: int = int(final_result.get("exit_code", _lookup_exit_code(scenario_contract, "runtime_error", 2)))

	final_result["runtime_errors"] = runtime_errors
	final_result["runtime_warnings"] = runtime_warnings
	final_result["artifact_presence"] = artifact_presence

	if exit_code == _lookup_exit_code(scenario_contract, "pass", 0) and not runtime_errors.is_empty():
		exit_code = _lookup_exit_code(scenario_contract, "runtime_error", 2)
		final_result["status"] = "runtime_error"
		final_result["message"] = "Runtime errors were recorded during the scenario run."

	var missing_artifacts: Array = artifact_presence.get("missing", [])
	if exit_code == _lookup_exit_code(scenario_contract, "pass", 0) and not missing_artifacts.is_empty():
		exit_code = _lookup_exit_code(scenario_contract, "artifact_generation_error", 4)
		final_result["status"] = "artifact_generation_error"
		final_result["message"] = "Missing required artifacts: %s" % ", ".join(missing_artifacts)

	final_result["exit_code"] = exit_code
	if exit_code == _lookup_exit_code(scenario_contract, "pass", 0):
		final_result["status"] = "pass"
		if str(final_result.get("message", "")).is_empty():
			final_result["message"] = "Scenario passed."
		final_result["failed_assertion"] = null
	else:
		final_result["failed_assertion"] = _build_failed_assertion(final_result, runtime_inspector)

	return final_result

func _lookup_exit_code(scenario_contract: Dictionary, key_name: String, fallback: int) -> int:
	var exit_codes: Dictionary = scenario_contract.get("exit_codes", {})
	return int(exit_codes.get(key_name, fallback))

func _build_failed_assertion(final_result: Dictionary, runtime_inspector: Node) -> Variant:
	var verification_variant: Variant = final_result.get("verification", null)
	if not (verification_variant is Dictionary):
		return null

	var verification: Dictionary = verification_variant
	var related_checkpoints: Array = []
	var related_variant: Variant = verification.get("related_checkpoints", [])
	if related_variant is Array:
		for checkpoint_name_variant in related_variant:
			var checkpoint_name: String = str(checkpoint_name_variant)
			if not checkpoint_name.is_empty():
				related_checkpoints.append(checkpoint_name)
	if related_checkpoints.is_empty() and verification.has("checkpoint"):
		var fallback_checkpoint: String = str(verification.get("checkpoint", ""))
		if not fallback_checkpoint.is_empty():
			related_checkpoints.append(fallback_checkpoint)

	var screenshots: Array = []
	var checkpoints: Dictionary = runtime_inspector.get_checkpoints()
	for checkpoint_name in _dedupe_strings(related_checkpoints):
		var checkpoint: Dictionary = checkpoints.get(checkpoint_name, {})
		if not checkpoint.is_empty():
			var screenshot_path: String = str(checkpoint.get("screenshot_relative_path", ""))
			if not screenshot_path.is_empty():
				screenshots.append(screenshot_path)

	return {
		"step_index": int(verification.get("step_index", -1)),
		"step_op": str(verification.get("step_op", "")),
		"assertion": str(verification.get("assertion", "")),
		"message": str(final_result.get("message", verification.get("message", ""))),
		"checkpoint": verification.get("checkpoint", null),
		"path": verification.get("path", null),
		"actual": verification.get("actual", null),
		"comparator": verification.get("comparator", null),
		"expected": verification.get("expected", null),
		"expected_source": verification.get("expected_source", null),
		"observed": verification.get("observed", verification.get("actual_value", null)),
		"related_checkpoints": _dedupe_strings(related_checkpoints),
		"related_screenshots": _dedupe_strings(screenshots),
	}

func _resolve_checkpoint_value(checkpoints: Dictionary, checkpoint_name: String, path: String) -> Dictionary:
	var checkpoint: Dictionary = checkpoints.get(checkpoint_name, {})
	if checkpoint.is_empty():
		return {
			"found": false,
			"message": "Checkpoint %s was not available." % checkpoint_name,
		}

	return _resolve_root_value(checkpoint, path, "Path %s was not available at checkpoint %s." % [path, checkpoint_name])

func _resolve_contract_value(scenario_contract: Dictionary, path: String) -> Dictionary:
	return _resolve_root_value(scenario_contract, path, "Contract path %s was not available." % path)

func _resolve_root_value(root_value: Variant, path: String, missing_path_message: String) -> Dictionary:
	var resolved_value: Variant = root_value
	var segments: PackedStringArray = path.split(".")
	var traversed_path: Array = []
	for segment in segments:
		traversed_path.append(segment)
		if resolved_value is Dictionary:
			var resolved_dictionary: Dictionary = resolved_value
			if not resolved_dictionary.has(segment):
				return {
					"found": false,
					"message": missing_path_message,
				}
			resolved_value = resolved_dictionary.get(segment)
		elif resolved_value is Array:
			if not segment.is_valid_int():
				return {
					"found": false,
					"message": "Path %s requires a numeric array index at segment %s." % [path, segment],
				}
			var resolved_array: Array = resolved_value
			var array_index: int = int(segment)
			if array_index < 0 or array_index >= resolved_array.size():
				return {
					"found": false,
					"message": "Path %s referenced array index %d outside the available range." % [path, array_index],
				}
			resolved_value = resolved_array[array_index]
		elif resolved_value is Vector2 or resolved_value is Vector2i:
			match segment:
				"x":
					resolved_value = resolved_value.x
				"y":
					resolved_value = resolved_value.y
				_:
					return {
						"found": false,
						"message": "Path %s could not continue past %s." % [path, ".".join(traversed_path)],
					}
		elif resolved_value is Vector3 or resolved_value is Vector3i:
			match segment:
				"x":
					resolved_value = resolved_value.x
				"y":
					resolved_value = resolved_value.y
				"z":
					resolved_value = resolved_value.z
				_:
					return {
						"found": false,
						"message": "Path %s could not continue past %s." % [path, ".".join(traversed_path)],
					}
		else:
			return {
				"found": false,
				"message": "Path %s could not continue past %s." % [path, ".".join(traversed_path)],
			}

	return {
		"found": true,
		"value": resolved_value,
	}

func _resolve_pipeline_source(scenario_contract: Dictionary, checkpoints: Dictionary, source_name: String, descriptor: Dictionary) -> Dictionary:
	var kind: String = str(descriptor.get("kind", ""))
	match kind:
		"checkpoint":
			var checkpoint_name: String = str(descriptor.get("checkpoint", ""))
			var path: String = str(descriptor.get("path", ""))
			if checkpoint_name.is_empty() or path.is_empty():
				return {
					"found": false,
					"passed": false,
					"status": "runtime_error",
					"exit_code": 2,
					"message": "Pipeline checkpoint source %s requires checkpoint and path." % source_name,
				}
			var checkpoint_resolution: Dictionary = _resolve_checkpoint_value(checkpoints, checkpoint_name, path)
			if not bool(checkpoint_resolution.get("found", false)):
				return {
					"found": false,
					"passed": false,
					"status": "assertion_failure",
					"exit_code": 1,
					"assertion": "pipeline",
					"source": source_name,
					"checkpoint": checkpoint_name,
					"path": path,
					"message": str(checkpoint_resolution.get("message", "Pipeline checkpoint source could not be resolved.")),
				}
			return {
				"found": true,
				"kind": kind,
				"source": source_name,
				"checkpoint": checkpoint_name,
				"path": path,
				"value": checkpoint_resolution.get("value", null),
			}
		"contract":
			var contract_path: String = str(descriptor.get("path", ""))
			if contract_path.is_empty():
				return {
					"found": false,
					"passed": false,
					"status": "runtime_error",
					"exit_code": 2,
					"message": "Pipeline contract source %s requires path." % source_name,
				}
			var contract_resolution: Dictionary = _resolve_contract_value(scenario_contract, contract_path)
			if not bool(contract_resolution.get("found", false)):
				return {
					"found": false,
					"passed": false,
					"status": "runtime_error",
					"exit_code": 2,
					"assertion": "pipeline",
					"source": source_name,
					"path": contract_path,
					"message": str(contract_resolution.get("message", "Pipeline contract source could not be resolved.")),
				}
			return {
				"found": true,
				"kind": kind,
				"source": source_name,
				"path": contract_path,
				"value": contract_resolution.get("value", null),
			}
		"literal":
			return {
				"found": true,
				"kind": kind,
				"source": source_name,
				"value": descriptor.get("value", null),
			}
		_:
			return {
				"found": false,
				"passed": false,
				"status": "runtime_error",
				"exit_code": 2,
				"message": "Unsupported pipeline source kind %s for %s." % [kind, source_name],
			}

func _execute_pipeline_step(available_values: Dictionary, pipeline_step: Dictionary) -> Dictionary:
	var operation: String = str(pipeline_step.get("op", ""))
	var output_name: String = str(pipeline_step.get("as", ""))
	if output_name.is_empty():
		return _pipeline_runtime_error("Pipeline step %s requires an output name via as." % operation)

	match operation:
		"add":
			var add_inputs_resolution: Dictionary = _resolve_pipeline_inputs(available_values, pipeline_step)
			if not bool(add_inputs_resolution.get("ok", false)):
				return _pipeline_runtime_error(str(add_inputs_resolution.get("message", "Pipeline add inputs could not be resolved.")))
			var add_inputs: Array = add_inputs_resolution.get("values", [])
			if add_inputs.is_empty() or not _all_numeric(add_inputs):
				return _pipeline_runtime_error("Pipeline add requires numeric inputs.")
			var total: float = 0.0
			for add_input in add_inputs:
				total += float(add_input)
			return {"ok": true, "output": output_name, "value": total}
		"subtract":
			var subtract_inputs_resolution: Dictionary = _resolve_pipeline_inputs(available_values, pipeline_step)
			if not bool(subtract_inputs_resolution.get("ok", false)):
				return _pipeline_runtime_error(str(subtract_inputs_resolution.get("message", "Pipeline subtract inputs could not be resolved.")))
			var subtract_inputs: Array = subtract_inputs_resolution.get("values", [])
			if subtract_inputs.size() != 2 or not _all_numeric(subtract_inputs):
				return _pipeline_runtime_error("Pipeline subtract requires exactly two numeric inputs.")
			return {"ok": true, "output": output_name, "value": float(subtract_inputs[0]) - float(subtract_inputs[1])}
		"abs":
			var abs_value_resolution: Dictionary = _resolve_single_pipeline_input(available_values, pipeline_step)
			if not bool(abs_value_resolution.get("found", false)):
				return _pipeline_runtime_error(str(abs_value_resolution.get("message", "Pipeline abs input could not be resolved.")))
			var abs_value: Variant = abs_value_resolution.get("value", null)
			if not _is_numeric(abs_value):
				return _pipeline_runtime_error("Pipeline abs requires a numeric input.")
			return {"ok": true, "output": output_name, "value": abs(float(abs_value))}
		_:
			return _pipeline_runtime_error("Unsupported pipeline operation %s. Supported operations: %s." % [operation, ", ".join(SUPPORTED_PIPELINE_OPERATIONS)])

func _resolve_pipeline_inputs(available_values: Dictionary, pipeline_step: Dictionary) -> Dictionary:
	var inputs_variant: Variant = pipeline_step.get("inputs", [])
	if not (inputs_variant is Array):
		return {
			"ok": false,
			"message": "Pipeline inputs must be an array.",
		}

	var resolved_inputs: Array = []
	for input_name_variant in inputs_variant:
		var input_name: String = str(input_name_variant)
		var resolution: Dictionary = _resolve_named_value(available_values, input_name, "pipeline input")
		if not bool(resolution.get("found", false)):
			return {
				"ok": false,
				"message": str(resolution.get("message", "Pipeline input could not be resolved.")),
			}
		resolved_inputs.append(resolution.get("value", null))

	return {
		"ok": true,
		"values": resolved_inputs,
	}

func _resolve_single_pipeline_input(available_values: Dictionary, pipeline_step: Dictionary) -> Dictionary:
	var input_name: String = str(pipeline_step.get("input", ""))
	if input_name.is_empty():
		var inputs_variant: Variant = pipeline_step.get("inputs", [])
		if inputs_variant is Array and not inputs_variant.is_empty():
			input_name = str(inputs_variant[0])

	if input_name.is_empty():
		return {
			"found": false,
			"message": "Pipeline step requires an input name.",
		}

	return _resolve_named_value(available_values, input_name, "pipeline input")

func _resolve_named_value(available_values: Dictionary, value_name: String, context_label: String) -> Dictionary:
	if value_name.is_empty() or not available_values.has(value_name):
		return {
			"found": false,
			"message": "Unable to resolve %s %s." % [context_label, value_name],
		}
	return {
		"found": true,
		"value": available_values.get(value_name, null),
	}

func _pipeline_runtime_error(message: String) -> Dictionary:
	return {
		"ok": false,
		"status": "runtime_error",
		"exit_code": 2,
		"message": message,
	}

func _compare_values(observed_value: Variant, comparator: String, expected_value: Variant) -> Dictionary:
	match comparator:
		"eq":
			return {
				"comparable": true,
				"passed": _values_equal(observed_value, expected_value),
			}
		"neq":
			return {
				"comparable": true,
				"passed": not _values_equal(observed_value, expected_value),
			}
		"gt", "gte", "lt", "lte":
			return _compare_numeric_values(observed_value, comparator, expected_value)
		"contains":
			return _compare_contains(observed_value, expected_value)
		"starts_with", "ends_with":
			return _compare_string_prefix_suffix(observed_value, comparator, expected_value)
		_:
			return {
				"comparable": false,
				"passed": false,
				"message": "Unsupported value comparator %s. Supported comparators: %s." % [comparator, ", ".join(SUPPORTED_VALUE_COMPARATORS)],
			}

func _compare_numeric_values(observed_value: Variant, comparator: String, expected_value: Variant) -> Dictionary:
	if not _is_numeric(observed_value) or not _is_numeric(expected_value):
		return {
			"comparable": false,
			"passed": false,
			"message": "Comparator %s requires numeric observed and expected values." % comparator,
		}

	var observed_number: float = float(observed_value)
	var expected_number: float = float(expected_value)
	match comparator:
		"gt":
			return {"comparable": true, "passed": observed_number > expected_number}
		"gte":
			return {"comparable": true, "passed": observed_number >= expected_number}
		"lt":
			return {"comparable": true, "passed": observed_number < expected_number}
		"lte":
			return {"comparable": true, "passed": observed_number <= expected_number}
		_:
			return {
				"comparable": false,
				"passed": false,
				"message": "Unsupported numeric comparator %s." % comparator,
			}

func _compare_contains(observed_value: Variant, expected_value: Variant) -> Dictionary:
	if observed_value is String:
		return {
			"comparable": true,
			"passed": str(observed_value).contains(str(expected_value)),
		}
	if observed_value is Array:
		var observed_array: Array = observed_value
		return {
			"comparable": true,
			"passed": observed_array.has(expected_value),
		}
	if observed_value is Dictionary:
		var observed_dictionary: Dictionary = observed_value
		var expected_key: String = str(expected_value)
		return {
			"comparable": true,
			"passed": observed_dictionary.has(expected_value) or observed_dictionary.has(expected_key),
		}

	return {
		"comparable": false,
		"passed": false,
		"message": "Comparator contains requires a string, array, or dictionary observed value.",
	}

func _compare_string_prefix_suffix(observed_value: Variant, comparator: String, expected_value: Variant) -> Dictionary:
	if not (observed_value is String):
		return {
			"comparable": false,
			"passed": false,
			"message": "Comparator %s requires a string observed value." % comparator,
		}

	var observed_string: String = str(observed_value)
	var expected_string: String = str(expected_value)
	if comparator == "starts_with":
		return {
			"comparable": true,
			"passed": observed_string.begins_with(expected_string),
		}
	return {
		"comparable": true,
		"passed": observed_string.ends_with(expected_string),
	}

func _values_equal(left_value: Variant, right_value: Variant) -> bool:
	if _is_numeric(left_value) and _is_numeric(right_value):
		return is_equal_approx(float(left_value), float(right_value))
	return left_value == right_value

func _is_numeric(value: Variant) -> bool:
	var value_type: int = typeof(value)
	return value_type == TYPE_INT or value_type == TYPE_FLOAT

func _all_numeric(values: Array) -> bool:
	for value in values:
		if not _is_numeric(value):
			return false
	return true

func _dedupe_strings(values: Array) -> Array:
	var deduped: Array = []
	var seen: Dictionary = {}
	for value_variant in values:
		var value: String = str(value_variant)
		if value.is_empty() or seen.has(value):
			continue
		seen[value] = true
		deduped.append(value)
	return deduped
