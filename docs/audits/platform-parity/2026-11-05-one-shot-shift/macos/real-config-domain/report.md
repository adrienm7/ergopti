# OSM-002 original persistence adjudication

Source is unchanged `9c565c88c9a1366a2e9b18c1b9d2868509510975`. All programs, reports and logs are scratch-only. Frozen prior supplements are unchanged.

The original persistence implementation does **not** prevent the tested numeric-domain failures. Actual private Linux file bytes and original Config readback establish this, replacing the earlier acknowledged-save-only limitation for these cases.

## Direct original setter and Config round trips

`real-config-domain.lua` uses the existing registered `real_user_config_path` and `real_user_config_writes=true` options. Original Remap calls original `RealConfig.save_user_config`; original TOML codec and original FileSystem adapter publish to a private temporary file. The program reads actual bytes with `io.open`, then calls the fixture's original Config load delegate on that file. No substitute persistence implementation is added.

Each case executes with the original Remap initially disabled and enabled. The actual enabled getter agrees with the selected state.

| Input             | Setter | Actual published bytes                   | Original Config readback |
| ----------------- | ------ | ---------------------------------------- | ------------------------ |
| `2000`            | true   | Timing leaf omitted as canonical neutral | 2000                     |
| positive infinity | true   | `sticky_timeout_ms = +inf`               | positive infinity        |
| finite `1e20`     | true   | `sticky_timeout_ms = 1e+20`              | 1e20                     |
| `0`               | false  | Source unchanged                         | 1000                     |
| `0.1`             | true   | `sticky_timeout_ms = 0`                  | 0                        |

Every case starts with explicit 1000 ms in its private source. Config's canonical 2000 ms neutral explains the accepted control's sparse omission. The large finite and infinite values are not rejected by original TOML serialization or parsing. The fractional API case really persists zero through the same original owners.

## Linked public menu and real persistence

`real-menu-persistence.lua` runs the prior frozen `../ui-domain/menu-infinity-probe.lua` unchanged. It wraps only the registered fixture constructor to select its existing real-write option and private file path. The original menu's sticky getter and setter still call the original Remap instance. This executes public menu input, setter, original persistence, actual private file readback, original menu rebuild and second action within the same process and owner scenario.

For both enabled states, recorded AppleScript strings `1e309` and `1e20` are accepted by the original callback, actually publish `+inf` and `1e+20`, and reload to the same numeric values through original Config. The first rebuilt caption succeeds; the next action raises at original shared `text_utils/init.lua:716` before another AppleScript call because `%d` cannot represent the stored default. These failures are therefore not prevented by the original persistence implementation on the measured private filesystem path.

String `2000` is the successful editable control. String `0.9` is floored to zero by the menu and refused without a write. `invalid` never invokes the setter. The direct fractional API result and the menu fractional result intentionally differ.

## Qualification

Actual Linux files are created, published, read and deleted under a fresh private temporary directory. Original `test.runner_home.isolate()` protects the user's configuration and cooperative write-lock location; it is not reimplemented. The original FileSystem adapter executes over the existing Hammerspoon test metadata/locking ports on Linux. Actual bytes establish the observed TOML round trip; this is not certification of macOS native metadata, atomic crash safety or Hammerspoon APIs.

Native lease observations, generator construction, AppleScript dialogs, menu regeneration requests and logging remain declared fixture ports. The original enabled setter's lifecycle gate executes, but no native lease, Karabiner compilation/deployment, osascript process or application receiving is measured. The menu regeneration port acknowledges its request; generator build/deploy counters are zero. Outer native UI exception handling is not measured; the result is specifically that the original second action raises before opening another dialog.

## Verification

`check_real_config.py REPOSITORY` pins source bytes to the original commit, including Config, FileSystem, test fixture, TOML codec and the prior UI route. It semantically asserts ten direct and ten linked-menu rows per sweep. Two final sweeps pass in fresh processes with fresh private TMPDIRs, using recorded Lua 5.4, `LOGNAME=agent` and the CI toolchain. Both original supplements remain untouched. No new unrelated root is counted: all results extend OSM-002 numeric-domain validation.
