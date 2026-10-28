extends SceneTree

## Checks every profile yml under a repository's cfg/ against its schema, with no game running, and exits 1 on any error.
## Run: godot --headless --path . --script addons/dot_profile/tools/profile_check.gd -- <dir>... [--schema <script>]... [--skip-unknown]
## Loads every profile through [DotProfileSet] (the game's own verdict); schemas come from global classes with [code]static func profile_schemas()[/code] or [code]--schema[/code]; no [code]class_name[/code].

var _providers: Dictionary = {}
var _seen_scripts := {}
var _skip_unknown := false
var _errors := PackedStringArray()
var _files := 0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	var dirs := PackedStringArray()
	var args := OS.get_cmdline_user_args()
	var explicit := PackedStringArray()
	var i := 0
	while i < args.size():
		match args[i]:
			"--skip-unknown":
				_skip_unknown = true
			"--schema":
				i += 1
				if i < args.size():
					explicit.append(args[i])
			_:
				dirs.append(args[i])
		i += 1
	_discover_providers()
	for e in explicit:
		_load_provider_script(e)
	if dirs.is_empty():
		_error("(arguments)", "give at least one repository or cfg directory")
	for d in dirs:
		_check_root(_absolute(d))
	for e in _errors:
		print(e)
	print("PROFILE_CHECK files %d errors %d" % [_files, _errors.size()])
	quit(1 if not _errors.is_empty() else 0)


func _absolute(p: String) -> String:
	if p.begins_with("/") or p.begins_with("res://") or p.begins_with("user://"):
		return p
	return (OS.get_environment("PWD").path_join(p) if OS.get_environment("PWD") != "" else p).simplify_path()


func _subdirs(dir: String) -> PackedStringArray:
	return DirAccess.get_directories_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray()


func _error(path: String, msg: String) -> void:
	_errors.append("%s: %s" % [path, msg])


func _class_script(cls: String) -> Script:
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == cls:
			return load(c["path"])
	return null


## Class cache scan; the text pre-filter keeps it from loading every script of a game.
func _discover_providers() -> void:
	for c in ProjectSettings.get_global_class_list():
		var path: String = c["path"]
		if FileAccess.get_file_as_string(path).contains("static func profile_schemas("):
			_register(load(path), path)


func _load_provider_script(path: String) -> void:
	var s: Variant = load(path) if path.contains("://") else _class_script(path)
	if s == null:
		s = load(_absolute(path))
	if not (s is Script) or not (s as Script).has_method("profile_schemas"):
		_error(path, "--schema needs a script with static profile_schemas()")
		return
	_register(s, path)


func _register(s: Script, label: String) -> void:
	if s == null or not s.has_method("profile_schemas"):
		_error(label, "provider script does not load or has no static profile_schemas()")
		return
	if _seen_scripts.has(s.resource_path):
		return
	_seen_scripts[s.resource_path] = true
	var d: Variant = s.call("profile_schemas")
	if not (d is Dictionary):
		_error(label, "profile_schemas() must return a Dictionary of kind to schema")
		return
	for kind in d:
		var v: Variant = d[kind]
		var entry: Variant = v if v is Dictionary else {"schema": v, "children": {}}
		if not _valid_entry(entry):
			_error(label, "profile_schemas() kind '%s': need a field Array, or {\"schema\": Array, \"children\": {name: Array}}" % kind)
			continue
		if _providers.has(kind):
			_error(label, "kind '%s' is also provided by %s" % [kind, _providers[kind]["source"]])
			continue
		_providers[kind] = {"schema": entry["schema"], "children": entry.get("children", {}), "source": label, "validator": entry.get("validator", Callable())}


func _valid_entry(entry: Variant) -> bool:
	if not (entry is Dictionary) or not (entry.get("schema") is Array):
		return false
	var kids: Variant = entry.get("children", {})
	if not (kids is Dictionary):
		return false
	for k in kids:
		if not (kids[k] is Array):
			return false
	return true


func _check_root(dir: String) -> void:
	var cfg := dir.path_join("cfg") if DirAccess.dir_exists_absolute(dir.path_join("cfg")) else dir
	if not DirAccess.dir_exists_absolute(cfg):
		_error(dir, "no such directory")
		return
	# The plural names are the shimmed layout; they are walked too, as the same tiers.
	for bucket in ["addon", "addons"]:
		for a in _subdirs(cfg.path_join(bucket)):
			_check_tier(cfg, "addon", a, cfg.path_join(bucket).path_join(a))
	for bucket in ["game", "games"]:
		for g in _subdirs(cfg.path_join(bucket)):
			_check_tier(cfg, "game", g, cfg.path_join(bucket).path_join(g))
	for bucket in ["server/addon", "server/addons"]:
		for a in _subdirs(cfg.path_join(bucket)):
			_check_tier(cfg, "server", a, cfg.path_join(bucket).path_join(a))
	for bucket in ["server/game", "server/games"]:
		for g in _subdirs(cfg.path_join(bucket)):
			_check_tier(cfg, "server", g, cfg.path_join(bucket).path_join(g))
	# Pre-mirror layout; these are the mirror's folders, not kinds.
	for kind in _subdirs(cfg.path_join("server")):
		if not kind in ["addon", "addons", "game", "games"]:
			_check_tier_kind(cfg, "server", "", cfg.path_join("server"), kind)


func _check_tier(cfg: String, tier: String, owner_name: String, dir: String) -> void:
	for kind in _subdirs(dir):
		_check_tier_kind(cfg, tier, owner_name, dir, kind)


func _check_tier_kind(cfg: String, tier: String, owner_name: String, dir: String, kind: String) -> void:
	if not _providers.has(kind):
		# A folder named after an addon the project links is that addon's own config (DotAddonConfig), not a profile kind.
		if DirAccess.dir_exists_absolute(cfg.get_base_dir().path_join("addons").path_join(kind)):
			return
		if not _skip_unknown:
			_error(dir.path_join(kind), "no schema for kind '%s' (add --schema, or a typo; --skip-unknown ignores it)" % kind)
		return
	var ctx := {"cfg": cfg, "tier": tier, "owner": owner_name, "server_owner": "addons" if (dir.contains("/server/addon/") or dir.contains("/server/addons/")) else ("game" if (dir.contains("/server/game/") or dir.contains("/server/games/")) else "")}
	_check_dir(ctx, dir.path_join(kind), kind, _providers[kind]["schema"], _providers[kind]["children"])


func _check_dir(ctx: Dictionary, dir: String, rel: String, schema: Array, children: Dictionary) -> void:
	var ids := {}
	var folded := {}
	for f in DirAccess.get_files_at(dir):
		var ext := f.get_extension().to_lower()
		if ext == "yaml":
			_error(dir.path_join(f), "a .yaml file is never read; rename it to .yml")
		elif ext == DotProfileSet.EXTENSION:
			_add_id(ids, folded, dir, f.get_basename(), dir.path_join(f))
	for sub in DirAccess.get_directories_at(dir):
		var own := ""
		for n in [sub, DotProfileSet.FOLDER_FILE]:
			var p := dir.path_join(sub).path_join(n + "." + DotProfileSet.EXTENSION)
			if FileAccess.file_exists(p):
				if own != "":
					_error(p, "folder profile '%s' has both %s.yml and %s.yml" % [sub, sub, DotProfileSet.FOLDER_FILE])
				own = own if own != "" else p
		if own != "":
			_add_id(ids, folded, dir, sub, own)
		else:
			_error(dir.path_join(sub), "folder has no %s.yml or %s.yml" % [sub, DotProfileSet.FOLDER_FILE])
	var ids_sorted := ids.keys()
	ids_sorted.sort()
	for id in ids_sorted:
		_check_profile(ctx, dir, rel, schema, id, ids[id])
		if DirAccess.dir_exists_absolute(dir.path_join(id)):
			for child in DirAccess.get_directories_at(dir.path_join(id)):
				if children.has(child):
					_check_dir(ctx, dir.path_join(id).path_join(child), rel.path_join(id).path_join(child), children[child], {})
				else:
					_error(dir.path_join(id).path_join(child), "no child schema for '%s' under a %s profile" % [child, rel.get_file()])


func _add_id(ids: Dictionary, folded: Dictionary, dir: String, id: String, file: String) -> void:
	if ids.has(id):
		_error(file, "duplicate id '%s' (also %s)" % [id, ids[id]])
		return
	if folded.has(id.to_lower()):
		_error(file, "id '%s' differs from '%s' only by case" % [id, folded[id.to_lower()]])
	folded[id.to_lower()] = id
	ids[id] = file


func _first_dir(cfg: String, buckets: Array, rel: String) -> String:
	for bucket in buckets:
		var base := cfg.path_join(bucket)
		for d in _subdirs(base):
			if DirAccess.dir_exists_absolute(base.path_join(d).path_join(rel)):
				return d
	return ""


## A set seeing the file's own tier plus the weaker tiers it may override or extend.
func _check_profile(ctx: Dictionary, _dir: String, rel: String, schema: Array, id: String, file: String) -> void:
	_files += 1
	var tier: String = ctx["tier"]
	var so: String = ctx.get("server_owner", "")
	var addon: String = ctx["owner"] if (tier == "addon" or so == "addons") else _first_dir(ctx["cfg"], ["addon", "addons"], rel)
	var game: String = ctx["owner"] if (tier == "game" or so == "game") else ("" if tier == "addon" else _first_dir(ctx["cfg"], ["game", "games"], rel))
	var s := DotProfileSet.create(addon, game, rel, schema)
	s.roots = PackedStringArray([ctx["cfg"]])
	s.cmdline = PackedStringArray(["--"])
	s.override_prefix = "profile_check_unused"
	if _providers.has(rel):
		s.validator = _providers[rel].get("validator", Callable())
	var res := s.load_profile(id)
	if not res.ok:
		_error(file, res.error.message + ((": " + res.error.detail) if res.error.detail != "" else ""))
