<!-- docs/handovers/2026-10-04-parallel-containers/group3-native-publisher-correction/README.md -->

# Additive native publisher correction

This reviewed [one-file patch](producer-only.patch) applies to the macOS
FileSystem postimage of the untouched [original publisher packet](../group3-native-publisher/README.md).
[Metadata](metadata.json) pins the exact preimage, postimage and patch.
Forward-port its owned hunks against newer upstream sources; do not replace a
newer FileSystem wholesale. The shared Writer and operation reporter are unchanged.

The correction retains unpublished staging cleanup debt after successful mutex
release, records original directory/payload and public-source identities, and
checks those identities before destructive cleanup and source-authorized retry.
A foreign same-byte replacement or an unknown initial identity remains refused;
retry cannot adopt it. Acknowledged unlink and directory retirement are distinct.
Hammerspoon exposes pathname attributes, so these are cooperating pathname
checks, without an atomic descriptor-relative compare-and-swap guarantee.

Under explicit umask `022`, focused Linux-host temporary-file qualification
passed 108 cases; conditional cleanup passed 19 on both Lua 5.4 and LuaJIT.
The previous source failed 8 of the new conditional cases. A metadata fixture
that acknowledged copying without performing it failed 11 of 13 publication
premises; real copying passed all 13. Existing staging and atomic-write cases
passed 35. Independent source review cleared the five-path production/fixture
correction. These results do not qualify native Hammerspoon, Darwin advisory
locks, packaged installation, or independently owned hotstring controllers.

Current `dev` also contains a conditional-removal participant added by Group 1.
Composition must preserve its retained cleanup acknowledgements and use one
native API implementation; applying competing complete definitions is unsafe.
