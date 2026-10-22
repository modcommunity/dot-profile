class_name DotProfile
extends RefCounted

## One loaded profile: schema values, the `extra:` block, and where they came from.

## Profile id (the file or folder name).
var id := ""
## Schema key -> validated value.
var values: Dictionary = {}
## The `extra:` block, untouched.
var extra: Dictionary = {}
## This id then each id it extends, nearest first.
var chain := PackedStringArray()
## `tier: path` for every file read, weakest first.
var sources := PackedStringArray()
## `key <- source` for each environment or command line override applied.
var overrides := PackedStringArray()
## Overrides refused as secrets.
var refused := PackedStringArray()
## The set that loaded this profile.
var set_ref: DotProfileSet = null


## A schema value, or [param default] when the key is not in the schema.
func get_value(key: String, default: Variant = null) -> Variant:
	return values.get(key, default)


## A dotted path into the `extra:` block.
func get_extra(path: String, default: Variant = null) -> Variant:
	return DotYaml.at(extra, path, default)


## Values plus `extra` as one copy.
func to_dictionary() -> Dictionary:
	return {"id": id, "values": values.duplicate(true), "extra": extra.duplicate(true)}


## The set of sub-entities in this profile's folder, with their own schema.
func child_set(child_kind: String, child_schema: Array = []) -> DotProfileSet:
	return set_ref.child_set(id, child_kind, child_schema)


## Sub-folders of this profile's folder, such as `upgrades`.
func child_kinds() -> PackedStringArray:
	return set_ref.child_kinds(id)


func describe() -> String:
	return "\n".join(describe_lines())


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["DotProfile %s (extends chain: %s)" % [id, " > ".join(chain)]])
	for k in values:
		out.append("  %s = %s" % [k, str(values[k])])
	for s in sources:
		out.append("  from %s" % s)
	for o in overrides:
		out.append("  override %s" % o)
	for r in refused:
		out.append("  refused %s" % r)
	return out
