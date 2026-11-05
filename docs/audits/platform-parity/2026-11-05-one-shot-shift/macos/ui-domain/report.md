# OSM-002 public menu numeric-domain supplement

Source remains `9c565c88c9a1366a2e9b18c1b9d2868509510975`. This supplements the same numeric-domain validation root. It does not add an unrelated finding. All work is separate scratch material; no production, tests or main campaign files were changed during the full gate.

## Confirmed original-owner observations

The actual public `ui.menu.menu_tap_holds.build` provider and its returned sticky-delay action execute over an original registered menu fixture. Its backend getter/setter delegate to the actual Remap module loaded through the registered transaction fixture. Each input executes with Remap initially disabled and initially enabled; the actual `get_enabled()` agrees. The setter's enabled lease/lifecycle guards therefore execute in the second group. Native lease observations and persistence remain declared fixture ports.

The recorded AppleScript port returns `true, { ["text returned"] = "1e309" }`, a valid string result. The actual menu callback parses positive infinity, floors it, invokes the actual setter, receives true, then requests regeneration and refresh. The actual live getter and acknowledged save payload contain positive infinity. The first subsequent public menu build succeeds. Using the actual English locale's format string, its label is `Sticky modifier delay: inf s`.

The second action raises **before the second AppleScript call**. The original `delay_dialog_script` floors the stored default and passes it as `%d` to original `text_utils.applescript_format`; the actual `string.format` at shared `text_utils/init.lua:716` raises `number has no integer representation`. Exactly one dialog call, one accepted setter call and one acknowledged save are retained for this case. This is a failure of the public action's formatting path; a native renderer's outer exception handling and actual UI behavior are not measured.

A large finite dialog string, `1e20`, follows the same route: original setter accepts and publishes finite 1e20, label becomes `Sticky modifier delay: 1e+17 s`, and the next action raises at the same `%d` boundary before another dialog call. Finite values outside the representable integer formatting range therefore matter alongside infinity.

Controls behave differently: string `2000` is committed, can be reopened, and renders `2 s`; string `0.9` is floored to zero by the menu and rejected by the actual setter without saving; `invalid` causes no setter call and no save. This preserves the earlier narrow conclusion about fractional menu input, while correcting any broad claim that the issue has no free-text menu entry route.

## Exact ports and limits

Production menu, parser, formatter and setter bodies are required unchanged. Only fixture utility definitions are extracted from `test_karabiner_timeout_regenerates.lua`, stopping before registered cases; no production function is copied. Its minimal backend facade supplies unrelated menu rows. The sticky getter/setter and enabled getter are replaced with direct calls to original Remap owners. The i18n port changes only the sticky title's lookup to the original English JSON value, preserving its real `%s` placeholder.

The original Remap transaction fixture acknowledges saves and records payloads. It stubs generator and native lease dependencies. The menu's regeneration port acknowledges and counts the request; it does not run real rule compilation, JSON publication or lease replacement. The refresh port counts calls, and an explicit subsequent original public `build` checks the actual reconstructed row. Generator build and deploy counts remain zero during these setter calls. No real disk, actual menu click, native osascript process, Karabiner deployment, full logger transport or application receiving result is claimed. A real persistence layer that refuses the invalid numeric value would prevent publication, so these results must retain the acknowledged-persistence qualification.

The enabled fixture confirms that the original setter's enabled-state gate does not itself reject these values. It does not certify native enabled lease availability. The initially disabled observations alone are not used to assert interactive reachability in a running native app.

## Replay

`check_menu_domain.py REPOSITORY` authenticates original source bytes against the pinned commit and runs two final fresh-process sweeps, each with private TMPDIR, `LOGNAME=agent` and the recorded Lua 5.4 toolchain. It semantically asserts ten rows per sweep: five string inputs in each enabled state, saved/live values, setter arity and result, rebuild caption, dialog counts, second-click refusal and the finite/invalid controls. Both sweeps pass.
