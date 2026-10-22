extends RefCounted

## A provider that returns the wrong shape, for profile_check_selftest.


static func profile_schemas() -> Dictionary:
	return {"gadget": "not a schema"}
