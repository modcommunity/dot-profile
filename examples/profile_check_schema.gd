extends RefCounted

## Schema provider for profile_check_selftest: kind `thing` with an `opt` child set.


static func profile_schemas() -> Dictionary:
	var f := DotProfileSet.field
	return {"thing": {
		"schema": [f.call("hp", "int", 10, {"min": 1, "max": 100}), f.call("mode", "string", "a", {"enum": ["a", "b"]}), f.call("speed", "float", 1.0)],
		"children": {"opt": [f.call("cost", "int", 0, {"min": 0})]},
	}}
