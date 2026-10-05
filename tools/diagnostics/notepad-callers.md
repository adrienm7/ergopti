<!-- tools/diagnostics/notepad-callers.md -->

# Owned Notepad caller diagnostic

This manual Windows experiment checks the actual HSE literal and LLM acceptance
callers against the installed modern Notepad receiver and current native editor
DLL. It activates an owned synthetic document. Save and close all Notepad windows
first, allow foreground testing, and leave the keyboard idle until it finishes.

Run from PowerShell 7 after building the canonical Windows native DLL:

```powershell
& ./tools/diagnostics/notepad-callers.ps1 -Interactive
```

An alternate AutoHotkey v2 executable can be supplied with `-Runtime`. The tool
records its hash and the package executable/version. Missing Notepad, missing
dependencies, an existing Notepad process, or failed ownership admission returns
failure. This is an optional receiving experiment, not an automatic CI gate.

The supervisor creates a fresh ignored `build/.codex-notepad-work/notepad-callers-*`
directory. It extracts the production includes from `tests/run_all.ahk` in their
canonical order, excludes ordinary unit/meta/E2E registrations, then includes the
two existing isolation fixtures required by the six callers. It never executes
`RunTests` or the production driver entry. Hooks and keyboard send ports are
replaced by the headless test owners; the native editor Begin/Poll/Decide/Close
ports remain actual DLL exports. The native worker receives the exact owned
foreground window, control, PID and deleted suffix.

The six cases independently compare the full literal document and full DWORD
caret. They cover insertion, the reported 16-to-50-character prediction correction,
a supplementary Unicode suffix, `ctâ˜… â†’ câ€™Ã©tait`, uppercase conformity, and a
consumed delimiter. Actual canonical HSE/LLM mirror and completion assertions
run alongside the receiving checks. Scheduling and presentation admission are
controlled test ports; this does not exercise a physical/default InputHook trigger.

`receipt.json`, `stdout.log`, `stderr.log` and the generated runner remain in the
owned output directory. The receipt records source hashes before/after, DLL
hashes, runtime/package identity, retained process creation times and natural
sender retirement. All six named TAP rows and empty stderr are mandatory.
Existing broad include-graph warnings are retained and counted; a successful
receiving observation does not claim warning-free parsing or persisted journal
rows. Do not remove an active output directory.

The supervisor never force-kills the sender. If a synchronous native message or
worker remains unresolved, it retains the sender and target and reports debt.
It retires only its exact acquired Notepad child and launcher after natural sender
exit. It validates the exclusive synthetic title before every control message, and
refuses a tab change inside the acquired process. It never adopts a pre-existing
process or reads an existing document, and
uses no clipboard or keyboard transport. Focus and external process changes can
still invalidate a trial. Package profile restoration is not proven isolated;
the experiment owns the selected synthetic document, not Notepad's shared profile.

Historical finite evidence is retained in
[`docs/audits/ahk/2026_10_05/notepad_native_receiving.md`](../../docs/audits/ahk/2026_10_05/notepad_native_receiving.md).
