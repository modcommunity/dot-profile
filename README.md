# dot-profile

Per-entity yml profiles for the dot-* family: one file per NPC, weapon or player class instead of one big config. `DotProfileSet` lists, loads and validates a kind's profiles, `DotProfile` is one loaded profile, and `DotProfileRuntime` applies permission-gated live edits on a server. Tiers (addon, game, user, server), `extends`, `extra:`, folder profiles with child sets, environment and command-line overrides, and a headless validator (`tools/profile_check.gd`).

Only dot-core is required. The cfg paths and file formats are dot-core's (`cfg/addon/<addon>/…`, `cfg/game/<game>/…`, `cfg/server/addon/<addon>/…`, `cfg/server/game/<game>/…`). The classes were part of dot-core until its API level 22; their names did not change.

See [docs/profiles.md](docs/profiles.md).

## Developing

Link dot-core (`ln -s ../../dot-core/addons/dot_core addons/dot_core`), import the project once, then run the scenes in `examples/`: `profile_selftest`, `profile_runtime_selftest`, `profile_check_selftest` and `user_tier_selftest`.
