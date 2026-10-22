extends SceneTree

## Checks every profile yml under a repository's cfg/ against its schema, with no game running.
##
## [codeblock]
## godot --headless --path . --script addons/dot_core/tools/profile_check.gd -- <dir>... [--schema <script>]... [--skip-unknown]
## [/codeblock]
##
## [code]<dir>[/code] is a repository (its [code]cfg/[/code] is read) or a cfg directory. Walks
## [code]cfg/addons/*/<kind>/[/code], [code]cfg/game/*/<kind>/[/code] and [code]cfg/server/<kind>/[/code]
## and loads every profile through [DotProfileSet], so the verdict is the game's own: unknown
## keys (use [code]extra:[/code]), wrong types, out of range, NaN and infinity, a missing or
## cyclic [code]extends[/code], a malformed yml. On top of that: two files for one id,
## [code].yaml[/code] files (never read), a folder profile with no file of its own, and child
## folders with no schema.
##
## [b]Schemas[/b] live in code. Built in: [code]weapon[/code] (with [code]upgrades[/code]) from
## [code]DotWeaponProfiles[/code] and [code]npc[/code] from [code]DotNpcProfiles[/code], found by
## class name when the project links that addon. [code]--schema <script>[/code] adds a script with
## [code]static func profile_schemas() -> Dictionary[/code]: kind to a field Array, or to
## [code]{"schema": [...], "children": {name: [...]}}[/code]. A kind with no schema is an error
## unless [code]--skip-unknown[/code].
##
## Prints one [code]path: message[/code] line per problem and [code]PROFILE_CHECK files N errors M[/code];
## exits 1 on any error. No [code]class_name[/code]: it adds no global.

const KIND_PROVIDERS := {
	"weapon": {"class": "DotWeaponProfiles", "schema": "schema", "children": {"upgrades": "upgrade_schema"}},
	"npc": {"class": "DotNpcProfiles", "schema": "schema", "children": {}},
}

var _providers: Dictionary = {}
var _skip_unknown := false
var _errors := PackedStringArray()
var _files := 0


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	var dirs := PackedStringArray()
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--skip-unknown":
				_skip_unknown = true
			"--schema":
				i += 1
				if i < args.size():
					_load_provider_script(args[i])
			_:
				dirs.append(args[i])
		i += 1
	_load_builtin_providers()
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


func _load_builtin_providers() -> void:
	for kind in KIND_PROVIDERS:
		if _providers.has(kind):
			continue
		var spec: Dictionary = KIND_PROVIDERS[kind]
		var s := _class_script(spec["class"])
		if s == null:
			continue
		var children := {}
		for c in spec["children"]:
			children[c] = s.call(spec["children"][c])
		_providers[kind] = {"schema": s.call(spec["schema"]), "children": children}


func _load_provider_script(path: String) -> void:
	var s: Variant = load(path) if path.contains("://") else _class_script(path)
	if s == null:
		s = load(_absolute(path))
	if not (s is Script) or not (s as Script).has_method("profile_schemas"):
		_error(path, "--schema needs a script with static profile_schemas()")
		return
	var d: Dictionary = (s as Script).call("profile_schemas")
	for kind in d:
		var v: Variant = d[kind]
		_providers[kind] = v if v is Dictionary else {"schema": v, "children": {}}


func _check_root(dir: String) -> void:
	var cfg := dir.path_join("cfg") if DirAccess.dir_exists_absolute(dir.path_join("cfg")) else dir
	if not DirAccess.dir_exists_absolute(cfg):
		_error(dir, "no such directory")
		return
	for a in _subdirs(cfg.path_join("addons")):
		_check_tier(cfg, "addon", a, cfg.path_join("addons").path_join(a))
	for g in _subdirs(cfg.path_join("game")):
		_check_tier(cfg, "game", g, cfg.path_join("game").path_join(g))
	_check_tier(cfg, "server", "", cfg.path_join("server"))


func _check_tier(cfg: String, tier: String, owner_name: String, dir: String) -> void:
	for kind in _subdirs(dir):
		if not _providers.has(kind):
			if not _skip_unknown:
				_error(dir.path_join(kind), "no schema for kind '%s' (add --schema, or a typo; --skip-unknown ignores it)" % kind)
			continue
		var ctx := {"cfg": cfg, "tier": tier, "owner": owner_name}
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


func _first_dir(cfg: String, bucket: String, rel: String) -> String:
	var base := cfg.path_join(bucket)
	for d in _subdirs(base):
		if DirAccess.dir_exists_absolute(base.path_join(d).path_join(rel)):
			return d
	return ""


## A set seeing the file's own tier plus the weaker tiers it may override or extend.
func _check_profile(ctx: Dictionary, _dir: String, rel: String, schema: Array, id: String, file: String) -> void:
	_files += 1
	var tier: String = ctx["tier"]
	var addon: String = ctx["owner"] if tier == "addon" else _first_dir(ctx["cfg"], "addons", rel)
	var game: String = ctx["owner"] if tier == "game" else ("" if tier == "addon" else _first_dir(ctx["cfg"], "game", rel))
	var s := DotProfileSet.create(addon, game, rel, schema)
	s.roots = PackedStringArray([ctx["cfg"]])
	s.cmdline = PackedStringArray(["--"])
	s.override_prefix = "profile_check_unused"
	var res := s.load_profile(id)
	if not res.ok:
		_error(file, res.error.message + ((": " + res.error.detail) if res.error.detail != "" else ""))
