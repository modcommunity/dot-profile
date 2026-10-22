extends Node

## Runs tools/profile_check.gd as a separate process over a fixture written to user://.
##
## Armed by construction: every bad file must be named, every good one must not be.
##
## [codeblock]
## godot --headless --path . res://examples/profile_check_selftest.tscn
## [/codeblock]

const TOOL := "res://addons/dot_core/tools/profile_check.gd"
const DUP := "res://examples/profile_check_dup_schema.gd"
const BADSCHEMA := "res://examples/profile_check_bad_schema.gd"
const BASE := "user://profile_check_selftest"
const GOOD := {
	"cfg/addons/pk/thing/ok.yml": "hp: 20\nextra:\n  anything: 1\n",
	"cfg/addons/pk/thing/child.yml": "extends: ok\nhp: 30\n",
	"cfg/addons/pk/thing/folder/folder.yml": "hp: 5\n",
	"cfg/addons/pk/thing/folder/opt/one.yml": "cost: 3\n",
	"cfg/game/gm/thing/ok.yml": "hp: 40\n",
}
const BAD := {
	"cfg/addons/pk/thing/typo.yml": "hpp: 5\n",
	"cfg/addons/pk/thing/type.yml": "hp: lots\n",
	"cfg/addons/pk/thing/range.yml": "hp: 500\n",
	"cfg/addons/pk/thing/enum.yml": "mode: z\n",
	"cfg/addons/pk/thing/nan.yml": "speed: .nan\n",
	"cfg/addons/pk/thing/inf.yml": "speed: .inf\n",
	"cfg/addons/pk/thing/missing.yml": "extends: nowhere\n",
	"cfg/addons/pk/thing/cyc_a.yml": "extends: cyc_b\n",
	"cfg/addons/pk/thing/cyc_b.yml": "extends: cyc_a\n",
	"cfg/addons/pk/thing/dup.yml": "hp: 1\n",
	"cfg/addons/pk/thing/dup/dup.yml": "hp: 2\n",
	"cfg/addons/pk/thing/yamlext.yaml": "hp: 1\n",
	"cfg/addons/pk/thing/hollow/nothing.txt": "x",
	"cfg/addons/pk/thing/folder/folder.yml": "hp: 5\n",
	"cfg/addons/pk/thing/folder/opt/badcost.yml": "cost: -1\n",
	"cfg/addons/pk/thing/folder/mystery/x.yml": "a: 1\n",
	"cfg/addons/pk/thing/broken.yml": "hp: [1, 2\n",
	"cfg/game/gm/thing/over.yml": "mode: q\n",
	"cfg/server/wepon/w.yml": "a: 1\n",
}
const FLAG := {
	"typo.yml": "unknown key", "type.yml": "hp", "range.yml": "hp", "enum.yml": "mode", "nan.yml": "speed",
	"inf.yml": "speed", "missing.yml": "nowhere", "cyc_a.yml": "cycle", "dup/dup.yml": "duplicate",
	"yamlext.yaml": ".yaml", "hollow": "no ", "badcost.yml": "cost", "mystery": "no child schema",
	"broken.yml": "profile file", "over.yml": "mode", "wepon": "no schema for kind",
}

var _passed := 0
var _failed := 0


func _ready() -> void:
	print("dot-core profile_check self-test")
	var root := ProjectSettings.globalize_path(BASE)
	for f in BAD:
		_write(root, f, BAD[f])
	var bad := _run(root)
	_check(bad["code"] == 1, "bad tree exits 1 (got %d)" % bad["code"])
	for needle in FLAG:
		var hit := false
		for line in String(bad["text"]).split("\n"):
			if line.contains(needle) and line.contains(FLAG[needle]):
				hit = true
		_check(hit, "names %s (%s)" % [needle, FLAG[needle]])

	_wipe(root)
	for f in GOOD:
		_write(root, f, GOOD[f])
	var good := _run(root)
	_check(good["code"] == 0, "clean tree exits 0 (got %d)" % good["code"])
	_check(String(good["text"]).contains("PROFILE_CHECK files 5 errors 0"), "clean tree: files 5 errors 0")

	var dup := _run(root, ["--schema", DUP])
	_check(dup["code"] == 1, "two providers for one kind exit 1")
	_check(String(dup["text"]).contains("kind 'thing' is also provided by") and String(dup["text"]).contains("profile_check_schema.gd") and String(dup["text"]).contains("profile_check_dup_schema.gd"), "duplicate kind names both providers")
	var bads := _run(root, ["--schema", BADSCHEMA])
	_check(bads["code"] == 1 and String(bads["text"]).contains("kind 'gadget'"), "a provider with a bad return is named")
	_check(String(good["text"]).contains("errors 0"), "class-cache discovery found the fixture with no --schema")

	_wipe(root)
	print("%d passed, %d failed" % [_passed, _failed])
	if _failed > 0:
		print(bad["text"])
	get_tree().quit(1 if _failed > 0 else 0)


func _run(root: String, extra: Array = []) -> Dictionary:
	var out := []
	var code := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", TOOL, "--", root] + extra, out, true)
	return {"code": code, "text": str(out[0]) if not out.is_empty() else ""}


func _write(root: String, rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(root.path_join(rel).get_base_dir())
	var w := FileAccess.open(root.path_join(rel), FileAccess.WRITE)
	w.store_string(text)
	w.close()


func _wipe(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	DirAccess.remove_absolute(dir)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL ", what)
