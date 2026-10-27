extends RefCounted

## dot-profile's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: DotProfileSet, DotProfile, DotProfileRuntime and tools/profile_check.gd, moved out of
#    dot-core (API level 22) with their class names, cfg paths and file formats unchanged.
# 2: DotBoxProfiles (the `box` kind).
const LEVEL := 2
const OLDEST := 1
