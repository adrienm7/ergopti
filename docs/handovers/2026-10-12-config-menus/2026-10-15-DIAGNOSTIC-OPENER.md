<!-- docs/handovers/2026-10-12-config-menus/2026-10-15-DIAGNOSTIC-OPENER.md -->

# Diagnostics desktop-opener receiving

## Problem and source contract

The Linux report producer previously started `xdg-open` through a background
shell. A private executable independently exits 23 while that literal producer
returns `ok: true` for `open_path`. The reproduction opens no actual desktop
application. The child exit and the producer's returned result are retained
separately; successful shell dispatch did not receive the child failure.

The producer now uses the existing asynchronous shell adapter, with an argument
vector, a canonical `ui.desktop_open_timeout_ms` deadline, cancellation and a
terminal native receipt. Copy and attachment write/close precede reveal; reveal
completion precedes opening the issue URL. The existing warning policy for a
failed folder reveal remains in force. Clipboard, attachment and browser
refusals retain their separate outcomes.

The healthcheck and error-dialog bridges retain the exact session, snapshot,
action and routed window ownership. Retired or superseded operations cannot
continue into another effect or publish a late success. The shared Lua
update-check controller receives report completion through the same explicit
callback contract. Its Linux adapter propagates native completion; its macOS
adapter completes inline from its existing native receipt. All real callers
are adapted, including the feature-request opener and direct update-error
report. The Windows report producer is separate; its installed qualification
remains required.

## Dated receiving boundary

At preparation, published feature base is
`cfb95d2e8fe5ebe587a6938934850fd80369b532` and Dev is
`e850833c74f3f10c6718eb822fd2aa21f83f13b2`. The real-child predecessor
refusal mismatch is received. Focused successor tests and independent lifetime
review now pass: 113 focused cases, including the original 77 and 36 additions;
the separate macOS adapter module passes nine cases, retaining its six original
subjects. The existing native diagnostics-save harness passes all seven
kernel receipts. The independent source review accepts the bounded lifecycle
joins. The separate macOS module capture predates the final shared-controller
reentry repair; its two macOS postimages remain unchanged. The complete
composed macOS suite is still required. Selected gates and new hosted receiving have not yet been
earned at this dated boundary. Their later exact source images, terminal
results and failure details must be received separately.

The pre-dispatch refresh subsequently receives Dev
`ccf7d35e40fd0a38b7ee346bfdb1bc42a01d80fd`. Normal feature merge
`614970f3c2f8c2c1b6c27e27ff1c513dd6c933d7` preserves its six published Windows
atoms and all eight incoming non-TODO files byte-for-byte. The owned candidate
is recoverably transferred onto that base, preserving the incoming TODO and
every code/test postimage. New validation must use that refreshed composition.

The preceding [Linux manual run](https://github.com/adrienm7/ergopti/actions/runs/38734785529)
naturally succeeds: 28 jobs, 25 successful and three skipped, including all 17
installation/launch variants. Its actual SHA is
`a31bc6fe438dace2ad2a0efb1a896c8fb9093cb9`, tree
`3fbc8dddccd8262265b35eab80bc08978b062493`, exactly source
`4dce81d67b0343974ac7026f0f8f19b56f838d49`. The proof-only successor `cfb95d2e8`
adds one inactive receiving archive. That run predates this opener correction.
API job outcomes do not establish hosted raw assertion counts or actual GitHub
form editability. macOS, Windows and Release were skipped by that Linux run.

## Remaining installed acceptance

Use a disposable installed profile and record its package/source identity.
Generate diagnostics with actual detailed results and a known admitted error.
With a non-English UI, verify that copied and saved technical reports remain
English and anonymized, and that the complete attachment closes successfully.
Refuse clipboard/write/close operations independently and require the browser
to remain unopened until the attachment is available.

Receive the actual desktop handler's nonzero exit and deadline. Check that a
failed folder reveal retains its warning, and that a failed browser launch is
reported. Replace or close the owning window while an opener is pending;
require no successor effect or stale action acknowledgement. Then open the real
GitHub draft and edit its diagnostic fields without URL values restoring them.
Keep this scenario separate from executable fixtures and portable WebView
tests. Repeat the applicable export flow on Windows and macOS.

Complete daily-log collection still needs a shared privacy/collection contract
and collectors for all three native drivers. The existing recent-error reader
is bounded to 64 KiB and 50 entries. Complete export/generation binding and
installed issue editability remain open in item 138; no automatic upload is
introduced. Group 1 items 5, 7, 33, 42, 54 and 81 remain partial, with transversal
16 and 38 mandatory. Root's integration HOLD remains in effect; no new Dev/Main
publication or group closure is claimed.
