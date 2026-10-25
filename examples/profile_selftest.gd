extends Node

## Exercises [DotProfileSet] and [DotProfile]: schema, extends, tiers, overrides, folders.
##
## [codeblock]
## godot --headless --path . res://examples/profile_selftest.tscn
## [/codeblock]

const SECTIONS := 11
const CHECKS := 90
const BASE := "user://profile_selftest"

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run()


func _run() -> void:
	_line("dot-core profile self-test")
	_clean()
	_test_schema()
	_test_extends()
	_test_merge()
	_test_tiers()
	_test_plural_legacy()
	_test_overrides()
	_test_extra()
	_test_listing()
	_test_folders()
	_test_bad_yml()
	_test_no_cycle()
	_clean()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _schema() -> Array:
	return [
		DotProfileSet.field("name", "string", "unnamed"),
		DotProfileSet.field("health", "int", 100, {"min": 1, "max": 1000}),
		DotProfileSet.field("speed", "float", 3.0, {"min": 0.0}),
		DotProfileSet.field("mode", "string", "melee", {"enum": ["melee", "ranged"]}),
		DotProfileSet.field("boss", "bool", false),
		DotProfileSet.field("loot", "list", []),
		DotProfileSet.field("stats", "dict", {}),
	]


func _mk(kind: String = "npc", schema: Array = []) -> DotProfileSet:
	var s := DotProfileSet.create("dot-npc", "mygame", kind, schema if not schema.is_empty() else _schema())
	s.roots = PackedStringArray([BASE])
	s.override_prefix = "pst"
	return s


func _w(rel: String, text: String) -> void:
	var path := BASE.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _addon(rel: String, text: String) -> void:
	_w("addon/dot-npc/" + rel, text)


func _gamef(rel: String, text: String) -> void:
	_w("game/mygame/" + rel, text)


func _clean() -> void:
	_rm(BASE)


func _rm(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_rm(dir.path_join(d))
	DirAccess.remove_absolute(dir)


func _test_schema() -> void:
	_section("Schema: defaults, types, range, enum, required")
	_addon("npc/ok.yml", "name: Orc\nhealth: 250\nspeed: 2\n")
	_addon("npc/high.yml", "health: 5000\n")
	_addon("npc/enum.yml", "mode: flying\n")
	_addon("npc/type.yml", "health: lots\nboss: 3\n")
	_addon("npc/typo.yml", "helth: 5\n")
	var s := _mk()
	var r := s.load_profile("ok")
	_check(r.ok, "a valid profile loads")
	_check(r.value.get_value("health") == 250 and r.value.get_value("name") == "Orc", "file values read")
	_check(r.value.get_value("mode") == "melee", "a default fills a missing key")
	_check(r.value.get_value("speed") is float and r.value.get_value("speed") == 2.0, "an int in a float field is a float")
	r = s.load_profile("high")
	_check(not r.ok and r.error.code == DotError.CODE_INVALID, "above max is CODE_INVALID")
	_check(r.error.message.contains("health") and r.error.message.contains("max"), "the message names key and bound")
	_check(not s.load_profile("enum").ok, "a value outside the enum fails")
	r = s.load_profile("type")
	_check(not r.ok and r.error.message.contains("health") and r.error.message.contains("boss"), "every error is reported together")
	r = s.load_profile("typo")
	_check(not r.ok and r.error.message.contains("helth"), "an unknown top-level key fails when strict")
	s.strict = false
	_check(s.load_profile("typo").ok, "and passes when not strict")
	var req := _mk("npc", [DotProfileSet.field("id_tag", "string", null, {"required": true})])
	_check(not req.load_profile("ok").ok, "a required key that is absent fails")
	_check(s.load_profile("nope").error.code == DotError.CODE_INVALID, "a missing profile is an error result")
	_check(not s.load_profile("../x").ok, "a path in the id is refused")


func _test_extends() -> void:
	_section("extends and cycles")
	_clean()
	_addon("npc/base.yml", "health: 100\nspeed: 1.5\nname: Base\n")
	_addon("npc/mid.yml", "extends: base\nhealth: 200\n")
	_addon("npc/leaf.yml", "extends: mid\nname: Leaf\n")
	_addon("npc/a.yml", "extends: b\n")
	_addon("npc/b.yml", "extends: c\n")
	_addon("npc/c.yml", "extends: a\n")
	_addon("npc/self.yml", "extends: self\n")
	_addon("npc/orphan.yml", "extends: ghost\n")
	var s := _mk()
	var r := s.load_profile("leaf")
	_check(r.ok, "a two-level chain loads")
	_check(r.value.get_value("health") == 200 and r.value.get_value("speed") == 1.5, "child over parent over grandparent")
	_check(r.value.get_value("name") == "Leaf", "the leaf wins")
	_check(list_eq(r.value.chain, ["leaf", "mid", "base"]), "the chain is recorded")
	r = s.load_profile("a")
	_check(not r.ok and str(r.error).contains("cycle"), "a three-profile cycle is detected")
	r = s.load_profile("self")
	_check(not r.ok and r.error.message.contains("cycle"), "extending itself is a cycle")
	r = s.load_profile("orphan")
	_check(not r.ok and r.error.message.contains("ghost"), "a missing parent names it")


func _test_merge() -> void:
	_section("Deep merge")
	_clean()
	_addon("npc/base.yml", "stats:\n  str: 5\n  dex: 3\nloot: [a, b]\nextra:\n  ai:\n    sight: 10\n    hear: 4\n")
	_addon("npc/kid.yml", "extends: base\nstats:\n  dex: 9\nloot: [z]\nextra:\n  ai:\n    sight: 20\n")
	var r := _mk().load_profile("kid")
	_check(r.ok, "loads")
	_check(r.value.get_value("stats") == {"str": 5, "dex": 9}, "maps merge key by key")
	_check(r.value.get_value("loot") == ["z"], "a list is replaced whole")
	_check(r.value.get_extra("ai.sight") == 20 and r.value.get_extra("ai.hear") == 4, "extra merges deeply too")
	var b := _mk().load_profile("base")
	_check(b.value.get_value("stats") == {"str": 5, "dex": 3}, "the parent is not mutated")
	_check(list_eq(r.value.file_keys, ["extra.ai.hear", "extra.ai.sight", "loot", "stats.dex", "stats.str"]), "file_keys lists file-set leaf paths, through extends")
	_addon("npc/lone.yml", "health: 50\n")
	var lone: DotProfile = _mk().load_profile("lone").value
	_check(list_eq(lone.file_keys, ["health"]) and lone.describe().contains("file keys set: health"), "a schema default is not a file key")


func _test_tiers() -> void:
	_section("Addon < game < server tiers")
	_clean()
	_addon("npc/orc.yml", "name: AddonOrc\nhealth: 100\nspeed: 2.0\n")
	_gamef("npc/orc.yml", "health: 150\nname: GameOrc\n")
	_w("server/npc/orc.yml", "health: 175\n")
	var s := _mk()
	var r := s.load_profile("orc")
	_check(r.ok, "three tiers load")
	_check(r.value.get_value("health") == 175, "server beats game beats addon")
	_check(r.value.get_value("name") == "GameOrc", "game overrides addon where server is silent")
	_check(r.value.get_value("speed") == 2.0, "an addon key survives a partial game file")
	_check(r.value.sources.size() == 3, "all three files are recorded")
	_gamef("npc/elf.yml", "health: 60\n")
	_check(s.load_profile("elf").ok, "a game may add a profile the addon lacks")
	var two := _mk()
	two.roots = PackedStringArray([BASE + "_x", BASE])
	_check(two.load_profile("orc").value.get_value("health") == 175, "a later root wins within a tier")
	_rm(BASE + "_x")
	_w("server/addon/dot-npc/npc/orc.yml", "health: 222\n")
	_w("server/npc/orc.yml", "health: 333\n")
	DirAccess.make_dir_recursive_absolute(BASE + "_x/server/game/mygame/npc")
	var gf := FileAccess.open(BASE + "_x/server/game/mygame/npc/orc.yml", FileAccess.WRITE)
	gf.store_string("health: 111\n")
	gf.close()
	var tf := _mk()
	tf.roots = PackedStringArray([BASE + "_x", BASE])
	_check(tf.load_profile("orc").value.get_value("health") == 111, "an earlier root's server/game beats a later root's server/addons")
	_rm(BASE + "_x/server")
	DirAccess.remove_absolute(BASE + "_x")
	tf.clear_cache()
	_check(tf.load_profile("orc").value.get_value("health") == 222, "server/addons beats the legacy server/<kind> in any root order")
	_w("server/evil/npc/orc.yml", "health: 999\n")
	var bad := _mk()
	bad.game = "../evil"
	_check(bad.load_profile("orc").value.get_value("health") != 999, "a game name with .. is skipped")
	_w("server/game/a/b/npc/orc.yml", "health: 888\n")
	bad.game = "a/b"
	bad.clear_cache()
	_check(bad.load_profile("orc").value.get_value("health") != 888, "a game name with / is skipped")
	_check(_mk("npc").game == "mygame" and DotProfileSet.create("dot-npc", "", "npc").has_id("orc") == false, "no game id skips the game tier")


func _test_plural_legacy() -> void:
	_section("Singular dirs are canonical; addons/, games/, server/addons/, server/games/ are read with one WARN")
	_clean()
	DotCfgLegacy.reset()
	_addon("npc/orc.yml", "health: 100\n")
	_check(_mk().load_profile("orc").value.get_value("health") == 100 and DotCfgLegacy.warned_count() == 0, "a singular addon file is read with no warning")
	_clean()
	_w("addons/dot-npc/npc/orc.yml", "health: 120\nspeed: 9.0\n")
	var r := _mk().load_profile("orc")
	_check(r.ok and r.value.get_value("health") == 120 and r.value.get_value("speed") == 9.0, "cfg/addons/<addon>/ is still read")
	_check(DotCfgLegacy.warned_count() == 1, "with one warning")
	_addon("npc/orc.yml", "health: 130\n")
	r = _mk().load_profile("orc")
	_check(r.value.get_value("health") == 130, "both present: the singular file wins")
	_check(r.value.get_value("speed") != 9.0, "whole: nothing of the plural file is merged")
	_w("games/mygame/npc/orc.yml", "health: 140\n")
	_check(_mk().load_profile("orc").value.get_value("health") == 140, "cfg/games/<game>/ is still read")
	_w("server/addons/dot-npc/npc/orc.yml", "health: 150\n")
	_check(_mk().load_profile("orc").value.get_value("health") == 150, "cfg/server/addons/<addon>/ is still read")
	_w("server/games/mygame/npc/orc.yml", "health: 160\n")
	_check(_mk().load_profile("orc").value.get_value("health") == 160, "cfg/server/games/<game>/ is still read")
	_check(DotCfgLegacy.warned_count() == 4, "one warning per old path")
	_clean()
	DotCfgLegacy.reset()


func _test_overrides() -> void:
	_section("Environment and command line over files")
	_clean()
	_addon("npc/orc.yml", "health: 100\nboss: false\nname: Orc\napi_token: x\n")
	var sc := [DotProfileSet.field("health", "int", 1, {"max": 500}), DotProfileSet.field("boss", "bool", false), DotProfileSet.field("name", "string", ""), DotProfileSet.field("api_token", "string", "")]
	var s := _mk("npc", sc)
	OS.set_environment("PST_NPC_ORC_HEALTH", "300")
	OS.set_environment("PST_NPC_ORC_BOSS", "true")
	OS.set_environment("PST_NPC_ORC_API_TOKEN", "stolen")
	var r := s.load_profile("orc")
	_check(r.value.get_value("health") == 300, "environment beats the file")
	_check(r.value.get_value("boss") == true, "a bool keeps its type")
	_check(r.value.get_value("api_token") == "x" and r.value.refused.size() == 1, "a secret is refused from the environment")
	s.clear_cache()
	s.cmdline = PackedStringArray(["--pst.npc/orc.health=400", "--pst.npc/orc.name", "Brute"])
	r = s.load_profile("orc")
	_check(r.value.get_value("health") == 400, "command line beats environment")
	_check(r.value.get_value("name") == "Brute", "a space-separated value is taken")
	OS.set_environment("PST_NPC_ORC_HEALTH", "9999")
	s.clear_cache()
	s.cmdline = PackedStringArray()
	r = s.load_profile("orc")
	_check(not r.ok and r.error.message.contains("max"), "an override is range-checked")
	OS.set_environment("PST_NPC_ORC_HEALTH", "many")
	s.clear_cache()
	_check(s.load_profile("orc").value.get_value("health") == 100, "a wrong-typed override is ignored")
	for k in ["HEALTH", "BOSS", "API_TOKEN"]:
		OS.unset_environment("PST_NPC_ORC_" + k)
	s.clear_cache()
	_check(s.load_profile("orc").value.overrides.is_empty(), "with none set there are no overrides")


func _test_extra() -> void:
	_section("extra: passes through untouched")
	_clean()
	_addon("npc/z.yml", "health: 10\nextra:\n  sound: growl\n  nested:\n    n: [1, 2]\n  unusual_key: 7\n")
	var r := _mk().load_profile("z")
	_check(r.ok, "unknown keys under extra do not fail")
	_check(r.value.extra.get("sound") == "growl", "a value is kept")
	_check(r.value.get_extra("nested.n") == [1, 2], "nested values are kept")
	_check(r.value.get_extra("unusual_key") == 7 and r.value.get_extra("missing", "d") == "d", "get_extra reads paths and defaults")
	_addon("npc/y.yml", "extra: 5\n")
	_check(not _mk().load_profile("y").ok, "extra must be a mapping")


func _test_listing() -> void:
	_section("Directory listing")
	_clean()
	_addon("npc/b.yml", "health: 1\n")
	_addon("npc/a.yml", "health: 1\n")
	_addon("npc/notes.txt", "x")
	_gamef("npc/c.yml", "health: 1\n")
	_gamef("npc/a.yml", "health: 2\n")
	_w("server/npc/d/d.yml", "health: 1\n")
	_w("server/npc/empty/readme.txt", "x")
	var s := _mk()
	var ids := s.list_ids()
	_check(list_eq(ids, ["a", "b", "c", "d"]), "ids are sorted and unique across tiers")
	_check(not ids.has("notes") and not ids.has("empty"), "non-yml files and empty folders are not profiles")
	_check(s.has_id("c") and not s.has_id("zz"), "has_id")
	_check(_mk("weapon").list_ids().is_empty(), "another kind is empty")
	_check(s._cache.is_empty(), "listing loaded nothing")


func _test_folders() -> void:
	_section("Folder profiles with child sets")
	_clean()
	_addon("weapon/pistol/pistol.yml", "name: Pistol\nhealth: 10\n")
	_addon("weapon/pistol/upgrades/scope.yml", "name: Scope\nspeed: 1.0\n")
	_addon("weapon/pistol/upgrades/scope2.yml", "extends: scope\nspeed: 2.0\nextra:\n  zoom: 4\n")
	_gamef("weapon/pistol/upgrades/scope.yml", "speed: 1.5\n")
	_addon("weapon/rifle/profile.yml", "name: Rifle\n")
	_addon("weapon/knife.yml", "name: Knife\n")
	var s := _mk("weapon")
	_check(list_eq(s.list_ids(), ["knife", "pistol", "rifle"]), "flat files and folders list together")
	var p: DotProfile = s.load_profile("pistol").value
	_check(p.get_value("name") == "Pistol", "<id>/<id>.yml loads")
	_check(s.load_profile("rifle").value.get_value("name") == "Rifle", "<id>/profile.yml loads")
	_check(list_eq(p.child_kinds(), ["upgrades"]), "child kinds come from sub-folders")
	var up_schema := [DotProfileSet.field("name", "string", ""), DotProfileSet.field("speed", "float", 0.0)]
	var up := p.child_set("upgrades", up_schema)
	_check(list_eq(up.list_ids(), ["scope", "scope2"]), "children list lazily")
	_check(up.load_profile("scope").value.get_value("speed") == 1.5, "a child merges tiers")
	var s2: DotProfile = up.load_profile("scope2").value
	_check(s2.get_value("speed") == 2.0 and s2.get_value("name") == "Scope", "a child extends a sibling")
	_check(s2.get_extra("zoom") == 4, "a child keeps its extra")
	_check(not up.load_profile("scope").value.values.has("health"), "a child has its own schema")
	_check(not up.load_profile("pistol").ok, "a child set does not see its parent's siblings")


func _test_no_cycle() -> void:
	_section("A freed set does not leak its cached profiles")
	_clean()
	_addon("npc/a.yml", "name: A\n")
	var s := _mk()
	var keep: DotProfile = s.load_profile("a").value
	_check(keep.set_ref == s, "a profile reaches its set while the set lives")
	var set_w: WeakRef = weakref(s)
	var prof_w: WeakRef = weakref(keep)
	keep = null
	s = null
	_check(set_w.get_ref() == null, "the set is freed with no clear_cache() call")
	_check(prof_w.get_ref() == null, "its cached profile is freed with it")
	var s2 := _mk()
	var orphan: DotProfile = s2.load_profile("a").value
	s2 = null
	_check(orphan.set_ref == null and orphan.child_set("x") == null, "a profile outliving its set has a null set_ref")


func _test_bad_yml() -> void:
	_section("Bad yml is a DotResult error naming the file")
	_clean()
	_addon("npc/bad.yml", "health: 5\n\tbroken: [\n")
	_addon("npc/list.yml", "- a\n- b\n")
	_addon("npc/empty.yml", "")
	_addon("npc/ext.yml", "extends: 7\n")
	_addon("npc/ok.yml", "health: 5\n")
	_addon("npc/kid.yml", "extends: bad\n")
	var s := _mk()
	var r := s.load_profile("bad")
	_check(not r.ok and r.error.code == DotError.CODE_PARSE, "a malformed file is CODE_PARSE")
	_check(r.error.message.contains("bad.yml"), "naming the file")
	_check(s.load_profile("empty").ok, "an empty file is all defaults")
	_check(not s.load_profile("ext").ok, "extends must be an id")
	_check(not s.load_profile("kid").ok and s.load_profile("ok").ok, "a bad parent fails the child only")
	_check(s.describe().contains("DotProfileSet") and s.load_profile("ok").value.describe().contains("DotProfile ok"), "describe works")
	_check(s.load_profile("ok").value.describe_lines().size() >= 2, "describe_lines lists values and sources")


	var imp := _mk()
	imp.implicit_ids = PackedStringArray(["settings"])
	_check(imp.has_id("settings") and list_eq(imp.list_ids().slice(0, 0), []) and imp.list_ids().has("settings"), "an implicit id exists and is listed with no file")
	_check(imp.load_profile("settings").ok and not imp.has_id("other"), "and loads as all defaults; other ids still need a file")
	_check(not imp.load_profile("other").ok, "a non-implicit id with no file still fails")


func list_eq(a: PackedStringArray, b: Array) -> bool:
	return Array(a) == b


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
