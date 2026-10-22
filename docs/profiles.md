# Profiles: `DotProfileSet` and `DotProfile`

One file per entity (an NPC, a weapon, a player class) instead of one big config. `DotProfileSet` lists, loads and validates a kind's profiles; `DotProfile` is one loaded profile. Kinds are generic and singular: `npc`, `weapon`, `class`.

## Where files live

Two tiers with the same shape, plus a server tier:

| Tier | Path | Who writes it |
| --- | --- | --- |
| addon | `cfg/addons/<addon_name>/<kind>/<id>.yml` | the addon's defaults |
| game | `cfg/game/<game>/<kind>/<id>.yml` | the game, overriding a few keys or adding profiles |
| server | `cfg/server/<kind>/<id>.yml` | the operator |

Each tier is looked up under every config root, weakest first (`res://cfg`, next to the executable, `user://cfg`, `--config DIR`), as [addon-config.md](addon-config.md). Precedence, weakest first: schema defaults < addon < game < server < environment < command line. A game file may hold only the keys it changes. Works from `res://` (packs) and `user://`; exports need `cfg/*` in the preset's `include_filter`.

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

## How the adopters would use it (not done yet)

- **DotNpcDef (dot-npc)**: its exported fields become the schema (`health`, `speed`, ...); `DotNpcDef.from_profile(DotProfile)` fills the resource, `extra:` carries behaviour-specific keys. dot-npc would own addon defaults in `cfg/addons/dot-npc/npc/`, a game ships `cfg/game/<game>/npc/zombie.yml` with the few keys it changes, and spawn tables list `set.list_ids()`.
- **Weapons (dot-weapon and packs)**: a weapon is a folder `weapon/<id>/<id>.yml` with `upgrades/<upgrade>.yml` children; the weapon config's fields are the schema, a variant is `extends: base_pistol`, and a pack's own keys sit under `extra:`. Server operators retune with `cfg/server/weapon/<id>.yml` or `PROFILE_WEAPON_<ID>_DAMAGE`.
- **Classes (dot-player-class)**: kind `class`, same shape.
