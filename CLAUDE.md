# dot-profile

`DotProfileSet`, `DotProfile` and `DotProfileRuntime`: per-entity yml profiles, split out of dot-core at its API level 22. Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific here.

**Only dot-core is a dependency** (>= 21), linked in `.gitignore` for the suites. dot-core must never name these classes; what both need (`DotAddonConfig.merge`, `set_nested`, `is_finite_value`, `check_field`, `DotYaml.emit`, the user-tier flag) lives in dot-core.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/profiles.md](docs/profiles.md) | any change to tiers, `extends`, folders, overrides, the user tier or the validator |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_profile/core/dot_profile_set.gd`, `dot_profile.gd` | the set (tiers read weakest first, schema, `extends`, `extra:`, folders, overrides) and one loaded profile |
| `addons/dot_profile/core/dot_profile_runtime.gd` | permission-gated, validated, replicated live edits; save to the server layer |
| | `add` and `delete` ops: a new profile lives in the runtime layer until saved; a delete removes the server file and, for a profile a lower tier ships, writes a `<id>.deleted` marker beside it that hides it (adding the id again removes the marker) |
| `addons/dot_profile/tools/profile_check.gd` | headless validator (no `class_name`): `-- <repo> [--schema script] [--skip-unknown]`; dot-ci `profiles: true` |
| `examples/` | `profile_selftest`, `profile_runtime_selftest`, `profile_check_selftest`, `user_tier_selftest` |

`DotProfileSet.user_tier_enabled` reads `DotAddonConfig.user_tier_enabled`; there is one flag.
