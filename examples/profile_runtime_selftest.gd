extends Node

## Exercises [DotProfileRuntime]: validated, permission-gated, replicated runtime profile edits.
##
## [codeblock]
## godot --headless --path . res://examples/profile_runtime_selftest.tscn
## [/codeblock]

const SECTIONS := 9
const CHECKS := 63
const BASE := "user://profile_runtime_selftest"

var _passed := 0
var _failed := 0
var _section_count := 0
var _records: Array = []
var _sink := Callable()
var _sent: Array = []
var _private: Array = []
var _changes: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	DotLog.print_to_stdout = false
	_sink = _on_record
	DotLog.add_sink(_sink)
	_run()


func _on_record(rec: Dictionary) -> void:
	_records.append(rec)


func _run() -> void:
	_line("dot-core profile runtime self-test")
	_clean()
	_test_edit()
	_test_refused()
	_test_permission()
	_test_revisions()
	_test_late_join()
	_test_reset()
	_test_save()
	_test_audit()
	_test_nested()
	_clean()
	DotLog.remove_sink(_sink)

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _schema() -> Array:
	return [
		DotProfileSet.field("health", "int", 100, {"min": 1, "max": 1000}),
		DotProfileSet.field("speed", "float", 3.0, {"min": 0.0, "max": 50.0}),
		DotProfileSet.field("mode", "string", "melee", {"enum": ["melee", "ranged"]}),
		DotProfileSet.field("boss", "bool", false),
		DotProfileSet.field("loot", "list", []),
		DotProfileSet.field("stats", "dict", {}),
		DotProfileSet.field("api_token", "string", ""),
	]


## Fresh files, a server runtime on one side, a client on the other.
func _world() -> Dictionary:
	_clean()
	_w("addons/dot-npc/npc/zombie.yml", "health: 50\nspeed: 2.5\n")
	_w("addons/dot-npc/npc/ghoul.yml", "health: 20\n")
	var server_set := _mk()
	var client_set := _mk()
	var server := DotProfileRuntime.new()
	server.add_set(server_set)
	server.save_root = BASE
	server.permit = func(actor: Variant, flag: String) -> bool: return actor == "admin" or (actor == "mod" and flag == "cvar")
	server.broadcast = func(row: Dictionary) -> void: _sent.append(row)
	server.send_to = func(peer: Variant, row: Dictionary) -> void: _private.append([peer, row])
	var client := DotProfileRuntime.new()
	client.add_set(client_set)
	_sent.clear()
	_private.clear()
	_changes.clear()
	client.profile_changed.connect(func(k: String, i: String, r: int) -> void: _changes.append([k, i, r]))
	return {"server": server, "client": client, "ss": server_set, "cs": client_set}


func _mk() -> DotProfileSet:
	var s := DotProfileSet.create("dot-npc", "mygame", "npc", _schema())
	s.roots = PackedStringArray([BASE])
	s.override_prefix = "prt"
	return s


func _req(op: String, id: String, key: String = "", value: Variant = null) -> Dictionary:
	return DotProfileRuntime.make_request(op, "npc", id, key, value)


func _val(set: DotProfileSet, id: String, key: String) -> Variant:
	return set.load_profile(id).value.get_value(key)


func _test_edit() -> void:
	_section("a valid edit is applied, broadcast and signalled")
	var w := _world()
	var server: DotProfileRuntime = w["server"]
	var res := server.handle_request("admin", _req("set", "zombie", "health", 400))
	_check(res.ok, "admin edit accepted")
	_check(_val(w["ss"], "zombie", "health") == 400, "runtime value wins over the file's 50")
	_check(_val(w["ss"], "ghoul", "health") == 20, "another profile is untouched")
	_check(server.revision("npc", "zombie") == 1 and res.value["rev"] == 1, "revision is 1")
	_check(_sent.size() == 1 and _sent[0]["paths"] == {"health": 400}, "the row was broadcast")
	var res2: DotResult = server.handle_request("admin", _req("set", "zombie", "speed", 7))
	_check(res2.ok and _val(w["ss"], "zombie", "speed") == 7.0 and _val(w["ss"], "zombie", "speed") is float, "an int is coerced to a float field")
	var seen: Array = []
	server.profile_changed.connect(func(k: String, i: String, r: int) -> void: seen.append([k, i, r]))
	server.handle_request("admin", _req("set", "zombie", "mode", "ranged"))
	_check(seen == [["npc", "zombie", 3]], "profile_changed(kind, id, revision) fired")
	var again := server.handle_request("admin", _req("set", "zombie", "mode", "ranged"))
	_check(again.ok and again.value["changed"] == false and server.revision("npc", "zombie") == 3, "an identical edit is a no-op")


func _test_refused() -> void:
	_section("invalid edits are refused with a code and change nothing")
	var w := _world()
	var server: DotProfileRuntime = w["server"]
	var cases := {
		"above max": ["health", 5000], "below min": ["health", 0], "wrong type": ["health", "lots"],
		"fractional int": ["health", 2.5], "NaN": ["speed", NAN], "inf": ["speed", INF],
		"enum": ["mode", "flying"], "unknown key": ["wings", 2], "list holding NaN": ["loot", [1.0, NAN]],
		"secret": ["api_token", "x"], "bad path": ["health.", 1], "bare extra": ["extra", 1],
		"nested into a scalar": ["health.x", 1],
	}
	for name in cases:
		var r := server.handle_request("admin", _req("set", "zombie", cases[name][0], cases[name][1]))
		var code := "" if r.ok else r.error.code
		_check(not r.ok and (code == DotError.CODE_INVALID or code == DotError.CODE_FORBIDDEN), "%s refused (%s)" % [name, code])
	_check(server.revision("npc", "zombie") == 0 and _sent.is_empty(), "no revision bump and nothing broadcast")
	_check(_val(w["ss"], "zombie", "health") == 50, "the profile is unchanged")
	var missing := server.handle_request("admin", _req("set", "nobody", "health", 5))
	_check(not missing.ok and missing.error.code == DotError.CODE_INVALID, "unknown profile refused")
	var kind := server.handle_request("admin", DotProfileRuntime.make_request("set", "weapon", "x", "health", 5))
	_check(not kind.ok and kind.error.code == DotError.CODE_INVALID, "unknown kind refused")
	var op := server.handle_request("admin", _req("explode", "zombie"))
	_check(not op.ok and op.error.code == DotError.CODE_INVALID, "unknown op refused")


func _test_permission() -> void:
	_section("permission gate")
	var w := _world()
	var server: DotProfileRuntime = w["server"]
	var r := server.handle_request("guest", _req("set", "zombie", "health", 400))
	_check(not r.ok and r.error.code == DotError.CODE_FORBIDDEN, "a player without the flag is forbidden")
	_check(_val(w["ss"], "zombie", "health") == 50 and _sent.is_empty(), "nothing applied or sent")
	_check(server.handle_request("mod", _req("set", "zombie", "health", 400)).ok, "the edit flag is enough to edit")
	var save := server.handle_request("mod", _req("save", "zombie"))
	_check(not save.ok and save.error.code == DotError.CODE_FORBIDDEN, "saving needs the stronger flag")
	var none := DotProfileRuntime.new()
	none.add_set(w["ss"])
	_check(none.handle_request("admin", _req("set", "zombie", "health", 9)).error.code == DotError.CODE_FORBIDDEN, "no permit callable denies everything")
	var denied: Array = _records.filter(func(rec: Dictionary) -> bool: return rec["message"] == "profile edit denied")
	_check(denied.size() >= 3, "denials are logged")


func _test_revisions() -> void:
	_section("client applies only newer revisions")
	var w := _world()
	var server: DotProfileRuntime = w["server"]
	var client: DotProfileRuntime = w["client"]
	server.handle_request("admin", _req("set", "zombie", "health", 100))
	server.handle_request("admin", _req("set", "zombie", "health", 200))
	var r1: Dictionary = _sent[0]
	var r2: Dictionary = _sent[1]
	_check(client.apply_row(r2).value == true and _val(w["cs"], "zombie", "health") == 200, "the newer row applies")
	_check(client.apply_row(r1).value == false and _val(w["cs"], "zombie", "health") == 200, "the older row, arriving late, is dropped")
	_check(client.apply_row(r2).value == false, "a duplicate is dropped")
	_check(client.revision("npc", "zombie") == 2 and _changes == [["npc", "zombie", 2]], "one change signalled at revision 2")
	_check(not client.apply_row({"kind": "npc", "id": "zombie", "rev": 9}).ok, "a malformed row is refused")
	var bad := client.apply_row({"kind": "npc", "id": "zombie", "rev": 9, "paths": {"health": 99999}})
	_check(not bad.ok and _val(w["cs"], "zombie", "health") == 200 and client.revision("npc", "zombie") == 2, "a row that breaks the schema is rolled back")


func _test_late_join() -> void:
	_section("a late joiner receives the full runtime layer")
	var w := _world()
	var server: DotProfileRuntime = w["server"]
	server.handle_request("admin", _req("set", "zombie", "health", 300))
	server.handle_request("admin", _req("set", "zombie", "boss", true))
	server.handle_request("admin", _req("set", "ghoul", "speed", 9.5))
	server.handle_request("admin", _req("reset", "ghoul"))
	var late := DotProfileRuntime.new()
	var late_set := _mk()
	late.add_set(late_set)
	server.send_snapshot(7)
	_check(_private.size() == 2 and _private[0][0] == 7, "one row per edited profile, to that peer")
	for p in _private:
		late.apply_row(p[1])
	_check(_val(late_set, "zombie", "health") == 300 and _val(late_set, "zombie", "boss") == true, "zombie edits arrived together")
	_check(_val(late_set, "ghoul", "speed") == 3.0 and late.revision("npc", "ghoul") == 2, "a reset profile arrives empty at its revision")
	late.begin_sync()
	_check(_val(late_set, "zombie", "health") == 50 and late.revision("npc", "zombie") == 0, "begin_sync forgets everything")
	_check(late.apply_row(server.snapshot()[0]).value == true, "a snapshot applies again after begin_sync")


func _test_reset() -> void:
	_section("reset key and reset profile")
	var w := _world()
	var server: DotProfileRuntime = w["server"]
	server.handle_request("admin", _req("set", "zombie", "health", 300))
	server.handle_request("admin", _req("set", "zombie", "speed", 9.0))
	var r := server.handle_request("admin", _req("reset_key", "zombie", "health"))
	_check(r.ok and _val(w["ss"], "zombie", "health") == 50 and _val(w["ss"], "zombie", "speed") == 9.0, "reset_key restores only that key")
	_check(server.revision("npc", "zombie") == 3, "reset_key bumps the revision")
	_check(server.handle_request("admin", _req("reset_key", "zombie", "health")).value["changed"] == false, "resetting an unedited key is a no-op")
	var all := server.handle_request("admin", _req("reset", "zombie"))
	_check(all.ok and _val(w["ss"], "zombie", "speed") == 2.5 and w["ss"].runtime_paths("zombie").is_empty(), "reset restores the file values")
	_check(_sent[_sent.size() - 1]["paths"] == {} and _sent[_sent.size() - 1]["rev"] == 4, "the empty row replicates the reset")


func _test_save() -> void:
	_section("save writes only the changed keys")
	var w := _world()
	var server: DotProfileRuntime = w["server"]
	server.handle_request("admin", _req("set", "zombie", "health", 300))
	server.handle_request("admin", _req("set", "zombie", "mode", "ranged"))
	server.handle_request("admin", _req("set", "zombie", "loot", ["coin", "gem"]))
	server.handle_request("admin", _req("set", "zombie", "stats.armor", 2))
	server.handle_request("admin", _req("set", "zombie", "extra.sound.growl", "low \"mean\""))
	var r := server.handle_request("admin", _req("save", "zombie"))
	_check(r.ok, "saved")
	var file: String = BASE.path_join("server/npc/zombie.yml")
	var parsed := DotYaml.parse_file(file)
	_check(parsed.ok and (parsed.value as Dictionary).keys().size() == 5, "five keys, not the whole profile")
	_check(not (parsed.value as Dictionary).has("speed") and not (parsed.value as Dictionary).has("boss"), "unedited keys are absent")
	var fresh := _mk()
	var p: DotProfile = fresh.load_profile("zombie").value
	_check(p.get_value("health") == 300 and p.get_value("mode") == "ranged" and p.get_value("loot") == ["coin", "gem"], "the file loads back as the same values")
	_check(p.get_value("stats") == {"armor": 2} and p.get_extra("sound.growl") == "low \"mean\"", "nested and extra paths round trip")
	_check(p.get_value("speed") == 2.5, "keys from lower tiers still show through")
	server.handle_request("admin", _req("reset", "zombie"))
	_check(server.handle_request("admin", _req("save", "zombie")).error.code == DotError.CODE_STATE, "nothing to save after a reset")
	server.handle_request("admin", _req("set", "zombie", "speed", 4.0))
	server.handle_request("admin", _req("save", "zombie"))
	var merged := DotYaml.parse_file(file).value as Dictionary
	_check(merged.size() == 6 and merged["speed"] == 4.0 and merged["health"] == 300, "a second save keeps the earlier server keys")


func _test_audit() -> void:
	_section("audit line")
	var w := _world()
	var server: DotProfileRuntime = w["server"]
	server.actor_name = func(actor: Variant) -> String: return "name:" + str(actor)
	_records.clear()
	server.handle_request("admin", _req("set", "zombie", "health", 400))
	var lines: Array = _records.filter(func(rec: Dictionary) -> bool: return rec["message"] == "profile edited")
	_check(lines.size() == 1, "one INFO line per edit")
	var f: Dictionary = lines[0]["fields"] if lines.size() > 0 else {}
	_check(lines.size() > 0 and lines[0]["level"] == DotLog.Level.INFO and lines[0]["channel"] == "profile", "INFO on channel profile")
	_check(f.get("who") == "name:admin" and f.get("key") == "health" and f.get("old") == "50" and f.get("new") == "400" and f.get("rev") == 1, "who, what, old, new and revision are in it")
	_records.clear()
	server.handle_request("admin", _req("set", "zombie", "health", 9999))
	_check(_records.any(func(rec: Dictionary) -> bool: return rec["message"] == "profile edit refused"), "a refused edit is logged too")


func _test_nested() -> void:
	_section("edits survive extends and the cache")
	var w := _world()
	_w("addons/dot-npc/npc/boss.yml", "extends: zombie\nhealth: 500\n")
	var server: DotProfileRuntime = w["server"]
	var before: Variant = _val(w["ss"], "boss", "health")
	server.handle_request("admin", _req("set", "zombie", "health", 1))
	_check(before == 500 and _val(w["ss"], "boss", "health") == 500, "a child's own value is not changed by its parent's runtime edit")
	server.handle_request("admin", _req("set", "boss", "speed", 8.0))
	_check(_val(w["ss"], "boss", "speed") == 8.0 and _val(w["ss"], "boss", "health") == 500, "the child is editable on its own")
	_check(w["ss"].load_profile("boss").value == w["ss"].load_profile("boss").value, "the loaded profile is cached between edits")


# --- Harness -----------------------------------------------------------------

func _w(rel: String, text: String) -> void:
	var path := BASE.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean() -> void:
	_rm(BASE)


func _rm(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_rm(dir.path_join(d))
	DirAccess.remove_absolute(dir)


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
