class_name DotProfileSet
extends RefCounted

## A directory of per-entity profiles (NPCs, weapons, classes): lists, loads and validates them.
##
## One file per profile, `<kind>/<id>.yml`, or a folder `<kind>/<id>/<id>.yml` (or
## `profile.yml`) that may hold child sets (`<kind>/<id>/upgrades/<child>.yml`). Tiers, weakest
## first: schema defaults < addon (`cfg/addons/<addon>/`) < game (`cfg/game/<game>/`) < server
## (`cfg/server/`) < environment < command line. A weaker tier's file may be overridden by a
## few keys of a stronger one. A player's `user` tier sits between game and server, on only in a
## solo or listen-host process. See docs/profiles.md.

const CHANNEL := "profile"
const EXTENSION := "yml"
const FOLDER_FILE := "profile"
## Top-level key that holds keys the schema does not know; passed through untouched.
const EXTRA_KEY := "extra"
const EXTENDS_KEY := "extends"
const TIER_ADDON := "addon"
const TIER_GAME := "game"
const TIER_USER := "user"
const TIER_SERVER := "server"

## Whether the user tier (`user://cfg/user/`) is read. Off: a dedicated server or a connected client
## must never obey a file on the player's disk. The solo or listen-host game turns it on.
static var user_tier_enabled := false

## Owning addon (`cfg/addons/<addon>/`), empty to skip the addon tier.
var addon_name := ""
## Game id (`cfg/game/<game>/`), empty to skip the game tier.
var game := ""
## Path below the tier directory: `npc`, `weapon`, or `weapon/pistol/upgrades` for a child set.
var rel_path := ""
## Fields built with [method field].
var schema: Array = []
## Unknown top-level keys fail when true; put them under `extra:` instead.
var strict := true
## Names that environment and command line may never set, on top of the secret words.
var sensitive := PackedStringArray()
## Prefix for environment (`PROFILE_NPC_ZOMBIE_HEALTH`) and command line (`--profile.npc/zombie.health=5`).
var override_prefix := "profile"
## Config roots, weakest first. Empty means [method default_roots].
var roots := PackedStringArray()
## Command-line arguments to read overrides from; empty means the process's own.
var cmdline := PackedStringArray()
## Where the user tier lives: `<user_root>/user/<kind>/<id>.yml`.
var user_root := "user://cfg"

## Runtime layer, above every file tier: profile id -> {dotted path: value}. Written by
## [DotProfileRuntime]; `extra.a.b` paths land in `extra`, `stats.hp` in a dict field.
var runtime: Dictionary = {}

var _cache: Dictionary = {}


## Builds a set for [param p_rel_path] (a singular kind such as `npc`) and its [param p_schema].
static func create(p_addon: String, p_game: String, p_rel_path: String, p_schema: Array = []) -> DotProfileSet:
	var s := DotProfileSet.new()
	s.addon_name = p_addon
	s.game = p_game
	s.rel_path = p_rel_path
	s.schema = p_schema
	return s


## One schema entry. [param opts] may hold `min`, `max`, `enum` (Array) and `required` (bool).
## [param type] is int, float, string, bool, list, dict or any.
static func field(p_name: String, type: String, default: Variant = null, opts: Dictionary = {}) -> Dictionary:
	var d := {"name": p_name, "type": type, "default": default}
	d.merge(opts, true)
	return d


## Turns the user tier on for a solo or listen-host process, off for a server or a connected client.
static func set_user_tier(enabled: bool) -> void:
	user_tier_enabled = enabled


## Config roots, weakest first: `res://cfg`, next to the executable, `user://cfg`, `--config DIR`.
static func default_roots() -> PackedStringArray:
	var out := PackedStringArray(["res://cfg"])
	var exe := OS.get_executable_path().get_base_dir()
	if exe != "":
		out.append(exe.path_join("cfg"))
	out.append("user://cfg")
	var given := DotAddonConfig._config_dir_arg()
	if given != "":
		out.append(given)
	return out


## Ids found on disk across all tiers, sorted; no file is opened.
func list_ids() -> PackedStringArray:
	var seen := {}
	for dir in _tier_dirs().values():
		for d in dir:
			for f in DirAccess.get_files_at(d):
				if f.get_extension().to_lower() == EXTENSION:
					seen[f.get_basename()] = true
			for sub in DirAccess.get_directories_at(d):
				if FileAccess.file_exists(d.path_join(sub).path_join(sub + "." + EXTENSION)) \
						or FileAccess.file_exists(d.path_join(sub).path_join(FOLDER_FILE + "." + EXTENSION)):
					seen[sub] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


## True when some tier has a file for [param id].
func has_id(id: String) -> bool:
	return _id_ok(id) and not _files_for(id).is_empty()


## Loads, extends-resolves, overrides and validates one profile. Value: a [DotProfile].
func load_profile(id: String) -> DotResult:
	if _cache.has(id):
		return DotResult.success(_cache[id])
	var res := _load(id)
	if res.ok:
		_cache[id] = res.value
	return res


## Forgets loaded profiles so the next load reads the files again.
func clear_cache() -> void:
	_cache.clear()


## Replaces the runtime layer of [param id] (empty [param paths] clears it) and drops its cache.
func set_runtime(id: String, paths: Dictionary) -> void:
	if paths.is_empty():
		runtime.erase(id)
	else:
		runtime[id] = paths.duplicate(true)
	_cache.erase(id)


## The runtime layer of [param id] as a copy.
func runtime_paths(id: String) -> Dictionary:
	return (runtime.get(id, {}) as Dictionary).duplicate(true)


## Checks one runtime edit against the schema without applying it. Value: `{path, value}` with
## the value coerced to the field's type. NaN, infinity, unknown keys and secrets are refused.
func check_edit(id: String, path: String, value: Variant) -> DotResult:
	if not has_id(id):
		return DotResult.fail(DotError.CODE_INVALID, "%s: " % id + "no such profile")
	var parts := path.split(".")
	if path.is_empty() or parts.has(""):
		return DotResult.fail(DotError.CODE_INVALID, "%s: " % id + "bad key path '%s'" % path)
	if not _finite(value):
		return DotResult.fail(DotError.CODE_INVALID, "%s: " % id + "%s: NaN or infinity is refused" % path)
	if DotAddonConfig._is_sensitive(parts[parts.size() - 1], sensitive):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "%s: " % id + "%s: secrets cannot be edited at runtime" % path)
	if parts[0] == EXTRA_KEY:
		if parts.size() < 2:
			return DotResult.fail(DotError.CODE_INVALID, "%s: " % id + "name a key under '%s'" % EXTRA_KEY)
		return DotResult.success({"path": path, "value": value})
	var f := {}
	for e in schema:
		if e["name"] == parts[0]:
			f = e
	if f.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "%s: " % id + "unknown key '%s'" % parts[0])
	if parts.size() > 1:
		if f["type"] != "dict" and f["type"] != "any":
			return DotResult.fail(DotError.CODE_INVALID, "%s: " % id + "%s is not a mapping" % parts[0])
		return DotResult.success({"path": path, "value": value})
	var checked := _check_field(f, value)
	if checked.has("error"):
		return DotResult.fail(DotError.CODE_INVALID, "%s: " % id + "%s: %s" % [path, checked["error"]])
	return DotResult.success({"path": path, "value": checked["value"]})


## Path of the user-tier file for [param id].
func user_file(id: String) -> String:
	return user_root.path_join(TIER_USER).path_join(rel_path).path_join(id + "." + EXTENSION)


## The user tier's own `{dotted path: value}` for [param id], read even when the tier is off.
func user_paths(id: String) -> Dictionary:
	var file := user_file(id)
	if not _id_ok(id) or not FileAccess.file_exists(file):
		return {}
	var res := DotYaml.parse_file(file)
	var out := {}
	if res.ok and res.value is Dictionary:
		_flatten(res.value, "", out)
	return out


## Writes [param paths] (`{dotted path: value}`) into the user file, keeping its other keys. Each
## is checked against the schema and the profile must still load, else the file is restored.
func save_user(id: String, paths: Dictionary) -> DotResult:
	if not user_tier_enabled:
		return DotResult.fail(DotError.CODE_STATE, "%s/%s: the user tier is off in this process" % [rel_path, id])
	if not has_id(id):
		return DotResult.fail(DotError.CODE_INVALID, "%s/%s: no such profile" % [rel_path, id])
	var tree := {}
	var file := user_file(id)
	var had := FileAccess.file_exists(file)
	var before := ""
	if had:
		var existing := DotYaml.parse_file(file)
		if not existing.ok:
			return existing.wrap("saving %s" % file)
		if existing.value is Dictionary:
			tree = existing.value
		before = FileAccess.get_file_as_string(file)
	for path in paths:
		var ok := check_edit(id, String(path), paths[path])
		if not ok.ok:
			return ok
		_set_path(tree, String(path).split("."), ok.value["value"])
	var text: Variant = DotProfileRuntime._emit(tree, 0)
	if text == null:
		return DotResult.fail(DotError.CODE_INVALID, "%s/%s holds a value yml cannot carry" % [rel_path, id])
	var dir := DotPaths.ensure_parent_dir(file)
	if not dir.ok:
		return dir
	var wrote := DotPaths.write_text(file, text)
	if not wrote.ok:
		return wrote.wrap("saving %s" % file)
	_cache.erase(id)
	var loaded := load_profile(id)
	if not loaded.ok:
		if had:
			DotPaths.write_text(file, before)
		else:
			DirAccess.remove_absolute(file)
		_cache.erase(id)
		DotWeb.sync_filesystem()
		return loaded
	DotWeb.sync_filesystem()
	DotLog.info(CHANNEL, "profile saved to user layer", {"kind": rel_path, "id": id, "keys": paths.size()})
	return DotResult.success({"saved": file})


## Removes the user file of [param id]: back to the tiers below. Value: true when a file was removed.
func reset_user(id: String) -> DotResult:
	if not _id_ok(id):
		return DotResult.fail(DotError.CODE_INVALID, "bad profile id")
	var file := user_file(id)
	if not FileAccess.file_exists(file):
		return DotResult.success(false)
	var err := DirAccess.remove_absolute(file)
	if err != OK:
		return DotResult.fail(DotError.CODE_IO, "cannot remove %s" % file)
	_cache.erase(id)
	DotWeb.sync_filesystem()
	DotLog.info(CHANNEL, "profile user layer reset", {"kind": rel_path, "id": id})
	return DotResult.success(true)


## The set below profile [param id]: `<rel>/<id>/<child_kind>`, with its own schema.
func child_set(id: String, child_kind: String, child_schema: Array = []) -> DotProfileSet:
	var s := DotProfileSet.create(addon_name, game, rel_path.path_join(id).path_join(child_kind), child_schema)
	s.strict = strict
	s.sensitive = sensitive
	s.override_prefix = override_prefix
	s.roots = roots
	s.cmdline = cmdline
	s.user_root = user_root
	return s


## Names of the sub-folders of profile [param id] (its child kinds), sorted.
func child_kinds(id: String) -> PackedStringArray:
	var seen := {}
	for dirs in _tier_dirs(rel_path.path_join(id)).values():
		for d in dirs:
			for sub in DirAccess.get_directories_at(d):
				seen[sub] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


func describe() -> String:
	return "\n".join(describe_lines())


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["DotProfileSet %s (addon '%s', game '%s', %d fields, strict %s)" % [rel_path, addon_name, game, schema.size(), strict]])
	for tier in _tier_dirs():
		for d in _tier_dirs()[tier]:
			out.append("  %s: %s" % [tier, d])
	return out


# --- Internals -------------------------------------------------------------

func _id_ok(id: String) -> bool:
	return not (id.strip_edges().is_empty() or id.contains("/") or id.contains("\\") or id.contains(":") or id.contains(".."))


func _roots() -> PackedStringArray:
	return roots if not roots.is_empty() else default_roots()


## tier -> existing directories for [param rel], weakest root first.
func _tier_dirs(rel: String = "") -> Dictionary:
	if rel == "":
		rel = rel_path
	var out := {TIER_ADDON: [], TIER_GAME: [], TIER_USER: [], TIER_SERVER: []}
	if user_tier_enabled:
		var ud := user_root.path_join(TIER_USER).path_join(rel)
		if DirAccess.dir_exists_absolute(ud):
			out[TIER_USER].append(ud)
	for root in _roots():
		var cands := {}
		if addon_name != "":
			cands[TIER_ADDON] = root.path_join("addons").path_join(addon_name).path_join(rel)
		if game != "":
			cands[TIER_GAME] = root.path_join("game").path_join(game).path_join(rel)
		cands[TIER_SERVER] = root.path_join("server").path_join(rel)
		for tier in cands:
			if DirAccess.dir_exists_absolute(cands[tier]):
				out[tier].append(cands[tier])
	return out


## [{path, tier}] for [param id], weakest first.
func _files_for(id: String) -> Array:
	var out: Array = []
	var tiers := _tier_dirs()
	for tier in [TIER_ADDON, TIER_GAME, TIER_USER, TIER_SERVER]:
		for d in tiers[tier]:
			for p in [d.path_join(id + "." + EXTENSION), d.path_join(id).path_join(id + "." + EXTENSION), d.path_join(id).path_join(FOLDER_FILE + "." + EXTENSION)]:
				if FileAccess.file_exists(p):
					out.append({"path": p, "tier": tier})
	return out


func _fail(code: String, id: String, msg: String) -> DotResult:
	DotLog.error(CHANNEL, "profile failed", {"kind": rel_path, "id": id, "why": msg})
	return DotResult.fail(code, "%s/%s: %s" % [rel_path, id, msg])


## File-level resolution: tiers merged, then over its parent. {data, sources, chain}.
func _raw(id: String, visiting: PackedStringArray) -> DotResult:
	if not _id_ok(id):
		return _fail(DotError.CODE_INVALID, id, "bad profile id")
	var files := _files_for(id)
	if files.is_empty():
		return _fail(DotError.CODE_INVALID, id, "no such profile")
	var merged := {}
	var sources := PackedStringArray()
	for f in files:
		var res := DotYaml.parse_file(f["path"])
		if not res.ok:
			DotLog.error(CHANNEL, "bad profile file", {"file": f["path"]})
			return res.wrap("profile file %s" % f["path"])
		if res.value == null:
			continue
		if not (res.value is Dictionary):
			return _fail(DotError.CODE_PARSE, id, "%s must hold a mapping at the top level" % f["path"])
		DotAddonConfig._merge(merged, res.value as Dictionary)
		sources.append("%s: %s" % [f["tier"], f["path"]])
	var chain := PackedStringArray([id])
	var parent: Variant = merged.get(EXTENDS_KEY, "")
	merged.erase(EXTENDS_KEY)
	if not (parent is String):
		return _fail(DotError.CODE_INVALID, id, "extends must be a profile id")
	if parent != "":
		var trail := visiting + PackedStringArray([id])
		if trail.has(parent):
			return _fail(DotError.CODE_INVALID, id, "extends cycle: %s" % " -> ".join(trail + PackedStringArray([parent])))
		var up := _raw(parent, trail)
		if not up.ok:
			return up.wrap("%s/%s extends %s" % [rel_path, id, parent])
		var base: Dictionary = (up.value["data"] as Dictionary).duplicate(true)
		DotAddonConfig._merge(base, merged)
		merged = base
		chain.append_array(up.value["chain"])
		sources = up.value["sources"] + sources
	return DotResult.success({"data": merged, "sources": sources, "chain": chain})


func _load(id: String) -> DotResult:
	var raw := _raw(id, PackedStringArray())
	if not raw.ok:
		return raw
	var data: Dictionary = raw.value["data"]
	var errors := PackedStringArray()
	var values := {}
	var names := {}
	for f in schema:
		names[f["name"]] = f
	var extra: Variant = data.get(EXTRA_KEY, {})
	if not (extra is Dictionary):
		errors.append("'%s' must be a mapping" % EXTRA_KEY)
		extra = {}
	if strict:
		for k in data:
			if k != EXTRA_KEY and not names.has(k):
				errors.append("unknown key '%s' (put it under '%s:')" % [k, EXTRA_KEY])
	var overrides := PackedStringArray()
	var refused := PackedStringArray()
	var supplied := {}
	for k in names:
		supplied[k] = data.has(k)
	for k in names:
		var f: Dictionary = names[k]
		var v: Variant = data[k] if data.has(k) else f.get("default")
		if v is Dictionary or v is Array:
			v = v.duplicate(true)
		var o := _override(id, k, f, v, overrides, refused)
		if o != null:
			v = o["value"]
			supplied[k] = true
		values[k] = v
	for path in runtime.get(id, {}):
		var parts: PackedStringArray = String(path).split(".")
		if parts[0] == EXTRA_KEY and parts.size() > 1 and extra is Dictionary:
			_set_path(extra, parts.slice(1), runtime[id][path])
		elif names.has(parts[0]):
			if parts.size() == 1:
				values[parts[0]] = runtime[id][path]
			elif values[parts[0]] is Dictionary:
				_set_path(values[parts[0]], parts.slice(1), runtime[id][path])
			supplied[parts[0]] = true
	for k in names:
		var f: Dictionary = names[k]
		if f.get("required", false) and not supplied[k]:
			errors.append("%s: required" % k)
			continue
		var checked := _check_field(f, values[k])
		if checked.has("error"):
			errors.append("%s: %s" % [k, checked["error"]])
		else:
			values[k] = checked["value"]
	if not errors.is_empty():
		return _fail(DotError.CODE_INVALID, id, "; ".join(errors))
	var p := DotProfile.new()
	p.id = id
	p.set_ref = self
	p.values = values
	p.extra = (extra as Dictionary).duplicate(true)
	p.chain = raw.value["chain"]
	p.sources = raw.value["sources"]
	p.overrides = overrides
	p.refused = refused
	DotLog.debug(CHANNEL, "loaded", {"kind": rel_path, "id": id, "files": p.sources.size(), "overrides": overrides.size()})
	return DotResult.success(p)


## {value} when environment or command line set [param key], else null.
func _override(id: String, key: String, f: Dictionary, current: Variant, overrides: PackedStringArray, refused: PackedStringArray) -> Variant:
	if f["type"] == "dict":
		return null
	var env_name := ("%s_%s_%s_%s" % [override_prefix, rel_path, id, key]).to_upper().replace("-", "_").replace(".", "_").replace("/", "_")
	var cli := "--%s.%s/%s.%s" % [override_prefix, rel_path, id, key]
	var raw: Variant = null
	var from := ""
	if OS.has_environment(env_name):
		raw = OS.get_environment(env_name)
		from = "env " + env_name
	var argv := cmdline if not cmdline.is_empty() else OS.get_cmdline_user_args() + OS.get_cmdline_args()
	for i in argv.size():
		var a: String = argv[i]
		if a.begins_with(cli + "="):
			raw = a.substr(cli.length() + 1)
			from = "cli " + cli
		elif a == cli and i + 1 < argv.size() and not String(argv[i + 1]).begins_with("--"):
			raw = argv[i + 1]
			from = "cli " + cli
	if raw == null:
		return null
	if DotAddonConfig._is_sensitive(key, sensitive):
		refused.append("%s (%s)" % [key, from])
		DotLog.warn(CHANNEL, "secret refused from environment/argv", {"kind": rel_path, "id": id, "key": key})
		return null
	var proto: Variant = current
	if proto == null:
		proto = {"int": 0, "float": 0.0, "string": "", "bool": false, "list": []}.get(f["type"])
	var coerced: Variant = DotAddonConfig._coerce(str(raw), proto)
	if coerced == null:
		DotLog.warn(CHANNEL, "override has the wrong type", {"kind": rel_path, "id": id, "key": key, "from": from})
		return null
	overrides.append("%s <- %s" % [key, from])
	return {"value": coerced}


static func _flatten(tree: Dictionary, prefix: String, out: Dictionary) -> void:
	for k in tree:
		var key: String = prefix + str(k)
		if tree[k] is Dictionary and (tree[k] as Dictionary).size() > 0 and prefix == "" and str(k) == EXTRA_KEY:
			_flatten(tree[k], key + ".", out)
		else:
			out[key] = tree[k]


static func _set_path(root: Dictionary, parts: PackedStringArray, value: Variant) -> void:
	var at := root
	for i in parts.size() - 1:
		if not (at.get(parts[i]) is Dictionary):
			at[parts[i]] = {}
		at = at[parts[i]]
	at[parts[parts.size() - 1]] = value.duplicate(true) if value is Array or value is Dictionary else value


## False when [param v] is, or holds, NaN or infinity.
static func _finite(v: Variant) -> bool:
	if v is float:
		return is_finite(v)
	if v is Array:
		for e in v:
			if not _finite(e):
				return false
	elif v is Dictionary:
		for k in v:
			if not _finite(v[k]):
				return false
	return true


## {value} or {error} after type, enum and range checks.
func _check_field(f: Dictionary, v: Variant) -> Dictionary:
	var t: String = f["type"]
	var out: Variant = v
	if v == null and not f.get("required", false) and f.get("default") == null:
		return {"value": null}
	match t:
		"int":
			if v is int:
				out = v
			elif v is float and is_finite(v) and v == floorf(v):
				out = int(v)
			else:
				return {"error": "expected int, got %s" % str(v)}
		"float":
			if (v is int or v is float) and _finite(v):
				out = float(v)
			else:
				return {"error": "expected float, got %s" % str(v)}
		"string":
			if v is String or v is StringName:
				out = String(v)
			else:
				return {"error": "expected string, got %s" % str(v)}
		"bool":
			if not (v is bool):
				return {"error": "expected bool, got %s" % str(v)}
		"list":
			if not (v is Array):
				return {"error": "expected list, got %s" % str(v)}
		"dict":
			if not (v is Dictionary):
				return {"error": "expected mapping, got %s" % str(v)}
		"any":
			pass
		_:
			return {"error": "schema type '%s' is unknown" % t}
	if t == "int" or t == "float":
		if f.has("min") and out < f["min"]:
			return {"error": "%s is below min %s" % [str(out), str(f["min"])]}
		if f.has("max") and out > f["max"]:
			return {"error": "%s is above max %s" % [str(out), str(f["max"])]}
	if f.has("enum") and not (f["enum"] as Array).has(out):
		return {"error": "%s is not one of %s" % [str(out), str(f["enum"])]}
	return {"value": out}
