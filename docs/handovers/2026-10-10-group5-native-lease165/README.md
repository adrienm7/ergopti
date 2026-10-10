<!-- docs/handovers/2026-10-10-group5-native-lease165/README.md -->

# Native lease receiving handoff

This source-only packet adds independent manual ARM and Intel receiving of the
existing `KarabinerLeaseWorkerTests` (146) and
`LeaseDiagnosticNextObservationTests` (19). Native execution remains **UNRUN**;
the workflow is **NOT ENROLLED**. It does not fix or attribute the reported
first tap-hold exit 73, and does not qualify packaging, installation or hardware.

The exact source base is
`ac4f1f1a52e70eb8fbd1798bf521b8c1daaa5012` on `feat/macos-input`.
[SOURCE.patch](SOURCE.patch) contains nine paths. Six existing files receive
only bounded owning cuts, and three files are new. The generic full-XCTest
parser remains byte unchanged. No old workflow or guard postimage is copied
wholesale into this base.

The adaptation preserves every current byte outside its declared cuts,
including incoming Windows retention conditions. It has 17 unified diff hunks:
15 changed opcode cuts across the six existing files, of which 14 original
contexts match uniquely and one pipeline inventory row uses the current
`STEP_CONDITIONS` opening before the existing `WINDOWS_FILE_RETENTION` spread.
The lease row itself is unchanged. Forward and reverse application were checked
in a disposable sparse source tree; all nine postimages and all original
preimages match [CONSERVATION.json](CONSERVATION.json).

## Receiving contract

The new reusable macOS sibling has no package prerequisite and is reached
through the existing top-level Validate dependency. It runs only for
`workflow_dispatch` with release disabled. ARM uses `macos-15`; Intel uses
`macos-15-intel`. The independent job budget is 25 minutes. The original full
Package/SDK clocks, consent conditions, default DAG and release verdict remain
unchanged. A red mandatory original job stays red.

Checkout binds `github.sha`; runtime `uname -m` must match the declared
architecture. Begin/judge receipts bind the committed native compiler input
inventory before and after the run. The historical method roster is frozen
independently; no expectation is regenerated from a candidate implementation.

[SWIFT-CHILD-SCRIPT.sh](SWIFT-CHILD-SCRIPT.sh) is the unchanged embedded producer.
It clears inherited errexit immediately before the unchanged Swift command,
captures `$?` immediately afterward, publishes an exclusive owned mode-0600
canonical decimal status plus LF, and exits with that same status. The BSD
`script` wrapper and `tee` statuses remain separate. No missing child receipt
or success override is accepted.

The receiver requires child, wrapper and capture status zero, both complete
named cohorts, exactly 165 original terminal passes, no skip/failure/duplicate
or malformed transcript, unchanged source inventory, and matching runtime
architecture. Missing, malformed, aliased, foreign-owned, multilink, wrong-mode
or nonzero child status refuses admission even with a complete transcript.

## Evidence and limits

Actual software receiving completed 57/57 combined controls and 19/19 individual
public-CLI vectors. The retained predecessor completed its original 38/38,
while the independent stricter 19 vectors failed 12 and passed seven there.
These were software subprocesses with a fixed modeled XCTest transcript and
controlled Git input. Foreign ownership uses a disclosed UID observation model;
actual foreign-user ownership and Windows POSIX permissions are not claimed.
See [SOFTWARE-RECEIVING.json](SOFTWARE-RECEIVING.json) and original receipt/review
hashes in [PROVENANCE.json](PROVENANCE.json).

[NATIVE-PINS.json](NATIVE-PINS.json) binds the five current worker, store,
guardian and original test source bytes, the immutable historical 146+19 corpus,
and producer script. The five source pins do not substitute the eventual whole
compiler inventory, executed SHA or architecture receipts. Neither Swift
compilation, native test execution, BSD wrapper behavior nor either architecture
has been observed for this proposed job. The separate proposed 147th synthetic
heartbeat experiment is outside this corpus and outside this patch.

## Owner receiving steps

The [bounded coordination notice](https://github.com/adrienm7/ergopti/issues/86#issuecomment-6098082135)
names all nine paths. G3's active NumberRow region in
`test-macos-dev-qualification-deferral.cjs` and G6's workflow/retained-clock
regions still need an exact nonconcurrent handoff. This packet preserves their
current source; it does not claim that a prior general clearance transfers
active writer ownership. The current-base adaptation needs independent source
review before publication or enrollment. No new user permission is required
for already authorized work.

Receive only the exact reviewed cuts onto the final merged source, recheck
preimages, and preserve newer owner changes. Run the selected verification
serially after adoption; this packet does not qualify changed current guard
postimages merely because the prior receiver models passed. Then use the
existing `ci.yml` manual `os_lanes=macos` input on the group's own CI branch.
There is no top-level manual `release` input; verify the actual Validate
no-release marker. Cancel only automatic workflows for each exact push SHA,
and leave manually dispatched validations untouched.

Keep all original mandatory results and each ARM/Intel lease job separately
classified as passed, failed, skipped or unrun. Require the strict 165 verdict,
actual child/wrapper/capture statuses, tested SHA and architecture receipt before
claiming native receiving. A successful sibling is not whole-package approval.
