# Profiles: `DotProfileSet` and `DotProfile`

One file per entity (an NPC, a weapon, a player class) instead of one big config. `DotProfileSet` lists, loads and validates a kind's profiles; `DotProfile` is one loaded profile. Kinds are generic and singular: `npc`, `weapon`, `class`.

## Where files live

Two tiers with the same shape, a user tier and a server tier:

| Tier | Path | Who writes it |
| --- | --- | --- |
| addon | `cfg/addons/<addon_name>/<kind>/<id>.yml` | the addon's defaults |
| game | `cfg/game/<game>/<kind>/<id>.yml` | the game, overriding a few keys or adding profiles |
| user | `user://cfg/user/<kind>/<id>.yml` | the player, in a solo or listen-host game only (below) |
| server | `cfg/server/<kind>/<id>.yml` | the operator |

Each tier is looked up under every config root, weakest first (`res://cfg`, next to the executable, `user://cfg`, `--config DIR`), as [addon-config.md](addon-config.md). Precedence, weakest first: schema defaults < addon < game < user < server < environment < command line. A game file may hold only the keys it changes. Works from `res://` (packs) and `user://`; exports need `cfg/*` in the preset's `include_filter`.

A profile may be a folder: `<kind>/<id>/<id>.yml` (or `profile.yml`) with child sets beside it, such as `weapon/pistol/upgrades/scope.yml`. Children are loaded lazily, each set with its own schema and its own `extends`, and see the same three tiers.

## Use

```gdscript
var s := DotProfileSet.create("dot-npc", "mygame", "npc", [
    DotProfileSet.field("health", "int", 100, {"min": 1, "max": 1000}),
    DotProfileSet.field("mode", "string", "melee", {"enum": ["melee", "ranged"]}),
])
var ids := s.list_ids()                  # scans directories; opens no file
var res := s.load_profile("zombie")      # DotResult, value is a DotProfile
if not res.ok:
    return res
var hp: int = res.value.get_value("health")
var sound = res.value.get_extra("sound.growl")
var ups := res.value.child_set("upgrades", [DotProfileSet.field("cost", "int", 0)])
```

`field(name, type, default, opts)`: type is `int`, `float`, `string`, `bool`, `list`, `dict` or `any`; opts `min`, `max`, `enum`, `required`. All errors of one profile are reported together as `CODE_INVALID`; a malformed yml is `CODE_PARSE` naming the file; a missing profile or parent is `CODE_INVALID`.

## Rules

- **Unknown keys** fail (`strict`, the default) so a typo does not pass silently. Anything the schema does not know goes under `extra:`, which is deep-merged and passed through untouched (`get_extra("a.b")`).
- **`extends: <id>`**: the parent is resolved with all its tiers first, then the child's tiers merge over it. Maps merge key by key, a list or scalar is replaced whole. A cycle (including self) fails and names the path.
- **Environment**: `PROFILE_<KIND>_<ID>_<KEY>` (`PROFILE_NPC_ZOMBIE_HEALTH`); **command line**: `--profile.npc/zombie.health=50` (`override_prefix` changes `profile`). Only schema keys, not `dict` fields, and only in the field's type; the result is range-checked. Keys with secret words (`password`, `token`, `*_key`, plus `sensitive`) are refused, as `DotAddonConfig`. Overrides apply to the requested profile, not to a parent.
- `describe()` / `describe_lines()` list the values, files, extends chain, overrides and refusals. Log channel `profile`.
- Web-safe: no threads, only `DirAccess`/`FileAccess`/`DotYaml`.

## The user tier: a player's own mod layer

`user://cfg/user/<kind>/<id>.yml` (`set.user_root` moves it) sits between game and server. It is **off** (`DotProfileSet.user_tier_enabled`, static, default false) and the process that is a solo or listen-host game turns it on with `DotProfileSet.set_user_tier(true)`; a dedicated server never does, and a client turns it off on connecting, so a file on a player's disk can never change what a server's profile says. `set.save_user(id, {path: value})` validates every path with `check_edit`, merges into the file, writes it, reloads the profile and restores the old file if it no longer loads (`CODE_STATE` while the tier is off); `set.reset_user(id)` deletes the file; `set.user_paths(id)` reads it. Writes call `DotWeb.sync_filesystem()`. `examples/user_tier_selftest`; dot-menu's `DotProfileEditorScreen` edits through it.

## Live editing: `DotProfileRuntime`

An admin changes a profile while the game runs. The layer sits on `DotProfileSet.runtime` (`id -> {dotted path: value}`) and is the strongest tier: schema defaults < addon < game < user < server < environment < command line < runtime. `DotProfileRuntime` is the controller; it has no UI and no transport, the host moves dictionaries.

```gdscript
var rt := DotProfileRuntime.new()
rt.add_set(npc_set)                                   # one per kind (set.rel_path)
rt.permit = func(actor, flag): return admins.uid_has_permission(actor, flag)   # dot-server's DotAdminManager
rt.broadcast = func(row): send_to_all("profile_row", row)
rt.send_to = func(peer, row): send_to_peer(peer, "profile_row", row)
# server: the command/RPC handler
var res := rt.handle_request(actor, DotProfileRuntime.make_request("set", "npc", "zombie", "health", 400))
# client: on "profile_row"
rt.apply_row(row)                                      # applies only a newer revision
```

| op | key | value | effect |
| --- | --- | --- | --- |
| `set` | dotted path: a schema key, `stats.armor` into a `dict` field, `extra.a.b` | the new value | validated, applied, revision + 1 |
| `reset_key` | the path | | drops that runtime value |
| `reset` | | | drops the profile's whole runtime layer |
| `save` | | | writes `<save_root>/server/<kind>/<id>.yml` with the runtime keys (merged into that file if it exists; other keys stay), then the file is the server tier |

- **Permission**: `permit(actor, flag)`; unset denies everything. `edit_flag` (default `cvar`) for edit and reset, `save_flag` (default `root`, it writes disk) for save, both `DotAdminFlags` names in dot-server. Denied is `CODE_FORBIDDEN`.
- **Validation** is the schema's: type, `min`/`max`, `enum`, plus NaN and infinity refused anywhere in the value (also now in file values), unknown keys, secret-named keys (`CODE_FORBIDDEN`), unknown profile, kind or op. All `CODE_INVALID`. After applying, the profile is reloaded; if it no longer loads the layer is rolled back. An edit that changes nothing returns `{"changed": false}` and bumps nothing.
- **Replication**: a row is `{kind, id, rev, paths}`, the profile's full runtime layer, so a lost row is repaired by the next. `rev` counts per profile; `apply_row` returns `false` for `rev <=` the held one. A late joiner gets `send_snapshot(peer)` (one row per edited profile, a reset one arrives empty). A client calls `begin_sync()` before a (re)connect, as a restarted server counts from 0 again.
- **Audit**: one INFO line on channel `profile`, `profile edited`, with `who` (`actor_name` callable, else `str(actor)`), `op`, `kind`, `id`, `key`, `old`, `new`, `rev`; refusals and denials are WARN.
- **Listening**: `profile_changed(kind, id, revision)` fires on the server and on each client after a row applies. The set drops its cached profile, so `set.load_profile(id)` returns the new values. A weapon's numbers are built into its definition, so a host rebuilds the definition on this signal and copies it onto the one in use (game-playground does, `DotWeaponProfiles.refresh_def`), and the next shot reads the new values; NPCs read at spawn, so they apply to new spawns, and a live NPC needs a `re_apply` hook the host connects to this signal (game-playground wires it for its own entities; `DotNpc` itself is not).
- Runtime edits apply to the profile named, not to profiles that `extends` it. Transport: dot-net's `DotNetProfileLink` and dot-console's `profile_edit` command call `handle_request` and relay `broadcast`. Two sets cannot share a kind: for packs that each own a `weapon` set, register dot-weapon's `DotWeaponProfileGroup` instead.

## How the adopters would use it (not done yet)

- **DotNpcDef (dot-npc)**: its exported fields become the schema (`health`, `speed`, ...); `DotNpcDef.from_profile(DotProfile)` fills the resource, `extra:` carries behaviour-specific keys. dot-npc would own addon defaults in `cfg/addons/dot-npc/npc/`, a game ships `cfg/game/<game>/npc/zombie.yml` with the few keys it changes, and spawn tables list `set.list_ids()`.
- **Weapons (dot-weapon and packs)**: a weapon is a folder `weapon/<id>/<id>.yml` with `upgrades/<upgrade>.yml` children; the weapon config's fields are the schema, a variant is `extends: base_pistol`, and a pack's own keys sit under `extra:`. Server operators retune with `cfg/server/weapon/<id>.yml` or `PROFILE_WEAPON_<ID>_DAMAGE`.
- **Classes (dot-player-class)**: kind `class`, same shape.
