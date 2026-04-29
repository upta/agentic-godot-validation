extends RefCounted

var _signal_facts: Dictionary = {}

func track_signal(target: Object, signal_name: String, owner_alias: String, signal_alias: String = signal_name) -> void:
	_ensure_signal_entry(owner_alias, signal_alias, signal_name, _target_path_or_empty(target))

	if target == null or not _has_signal(target, signal_name):
		_signal_facts[owner_alias][signal_alias]["connected"] = false
		return

	var arg_count: int = _signal_arg_count(target, signal_name)
	var signal_callable: Callable = Callable(self, "_record_signal").bind(owner_alias, signal_alias)
	if arg_count > 0:
		signal_callable = signal_callable.unbind(arg_count)

	if not target.is_connected(signal_name, signal_callable):
		target.connect(signal_name, signal_callable)

	_signal_facts[owner_alias][signal_alias]["connected"] = true

func get_signal_facts() -> Dictionary:
	return _signal_facts.duplicate(true)

func _record_signal(owner_alias: String, signal_alias: String) -> void:
	if not _signal_facts.has(owner_alias):
		return
	if not _signal_facts[owner_alias].has(signal_alias):
		return

	var signal_fact: Dictionary = _signal_facts[owner_alias][signal_alias]
	signal_fact["count"] = int(signal_fact.get("count", 0)) + 1
	signal_fact["last_emitted_msec"] = Time.get_ticks_msec()
	_signal_facts[owner_alias][signal_alias] = signal_fact

func _ensure_signal_entry(owner_alias: String, signal_alias: String, signal_name: String, source_path: String) -> void:
	if not _signal_facts.has(owner_alias):
		_signal_facts[owner_alias] = {}

	if not _signal_facts[owner_alias].has(signal_alias):
		_signal_facts[owner_alias][signal_alias] = {
			"signal_name": signal_name,
			"source_path": source_path,
			"count": 0,
			"connected": false,
			"last_emitted_msec": null,
		}

func _has_signal(target: Object, signal_name: String) -> bool:
	for signal_info_variant in target.get_signal_list():
		if signal_info_variant is Dictionary:
			var signal_info: Dictionary = signal_info_variant
			if str(signal_info.get("name", "")) == signal_name:
				return true
	return false

func _signal_arg_count(target: Object, signal_name: String) -> int:
	for signal_info_variant in target.get_signal_list():
		if signal_info_variant is Dictionary:
			var signal_info: Dictionary = signal_info_variant
			if str(signal_info.get("name", "")) == signal_name:
				var args_variant: Variant = signal_info.get("args", [])
				if args_variant is Array:
					return args_variant.size()
	return 0

func _target_path_or_empty(target: Object) -> String:
	if target is Node:
		return str(target.get_path())
	return ""
