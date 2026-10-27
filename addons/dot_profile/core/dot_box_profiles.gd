class_name DotBoxProfiles
extends RefCounted

## The `box` profile kind: a random box type (looks, odds, outcomes, timed effect, sounds) as one yml per type.
##
## Paths: cfg/addon/dot-profile/box, cfg/game/<game>/box, cfg/server/... as every kind. The game ships its types as game-tier files; an operator
## edits one live in the workbench. Outcomes and actions are the game's own vocabulary and are validated by the game, not here.

const ADDON := "dot-profile"
const KIND := "box"
const POLARITIES: Array[String] = ["positive", "negative", "mixed"]
const IMPACTS: Array[String] = ["self", "radius", "everyone", "game"]
const DURATION_MODES: Array[String] = ["instant", "seconds", "round"]
const DROP_SOURCES: Array[String] = ["common", "special", "brute", "map"]
## Sound events; the same list as dot-audio's DotBoxSounds.EVENTS (dot-profile must not depend on dot-audio).
const LIST_KEY := "_list"
const SOUND_EVENTS: Array[String] = ["spawn", "approach", "open", "reward", "deny", "effect_end"]
const SOUND_MODES: Array[String] = ["3d", "ui"]
const SOUND_KEYS: Array[String] = ["sound", "volume", "pitch_jitter", "max_distance", "unit_size", "mode", "enabled"]


static func schema() -> Array:
	var f := DotProfileSet.field
	return [
		f.call("title", "string", ""),
		f.call("colour", "string", "#d0a040"),
		f.call("enabled", "bool", true),
		f.call("polarity", "string", "mixed", {"enum": POLARITIES}),
		f.call("impact", "string", "self", {"enum": IMPACTS}),
		f.call("radius", "float", 0.0, {"min": 0.0, "max": 500.0}),
		f.call("stacks", "bool", true),
		f.call("max_stacks", "int", 99, {"min": 1, "max": 9999}),
		f.call("survives_round", "bool", false),
		f.call("duration", "dict", {"mode": "instant", "min": 0.0, "max": 0.0}),
		f.call("drop", "dict", {}),
		f.call("open_seconds", "float", 0.0, {"min": 0.0, "max": 30.0}),
		f.call("lifetime", "float", 0.0, {"min": 0.0, "max": 3600.0}),
		f.call("params", "dict", {}),
		f.call("outcomes", "list", []),
		f.call("sounds", "dict", {}),
		f.call("meta", "dict", {}),
	]


static func profile_schemas() -> Dictionary:
	return {KIND: {"schema": schema(), "children": {}}}


static func make_set(game: String, roots: PackedStringArray = PackedStringArray()) -> DotProfileSet:
	var s := DotProfileSet.create(ADDON, game, KIND, schema())
	s.roots = roots
	s.validator = Callable(DotBoxProfiles, "check")
	return s


## Checks the dict-valued keys the schema cannot: duration, drop odds, sound slots. Returns every problem as one CODE_INVALID.
static func check(p: DotProfile) -> DotResult:
	var problems: Array[String] = []
	var d: Dictionary = p.get_value("duration", {})
	var mode := str(d.get("mode", "instant"))
	if mode not in DURATION_MODES:
		problems.append("duration.mode '%s' is not one of %s" % [mode, ", ".join(DURATION_MODES)])
	var lo := float(d.get("min", 0.0))
	var hi := float(d.get("max", 0.0))
	if not is_finite(lo) or not is_finite(hi) or lo < 0.0 or hi < lo:
		problems.append("duration needs 0 <= min <= max (%s, %s)" % [lo, hi])
	if mode == "seconds" and hi <= 0.0:
		problems.append("duration.mode seconds needs max > 0")
	var drop: Dictionary = p.get_value("drop", {})
	for k in drop:
		if str(k) not in DROP_SOURCES:
			problems.append("drop.%s is not a source (%s)" % [k, ", ".join(DROP_SOURCES)])
		elif not (drop[k] is int or drop[k] is float) or not is_finite(float(drop[k])) or float(drop[k]) < 0.0:
			problems.append("drop.%s must be a number >= 0" % k)
	var sounds: Dictionary = p.get_value("sounds", {})
	for ev in sounds:
		if str(ev) not in SOUND_EVENTS:
			problems.append("sounds.%s is not an event (%s)" % [ev, ", ".join(SOUND_EVENTS)])
			continue
		var slot: Variant = sounds[ev]
		if not (slot is Dictionary):
			problems.append("sounds.%s must be a map" % ev)
			continue
		problems.append_array(check_slot(str(ev), slot))
	if problems.is_empty():
		return DotResult.success(p)
	return DotResult.fail(DotError.CODE_INVALID, "box profile '%s' is invalid" % p.id, "; ".join(problems))


static func check_slot(event: String, slot: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for k in slot:
		if str(k) not in SOUND_KEYS:
			out.append("sounds.%s.%s is not a slot key (%s)" % [event, k, ", ".join(SOUND_KEYS)])
	var ranges := {"volume": [0.0, 4.0], "pitch_jitter": [0.0, 0.5], "max_distance": [1.0, 10000.0], "unit_size": [0.1, 1000.0]}
	for k in ranges:
		if not slot.has(k):
			continue
		var v: Variant = slot[k]
		if not (v is int or v is float) or not is_finite(float(v)) or float(v) < ranges[k][0] or float(v) > ranges[k][1]:
			out.append("sounds.%s.%s must be %s to %s" % [event, k, ranges[k][0], ranges[k][1]])
	if slot.has("mode") and str(slot["mode"]) not in SOUND_MODES:
		out.append("sounds.%s.mode must be 3d or ui" % event)
	if slot.has("sound") and not (slot["sound"] is String):
		out.append("sounds.%s.sound must be a string" % event)
	if slot.has("enabled") and not (slot["enabled"] is bool):
		out.append("sounds.%s.enabled must be true or false" % event)
	return out


## One box profile loaded (the set's validator is [method check]); the value is a [DotProfile].
static func load_box(set: DotProfileSet, id: String) -> DotResult:
	var res := set.load_profile(id)
	if not res.ok:
		return res
	return res


## yml text for a box document `{key: value}` with nested maps and lists of maps (DotYaml.emit does scalars-only lists); the reader gives the same tree back.
static func to_yaml(tree: Dictionary, indent: int = 0) -> String:
	var out := PackedStringArray()
	var pad := "  ".repeat(indent)
	for k in tree:
		var v: Variant = tree[k]
		if v is Dictionary:
			# An empty map reads back as an empty string, so it is left out (the schema default is {}).
			if not (v as Dictionary).is_empty():
				out.append("%s%s:" % [pad, k])
				out.append(to_yaml(v, indent + 1).trim_suffix("\n"))
		elif v is Array:
			if (v as Array).is_empty():
				out.append("%s%s: []" % [pad, k])
			else:
				out.append("%s%s:" % [pad, k])
				for raw_item: Variant in v:
					# DotYaml has no list in a list: one is written as `- _list: [...]` and [method unwrap_lists] undoes it.
					var item: Variant = {LIST_KEY: raw_item} if raw_item is Array else raw_item
					if item is Dictionary:
						var lines := to_yaml(item, indent + 2).trim_suffix("\n").split("\n")
						lines[0] = "%s  - %s" % [pad, lines[0].strip_edges(true, false)]
						out.append("\n".join(lines))
					else:
						out.append("%s  - %s" % [pad, _scalar(item)])
		else:
			out.append("%s%s: %s" % [pad, k, _scalar(v)])
	return "\n".join(out) + "\n"


## Turns every `{_list: [...]}` that [method to_yaml] wrote back into the list, at any depth.
static func unwrap_lists(v: Variant) -> Variant:
	if v is Dictionary:
		var d := v as Dictionary
		if d.size() == 1 and d.has(LIST_KEY):
			return unwrap_lists(d[LIST_KEY])
		var out := {}
		for k in d:
			out[k] = unwrap_lists(d[k])
		return out
	if v is Array:
		return (v as Array).map(func(x: Variant) -> Variant: return unwrap_lists(x))
	return v


static func _scalar(v: Variant) -> String:
	if v is String or v is StringName:
		return "\"%s\"" % str(v).replace("\\", "\\\\").replace("\"", "\\\"")
	if v is bool:
		return "true" if v else "false"
	if v is float:
		# JSON reads every number as a float; a whole one is written as an int so an int field takes it.
		return str(v) if absf(v - roundf(v)) > 0.0 else "%d" % int(v)
	return str(v)
