<!-- docs/handovers/2026-10-11-groups-247/group2-native-execution.md -->

# Hotstrings execution companion

Current software inventory includes the existing Windows custom-terminator
consumer/editor; it was not rebuilt from historical missing-consumer notes.
All three drivers retain additional personal/dynamic sources, category controls,
source/section activation, delay, color, tooltip, collision priority and
refusal/restoration/cancellation/removal behavior.

Container regressions:

| Correction                        | macOS portable      | Linux portable      | Genuine predecessor               |
| --------------------------------- | ------------------- | ------------------- | --------------------------------- |
| Retained timing prompts           | 13 passed, 0 failed | 11 passed, 0 failed | 11 passed, 2 failed               |
| Scoped publication and live pause | 57 passed, 0 failed | 2 passed, 0 failed  | 54 passed, 3 failed               |
| Lossless primary writer           | 23 passed, 0 failed | 23 passed, 0 failed | 1 passed, 22 failed               |
| Publisher mutation controls       | 34 passed, 0 failed | Shared owner code   | Original 61-call census retained  |
| Real writer retained in UI spy    | Not applicable      | 4 passed, 0 failed  | Current writer/original spy: 0/1  |
| Explicit scanner fixture custody  | 17 passed, 0 failed | Not applicable      | Current reader/old fixtures: 3/10 |

Independent preservation vectors include changed/deleted row/header comments,
quoted semantic descendants, unsafe hidden deletion/reordering, output token
normalization, multilingual unprojected descriptions, ancestor aliases and
foreign empty arrays/maps/floats. The old writer control executes the actual
original writer against the independent cases; this is not a source-only test.
Neither controlled Lua ports nor source checks qualify native Hammerspoon/AHK.

The UI spy now retains the real preparation and acknowledged writer, with
additional successful-save assertions for row deletion and triggerless rows.
The genuine original reader/writer passes its original whole-model fixture
1/0. The macOS gesture/tooltip fixtures explicitly own only the newly required
`toml_codec.record_scanner` dependency, retain all previous assertions and cover
absent/false/existing slots. Genuine original reader/original fixtures pass
13/0; current reader/strengthened fixtures pass 17/0. These are integration
regression repairs, with no production writer change in those two commits.

Executable Windows validation (VM sufficient): activate pinned AutoHotkey 2.0.26 x64 and Node 22.22.2, install frozen dependencies, use a writable isolated temporary directory and no running production instance that shares fixtures. For full driver/E2E execution, first perform the official Windows DLL generation
precondition in [Group 7](group7-native-execution.md); a stale manifest must refuse. Run:

    AutoHotkey64.exe /ErrorStdOut=UTF-8 static\ergopti_plus\windows\tests\run_all.ahk --only=personal-editor-preservation
    AutoHotkey64.exe /ErrorStdOut=UTF-8 static\ergopti_plus\windows\tests\run_all.ahk
    AutoHotkey64.exe /ErrorStdOut=UTF-8 static\ergopti_plus\windows\tests\e2e\run_e2e.ahk

Require a fresh complete result receipt, exact registered selection counts, zero failed cases, and explicit skipped/unexecuted counts. The preserving-writer selection contains 23 shared corpus vectors plus eight native cases: require 31 executed, zero failed, and zero unexecuted in its native selection (native inventory aligned; all 31 remain UNEXECUTED in this container). Additional metadata controls are registered in the full unit runner. Execute the actual compiled callback probe using tools/test/run-compiled-user-hotstrings.ps1 with same-SHA packaged executable, private LocalAppData, extracted bundle and startup evidence as required by that command; its portable contract is not compiled acceptance.

Executable macOS validation (native VM sufficient for software UI/lifecycle): install the repository with the exact delivered SHA and required Accessibility/Input Monitoring permissions; stop other instances, use an isolated personal config directory, and run the pinned repository unit/E2E commands followed by actual Hammerspoon source/installed application menus. Exercise retained timing prompt after a preference change and live pause; throwing/refused persistence must preserve desired choices and admitted callback definitions or retain honest inverse debt. Edit a personal rule beside foreign nested metadata and comments; reopen/restart and inspect source bytes, registry, preview and next-save state. For unsafe hidden descendant deletions/reordering, require a localized failure with exact original bytes and no success refresh. VM UI/callback execution must be reported independently of repository tests whose native ports are mocked.

Physical acceptance still requires a real keyboard and installed user environment: magic-key repeats and timing boundaries; handwritten terminator consume behavior; UTF-8/multiline programmable callbacks and real event-tap privacy/suspension; preview/cache retirement in actual editors and applications; all 140 historical common rules and independent family settings after restart/update. Verify shipped Ergopti suffix/replacement visibility both with and without its layout installed. Actual tooltip display placement/rendering needs a physical display; trackpad tests belong to the relevant gesture owners. Items 34/37/102/104/105 remain partial until their native/physical acceptance is complete. Packaging, installation, upgrades and releases belong to the publication agent.

For compiled callback qualification, use PowerShell 7 on Windows and the
publication owner's same-SHA startup-admitted executable, extracted bundle and
startup receipt. Set the six variables below to those actual recorded artifacts
and a fresh writable evidence directory; do not substitute an interpreted source
run or manufacture startup evidence. Set `RUNNER_TEMP` to a private writable
directory and `GITHUB_SHA` to `git rev-parse HEAD`, then run:

```powershell
$env:GITHUB_SHA = (git rev-parse HEAD).Trim()
pwsh -NoProfile -ExecutionPolicy Bypass -File tools/test/run-compiled-user-hotstrings.ps1 `
  -Executable $TaskExecutable -Checkout $PWD.Path -BundleRoot $TaskBundleRoot `
  -LocalAppData $TaskLocalAppData -StartupEvidence $TaskStartupEvidence `
  -EvidenceDirectory $TaskFreshEvidence
```

Expected: exit 0, `evidence.json` with complete=true and acknowledged cleanup,
source-bound package/dependency hashes and complete native TAP. Packaging and
startup evidence must come from the publication owner's native build.

On Darwin, portable regressions still remain separate from actual Hammerspoon:

```sh
node --version  # require v22.22.2 and frozen dependencies
lua -v         # require 5.4.7 for these portable suites
npm run test:hs
npm run test:hs:e2e
open -a "$TASK_HS_APP"
```

Before `open`, configure the admitted signed app to load this exact checkout's
`static/ergopti_plus/macos/init.lua`, or use the publication owner's same-SHA
installed app; prepare isolated personal config and macOS permissions. The first
two commands exercise controlled portable ports even on Darwin. The launched
app's real menus, callback execution, persistence, restart and cleanup supply
the native observations for the manual scenarios above; retain their actual
source/process/config evidence separately.
