extends Node

## The `box` kind: defaults, round trip through yml, validation of the dict keys, per-server override, live edit with rollback.

const SECTIONS := 5
const CHECKS := 28
const BASE := "user://box_profile_selftest"

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_clean()
	_defaults()
	_validation()
	_server_override()
	_live_edit()
	_check_tool()
	_clean()
	print("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	var bad := _failed > 0 or _section_count != SECTIONS or _passed + _failed != CHECKS
	if bad:
		print("ERROR: expected %d sections %d checks" % [SECTIONS, CHECKS])
	get_tree().quit(1 if bad else 0)


func _mk() -> DotProfileSet:
	var s := DotBoxProfiles.make_set("mygame", PackedStringArray([BASE]))
	s.override_prefix = "bps"
	return s


func _w(rel: String, text: String) -> void:
	var path := BASE.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean() -> void:
	OS.move_to_trash(ProjectSettings.globalize_path(BASE)) if DirAccess.dir_exists_absolute(BASE) else null


func _section(t: String) -> void:
	_section_count += 1
	print("-- " + t)


func _ck(c: bool, what: String) -> void:
	if c:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL  " + what)


func _defaults() -> void:
	_section("defaults and a round trip")
	_w("game/mygame/box/med.yml", "title: Medical\ncolour: '#44aa44'\npolarity: positive\ndrop:\n  common: 5\n  brute: 3\nduration:\n  mode: seconds\n  min: 30\n  max: 60\noutcomes:\n  - id: heal\n    weight: 3\n    actions:\n      - do: heal\n")
	var s := _mk()
	var res := DotBoxProfiles.load_box(s, "med")
	_ck(res.ok, "a box loads")
	var p: DotProfile = res.value
	_ck(p.get_value("title") == "Medical" and p.get_value("polarity") == "positive", "keys read back")
	_ck(p.get_value("impact") == "self" and p.get_value("max_stacks") == 99 and p.get_value("enabled") == true, "schema defaults fill the rest")
	_ck((p.get_value("drop") as Dictionary).get("brute") == 3, "drop odds are a map")
	_ck((p.get_value("outcomes") as Array).size() == 1 and p.get_value("sounds") == {}, "outcomes round trip; no sounds means stock")
	_ck(s.list_ids() == PackedStringArray(["med"]), "listed")
	var tree := {"title": "A \"q\"", "drop": {"common": 2.5, "map": 1}, "stacks": false, "radius": 6.0, "outcomes": [{"id": "x", "weight": 5, "actions": [{"do": "airstrike", "count": 3, "delay": 1.6}, {"do": "random", "choices": [[{"do": "heal"}], [{"do": "mob"}, {"do": "heal"}]]}]}], "sounds": {}}
	_w("game/mygame/box/rt.yml", DotBoxProfiles.to_yaml(tree))
	var back: DotProfile = DotBoxProfiles.load_box(_mk(), "rt").value
	_ck(back.get_value("title") == "A \"q\"" and back.get_value("drop") == {"common": 2.5, "map": 1} and DotBoxProfiles.unwrap_lists(back.get_value("outcomes")) == tree["outcomes"] and back.get_value("radius") == 6.0, "to_yaml reads back as the same tree")


func _validation() -> void:
	_section("validation")
	var cases := {
		"badpol": "polarity: nasty\n",
		"badmode": "duration:\n  mode: forever\n",
		"nosec": "duration:\n  mode: seconds\n  min: 0\n  max: 0\n",
		"reversed": "duration:\n  mode: seconds\n  min: 9\n  max: 3\n",
		"baddrop": "drop:\n  zombie: 3\n",
		"negdrop": "drop:\n  common: -1\n",
		"badevent": "sounds:\n  explode:\n    volume: 1\n",
		"badvol": "sounds:\n  open:\n    volume: 9\n",
		"badmode2": "sounds:\n  open:\n    mode: 4d\n",
		"badkey": "sounds:\n  open:\n    loudness: 1\n",
	}
	for k in cases:
		_w("game/mygame/box/%s.yml" % k, cases[k])
	var s := _mk()
	var wrong := 0
	for k in cases:
		if DotBoxProfiles.load_box(s, k).ok:
			wrong += 1
			print("  accepted: " + k)
	_ck(wrong == 0, "all ten bad files are refused")
	_w("game/mygame/box/good.yml", "duration:\n  mode: round\nsounds:\n  effect_end:\n    sound: res://a.ogg\n    volume: 1.5\n    pitch_jitter: 0.1\n    mode: ui\n  open:\n    enabled: false\n")
	_ck(DotBoxProfiles.load_box(_mk(), "good").ok, "a sound slot per event with every key is accepted")
	var r := DotBoxProfiles.load_box(s, "badvol")
	_ck(not r.ok and str(r.error.detail).contains("volume"), "the refusal names the key")


func _server_override() -> void:
	_section("per-server override")
	_w("game/mygame/box/srv.yml", "title: Shipped\ndrop:\n  common: 4\nsounds:\n  open:\n    volume: 1.0\n")
	_w("server/game/mygame/box/srv.yml", "title: Ours\nsounds:\n  open:\n    volume: 2.5\n")
	var p: DotProfile = DotBoxProfiles.load_box(_mk(), "srv").value
	_ck(p.get_value("title") == "Ours", "the server tier wins")
	_ck((p.get_value("sounds") as Dictionary)["open"]["volume"] == 2.5, "down to one slot's volume")
	_ck((p.get_value("drop") as Dictionary)["common"] == 4, "keys the server file omits keep the game's")


func _live_edit() -> void:
	_section("live edit through the runtime")
	_w("game/mygame/box/live.yml", "title: Live\n")
	var s := _mk()
	var rt := DotProfileRuntime.new()
	rt.add_set(s)
	rt.save_root = BASE
	rt.permit = func(_a: Variant, _f: String) -> bool: return true
	var ok := rt.handle_request("admin", DotProfileRuntime.make_request("set", "box", "live", "sounds.reward.volume", 3.0))
	_ck(ok.ok and (DotBoxProfiles.load_box(s, "live").value.get_value("sounds") as Dictionary)["reward"]["volume"] == 3.0, "a slot's volume is editable live")
	var bad := rt.handle_request("admin", DotProfileRuntime.make_request("set", "box", "live", "sounds.reward.volume", 99.0))
	_ck(not bad.ok, "an out-of-range slot value is refused")
	_ck((DotBoxProfiles.load_box(s, "live").value.get_value("sounds") as Dictionary)["reward"]["volume"] == 3.0, "and rolled back")
	var bad2 := rt.handle_request("admin", DotProfileRuntime.make_request("set", "box", "live", "duration", {"mode": "seconds", "min": 5, "max": 2}))
	_ck(not bad2.ok, "a reversed duration is refused")
	_ck(rt.handle_request("admin", DotProfileRuntime.make_request("set", "box", "live", "drop.brute", 9)).ok, "a drop weight is editable")


func _check_tool() -> void:
	_section("schemas for tools")
	var ps := DotBoxProfiles.profile_schemas()
	_ck(ps.has("box") and (ps["box"]["schema"] as Array).size() == DotBoxProfiles.schema().size(), "profile_schemas names the kind")
	var names := (DotBoxProfiles.schema() as Array).map(func(f: Dictionary) -> String: return f["name"])
	for k in ["title", "colour", "drop", "duration", "outcomes", "sounds", "open_seconds", "lifetime", "enabled"]:
		_ck(k in names, "schema has " + k)
