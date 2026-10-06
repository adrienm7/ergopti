<!-- docs/handovers/2026-10-04-parallel-containers/group3-conditional-removal-bridge/README.md -->

# Conditional-removal participant contracts

The reviewed [producer delta](bridge.patch) applies to the Group 3 publisher
postimages in [the additive correction](../group3-native-publisher-correction/README.md).
[Metadata](metadata.json) pins every image and both patches. Current upstream
may already contain these changes; inspect preimages and preserve its owners.
There must be one native `remove_if_unchanged` implementation.

macOS FileSystem keeps its source-guarded receipt as the third result and adds
an exact release-only closure as the fourth. Ordinary shared Writer calls
return that closure to scope/layer inverses, after matching the requested path
and classified source. Private `require_conditional` calls retain the receipt.
Existing adapters' third-result functions keep their exact identity.

The release closure never reads public content, unlinks, reacquires a lock, or
retires a successor. A foreign recreation can permit physical lock release
while still refusing private logical compensation. Refused release retains
the same debt. Ordinary read errors preserve the existing participant contract;
private diagnostics retain fixed categories without content or paths.

Independent source review cleared both production changes and the
[append-only test delta](bridge-tests.patch). The original 19 conditional cases
are byte-preserved; the five added controls give 24 passing cases. Eight selected
Mac-target Lua 5.4 modules plus those controls passed 296 cases. Original
preimages failed all five new controls, seven cooperating-writer cases and one
shared Writer case. Supplemental LuaJIT fixture incompatibilities are not
qualification. Full composed sources passed 357 JS checks, 14,285 portable Mac
cases and 6,834 Linux cases. Native Hammerspoon, Swift/C, packaging and
installation acceptance remain separate and pending.

The producer-only diff is also preserved byte-for-byte in
[the coordination packet](https://github.com/adrienm7/ergopti/issues/86#issuecomment-5986363047).
No hotstring controller, automation discovery or completed TODO claim is included.
