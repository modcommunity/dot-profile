extends RefCounted

## Second provider of kind `thing`, for the duplicate-kind check in profile_check_selftest.


static func profile_schemas() -> Dictionary:
	return {"thing": [DotProfileSet.field.call("hp", "int", 1)]}
