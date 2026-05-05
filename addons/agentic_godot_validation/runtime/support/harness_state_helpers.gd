extends RefCounted

static func build_named_node_facts(node_alias_map: Dictionary) -> Dictionary:
	var node_facts: Dictionary = {}
	for alias_variant in node_alias_map.keys():
		node_facts[str(alias_variant)] = build_node_facts(node_alias_map[alias_variant])
	return node_facts

static func build_node_facts(node: Variant) -> Dictionary:
	if not (node is Node):
		return {
			"exists": false,
			"path": "",
		}

	var target_node: Node = node
	var facts: Dictionary = {
		"exists": true,
		"name": str(target_node.name),
		"type": target_node.get_class(),
		"path": str(target_node.get_path()),
		"inside_tree": target_node.is_inside_tree(),
		"physics_processing": target_node.is_physics_processing(),
	}

	if target_node is CanvasItem:
		facts["visible"] = target_node.is_visible_in_tree()

	if target_node is Node2D:
		facts["position"] = target_node.position
		facts["global_position"] = target_node.global_position

	if target_node is Control:
		facts["focused"] = target_node.has_focus()
		facts["size"] = target_node.size

	_copy_property_if_present(target_node, facts, "disabled")
	if facts.has("disabled"):
		facts["enabled"] = not bool(facts.get("disabled", false))

	_copy_property_if_present(target_node, facts, "text")
	_copy_property_if_present(target_node, facts, "button_pressed")
	_copy_property_if_present(target_node, facts, "selected")
	return facts

static func _copy_property_if_present(target: Object, facts: Dictionary, property_name: String) -> void:
	if _has_property(target, property_name):
		facts[property_name] = target.get(property_name)

static func _has_property(target: Object, property_name: String) -> bool:
	for property_info_variant in target.get_property_list():
		if property_info_variant is Dictionary:
			var property_info: Dictionary = property_info_variant
			if str(property_info.get("name", "")) == property_name:
				return true
	return false
