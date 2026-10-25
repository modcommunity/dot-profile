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
## Dotted paths the runtime (admin edit) layer sets on this profile, sorted; empty when unedited.
var runtime_keys := PackedStringArray()
## Dotted paths the files (any tier, and every profile it extends) set, sorted; a schema default is not listed.
var file_keys := PackedStringArray()
## The set that loaded this profile; held weakly, so the set's cache and its profiles do not
## keep each other alive. Null once the set is freed.
var set_ref: DotProfileSet:
	get:
		return _set_weak.get_ref() as DotProfileSet if _set_weak != null else null
	set(value):
		_set_weak = weakref(value) if value != null else null

var _set_weak: WeakRef = null


## A schema value, or [param default] when the key is not in the schema.
func get_value(key: String, default: Variant = null) -> Variant:
	return values.get(key, default)


## A dotted path into the `extra:` block.
func get_extra(path: String, default: Variant = null) -> Variant:
	return DotYaml.at(extra, path, default)


## Values plus `extra` as one copy.
func to_dictionary() -> Dictionary:
	return {"id": id, "values": values.duplicate(true), "extra": extra.duplicate(true)}


## The set of sub-entities in this profile's folder, with their own schema; null once the owning set is freed.
func child_set(child_kind: String, child_schema: Array = []) -> DotProfileSet:
	var owner_set := set_ref
	if owner_set == null:
		return null
	return owner_set.child_set(id, child_kind, child_schema)


## Sub-folders of this profile's folder, such as `upgrades`.
func child_kinds() -> PackedStringArray:
	var owner_set := set_ref
	return owner_set.child_kinds(id) if owner_set != null else PackedStringArray()


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
	if not file_keys.is_empty():
		out.append("  file keys set: %s" % ", ".join(file_keys))
	if not runtime_keys.is_empty():
		out.append("  runtime keys set: %s" % ", ".join(runtime_keys))
	return out
