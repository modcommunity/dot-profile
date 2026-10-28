extends Node

## Exercises the [DotProfileSet] user tier: precedence, off by default and when connected, write, reset, listing.
## Run: godot --headless --path . res://examples/user_tier_selftest.tscn

const SECTIONS := 7
const CHECKS := 40
const BASE := "user://user_tier_selftest"

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_line("dot-profile user tier self-test")
	_clean()
	_test_precedence()
	_test_disabled()
	_test_connected_client()
	_test_write()
	_test_reset()
	_test_listing()
	_test_server_mirror()
	_clean()
	DotProfileSet.set_user_tier(false)
	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _mk() -> DotProfileSet:
	var s := DotProfileSet.create("dot-npc", "mygame", "npc", [
		DotProfileSet.field("health", "int", 100, {"min": 1, "max": 1000}),
		DotProfileSet.field("speed", "float", 3.0, {"min": 0.0}),
		DotProfileSet.field("mode", "string", "melee", {"enum": ["melee", "ranged"]}),
		DotProfileSet.field("boss", "bool", false),
	])
	s.roots = PackedStringArray([BASE])
	s.user_root = BASE
	s.override_prefix = "utst"
	return s


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


func _seed() -> void:
	_clean()
	_w("addon/dot-npc/npc/orc.yml", "health: 100\nspeed: 2\n")
	_w("game/mygame/npc/orc.yml", "health: 150\n")
	_w("user/npc/orc.yml", "health: 400\nspeed: 5\n")
	_w("server/npc/orc.yml", "speed: 1.5\n")


func _test_precedence() -> void:
	_section("Tier order: addon < game < user < server")
	_seed()
	DotProfileSet.set_user_tier(true)
	var s := _mk()
	var p: DotProfile = s.load_profile("orc").value
	_check(p.get_value("health") == 400, "user beats game")
	_check(p.get_value("speed") == 1.5, "server beats user")
	_check(p.sources.size() == 4, "four tiers contributed")
	_check(p.sources[2].begins_with("user:") and p.sources[3].begins_with("server:"), "user is listed after game and before server")
	_check(p.get_value("mode") == "melee", "a key nobody sets keeps the schema default")


func _test_disabled() -> void:
	_section("Off by default and when switched off")
	_seed()
	DotProfileSet.user_tier_enabled = false
	_check(not DotProfileSet.user_tier_enabled, "the tier is off unless a host turns it on")
	var s := _mk()
	_check(s.load_profile("orc").value.get_value("health") == 150, "a user file is ignored while off")
	var r := s.save_user("orc", {"health": 10})
	_check(not r.ok and r.error.code == DotError.CODE_STATE, "saving while off is CODE_STATE")
	_check(not FileAccess.file_exists(s.user_file("orc")) or FileAccess.get_file_as_string(s.user_file("orc")).contains("400"), "the file is untouched by the refused save")


func _test_connected_client() -> void:
	_section("A connected client ignores a client-side file")
	_seed()
	DotProfileSet.set_user_tier(true)
	var s := _mk()
	_check(s.load_profile("orc").value.get_value("health") == 400, "solo: the user file applies")
	DotProfileSet.set_user_tier(false)
	s.clear_cache()
	_check(s.load_profile("orc").value.get_value("health") == 150, "after connecting (host turns the tier off) the same file is ignored")
	_check(s.load_profile("orc").value.get_value("speed") == 1.5, "the server tier still applies")
	var q := _mk()
	_check(q.load_profile("orc").value.get_value("health") == 150, "a set built after connecting ignores it too")
	DotProfileSet.set_user_tier(true)
	q.clear_cache()
	_check(q.load_profile("orc").value.get_value("health") == 400, "back to solo it applies again")


func _test_write() -> void:
	_section("Writing: validated, merged, applied")
	_seed()
	DotProfileSet.set_user_tier(true)
	var s := _mk()
	var r := s.save_user("orc", {"health": 700})
	_check(r.ok, "a valid edit saves")
	_check(s.load_profile("orc").value.get_value("health") == 700, "the saved value applies at once")
	_check(s.load_profile("orc").value.get_value("speed") == 1.5, "other tiers are unchanged")
	_check(s.user_paths("orc").get("speed") == 5, "keys already in the file are kept")
	r = s.save_user("orc", {"health": 5000})
	_check(not r.ok and r.error.code == DotError.CODE_INVALID, "above max is refused")
	r = s.save_user("orc", {"mode": "flying"})
	_check(not r.ok, "outside the enum is refused")
	r = s.save_user("orc", {"nope": 1})
	_check(not r.ok, "an unknown key is refused")
	_check(s.load_profile("orc").value.get_value("health") == 700, "a refused save leaves the file as it was")
	_check(not s.save_user("ghost", {"health": 5}).ok, "an unknown profile is refused")
	_check(s.save_user("orc", {"boss": true, "mode": "ranged"}).ok and s.load_profile("orc").value.get_value("boss") == true, "several keys at once")
	_check(not s.save_user("../x", {"health": 5}).ok, "a traversing id is refused")


func _test_reset() -> void:
	_section("Reset removes the user file")
	_seed()
	DotProfileSet.set_user_tier(true)
	var s := _mk()
	_check(FileAccess.file_exists(s.user_file("orc")), "the file exists before")
	var r := s.reset_user("orc")
	_check(r.ok and r.value == true, "reset reports a file removed")
	_check(not FileAccess.file_exists(s.user_file("orc")), "the file is gone")
	_check(s.load_profile("orc").value.get_value("health") == 150, "the game tier shows through again")
	_check(s.reset_user("orc").value == false, "a second reset removes nothing")


func _test_listing() -> void:
	_section("Listing includes user-only profiles only while on")
	_seed()
	_w("user/npc/mine.yml", "health: 9\n")
	DotProfileSet.set_user_tier(true)
	var s := _mk()
	_check(s.list_ids() == PackedStringArray(["mine", "orc"]), "a user-only profile is listed")
	_check(s.has_id("mine"), "has_id sees it")
	DotProfileSet.set_user_tier(false)
	_check(s.list_ids() == PackedStringArray(["orc"]), "off: it is not listed")
	_check(s.user_paths("mine").get("health") == 9, "user_paths still reads the file")


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("== %s ==" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)


func _test_server_mirror() -> void:
	_section("Server tier: mirrored layout, old folder shimmed")
	_seed()
	DotCfgLegacy.reset()
	DotProfileSet.set_user_tier(false)
	var s := _mk()
	_check(s.load_profile("orc").value.get_value("speed") == 1.5, "the old server/<kind>/ is still read")
	_check(DotCfgLegacy.warned_count() == 1, "with one warning")
	_w("server/addon/dot-npc/npc/orc.yml", "speed: 2.5\n")
	_check(_mk().load_profile("orc").value.get_value("speed") == 2.5, "server/addon/<addon>/ wins over the old folder")
	_w("server/game/mygame/npc/orc.yml", "speed: 3.5\n")
	_check(_mk().load_profile("orc").value.get_value("speed") == 3.5, "server/game/<game>/ is strongest")
	_clean()
	_w("server/npc/orc.yml", "speed: 4.5\n")
	DotCfgLegacy.reset()
	var bare := DotProfileSet.create("", "", "npc", [DotProfileSet.field("speed", "float", 3.0)])
	bare.roots = PackedStringArray([BASE])
	_check(bare.load_profile("orc").value.get_value("speed") == 4.5, "with no addon or game, server/<kind>/ is the layer itself")
	_check(DotCfgLegacy.warned_count() == 0, "and is not reported as legacy")
	DotCfgLegacy.reset()
