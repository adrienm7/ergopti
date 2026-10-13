# Linux model inventory getter custody

Apply `linux-inventory-getter.patch` after exact Linux A/B/C and sealed response
identity SHA256 `b3b04e8bc35cd7a295333c3e8c1e668cc29f94bc5a41f50ee57e6bd792e0212b`.
The two source preimages are that correction's exact afterimages. Frozen b3b,
A/B/C and the canonical checkout remain unchanged. Root owns composition.

The original getter discarded a rejected refresh result and returned the old
cache. During a cached source observer it could also recapture a successor
app, or return/refetch a newer nested inventory belonging to another query.
The getter now captures its original private response before readers, retains
raw-identical cache/publication pointers around currency observations, and
returns its actual owned refresh result. Refusal preserves the newer cache
for a fresh getter instead of clearing it. Configured personal selection is
separate and remains unchanged. Fresh unowned queries after managed app
retirement remain permitted through their own actual transport responses;
this grants no external PID identity, server readiness or runtime start.

The only raw inventory cache reads are inside profiles. Engine, menu and model
browser consumers use its getter. get_current_model returns configured model
selection; it does not expose raw model inventory. No shared controller,
lifecycle, consent, cleanup, native qualification, schema, locale, backend,
roster, runner, workflow or packaging source changes are included.

Seven appended tests reuse the existing real repair/controller/Engine/API/
Profiles graph and its controlled OS/HTTP/native-reader ports. They exercise
actual shutdown, retained service exit, same-origin replacement during cached
observation, nested cache publication, fresh external caching, delayed native
pipe service replacement and delayed nested refresh. Every original test byte
and all170 prior assertion call sites remain an exact prefix, now206 sites.
The cases do not mirror helper implementation or simulate native qualification.

Actual pinned Lua5.4.7 and LuaJIT each: predecessor2 PASS/5 FAIL; corrected7/0.
Complete acquisition42+7=49/0 and canonical preferences5/0 on both ABIs. Exact
commands/status/timings are in focused-receipt.json. Four actual source-matched
behavioral mutations fail assertions: discarding refusal6/1; dropping original
app check6/1; dropping publication pointers6/1; dropping cached currency2/5.
No mutation failed by missing API or parser error. Pinned luac5.4 parses both
paths; UTF-8/LF/trailing-whitespace and exact git apply/check pass. Full common
root gates remain the integration owner's responsibility after its active gate.

After composition, from the Linux driver root:

```sh
source /workspace/ergopti/.rtk/cloud-tools.sh
lua tests/run.lua --only=linux-inventory-getter
LUA_CPATH="$LUA_CPATH_5_1" luajit tests/run.lua --only=linux-inventory-getter
```

Expect exactly7 executed, zero failures; reject an empty selection. The compact
private runner `/tmp/ergopti247-linux-inventory-getter-c09wevgf/run.lua` accepts
source/test paths, recorded in receipts, and reuses unchanged sealed b3b files.

Linux live service/native desktop receiving remains UNRUN: prime the real
model browser, stop/shut down the original managed service and refresh the
browser; it must not expose the old inventory or dispatch after shutdown.
During a service replacement, an already running getter must not borrow the
successor; a later explicit getter may acquire its own response and cache.
Verify the configured model remains persisted. This needs a Linux session and
real managed/external listeners, not a physical keyboard. Keyboard/editor/
display acceptance and Windows/macOS native receiving remain separate.
