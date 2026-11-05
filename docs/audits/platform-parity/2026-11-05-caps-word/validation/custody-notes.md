# CapsWord audit custody clarifications

## Linux standalone diagnostic

The original Linux submission says that the exact owner program passed a
standalone diagnostic. The reviewer confirmed that the retained standalone
diagnostic used `owner-debug.lua`, an instrumented program with different bytes.
There is no retained byte-identical standalone receipt before TMPDIR isolation.
The root integration adds an explicit corrective note above the original report.
This is an editorial correction, not a formatting-only or semantic-equivalence
claim. The submitted body and its original hash remain available verbatim.

- Original report: `validation/original-submissions/linux/report.md.txt`.
- Original SHA-256: `73493878ee5c20a3a19b06be800707875887a89d4d1862d4b4883d83069fc1cd`.
- Corrected archive: `linux/report.md`.
- Corrected SHA-256: `3226591e1ec9ae9ae0fe3e184214fcc29fa8bace871c93edc571fa93aeea4de8`.

The unsuccessful parallel batch receipt and its raw failed stdout/stderr are
retained under `linux/pre-isolation-proofs/`. Its owner program SHA matches
`linux/owner-probe.lua`, `linux/owner-initial.lua.txt`, and the owner SHA in both
final process-private TMPDIR sweeps: no owner assertion changed. These later
passes do not establish a cause for the earlier failure. A temporary-name
collision remains a hypothesis rather than a reconstructed failure or repaired
production defect.

## Initial Linux modifier-key fixture boundary

The initial `linux/owner-probe.lua` supplies physical Ctrl and Shift key codes,
but its recording XKB backend implements `key_sym` as a nil return for every
key. Its `ctrl-tab-checked` row therefore does not establish that the actual
Ctrl-modified control admission branch ran: a bare Tab path can satisfy that
assertion. The `modifier-does-not-wake` Shift-code row likewise does not itself
qualify the Hook's actual modifier-role classification. The frozen initial
observations, source and worker hashes remain unchanged.

The separately frozen [synthetic-output follow-up](../linux-synthetic-followup/report.md)
uses native-shaped numeric `Control_L` and `Shift_L` keysyms and explicitly
asserts the actual XKB adapter's modifier-role result. Its qualified Ctrl+Tab
control reaches the semantic control callback with `mods.ctrl=true`; its
qualified Shift idle control rechecks the modifier-only observation. These
recorded-backend results strengthen the corresponding boundaries without
claiming a native XKB/desktop session or retroactively upgrading the old fixture.
The initial pointer-dispatch and menu-policy findings remain separately supported
by their own controls and source owners.

The follow-up also demonstrates a CapsWord consumer consequence of the existing
`WRSL-001` generic catalogue-output publication root. Ordinary Enter/Tab tap
actions and literal-injector output are positive controls, not failing routes.
It adds twelve separately qualified observation rows, four final processes and
one known-root extension; it adds zero new independent finding roots. The
initial 159-row/nine-finding custody snapshot remains historical and unchanged.
