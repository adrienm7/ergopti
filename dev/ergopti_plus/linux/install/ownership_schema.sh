# static/ergopti_plus/linux/install/ownership_schema.sh
# Canonical receipt constants for the Bash writer and native Lua verifier.
# Keep assignments literal: the verifier never executes shell schema bytes.
OWNERSHIP_MANIFEST='.ergopti-owned-files'
OWNERSHIP_HEX_LENGTH='64'
OWNERSHIP_DRIVER_TREE='linux'
OWNERSHIP_SHARED_TREE='_shared'
OWNERSHIP_LAUNCHER='bin/ergopti-hotstrings'
OWNERSHIP_EXTERNAL_RECORDS='wrapper unit autostart'
OWNERSHIP_DRIVER_SENTINEL='ergopti_hotstrings.lua'
OWNERSHIP_SHARED_SENTINEL='data/locales/en.json'
