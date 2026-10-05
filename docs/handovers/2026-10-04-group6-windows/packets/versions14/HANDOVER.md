# Versions managed-network failures (scratch candidate)

Scope: only the native Versions consumers, shared chosen-release sequence/page,
and their regression controls. No repository edits, staging, commits or pushes.

## Composition

Apply after the frozen Linux managed-failure caller patch. This packet's Linux
changelog preimage is that packet's source (fourth callback receipt forwarding),
not the original checkout file. Every other preimage currently matches checkout.
`preimages.json` and `sources.json` record exact bytes/hashes. The frozen patch is `managed-versions-failure.patch`; `handoff.json` records its
checksum and the exact validation receipt.

Dependencies owned by other agents/root:

- Canonical `network.failure` Lua interpreter and `managed_network.json`.
- Windows failure_host Init/Classify/PerformAction, initialized exactly once
  from native root boot before Versions can observe failures.
- Windows typed failure observer's third native argument, the private
  `_Updater_GetManagedFailureOwnerFor(Request, Release)` getter, current-owner
  predicate and `_Updater_RetryManagedFailure(Owner)` from the staging owner.
- Linux updater manager fourth callback receipt producer/forwarding and the
  real curl failure receipt. This packet keeps its Linux receipt-forwarding
  preimage and does not overwrite that producer.
- Root JS registry entry for `tools/test/test-changelog-managed-failure.cjs`.
  Existing Linux/macOS/Windows contract test entries gain additive controls;
  the existing real Chromium Versions scenario gains six managed assertions.

## Behavior and private boundaries

The Lua sequence retains a native receipt only in the exact completed operation.
An independent monotonic operation number plus failure epoch fences action
messages and same-tag retries. The canonical classifier receives actual private
native capability checks. Missing typed evidence becomes canonical unknown.
Verification, backup, asset, installation, swap and restart failures keep their
existing reason and stop order; successful downloads still enter the original
installer and restart ports. Retry passes through backup-first again on Lua.

Linux captures the actual trusted native route context's page epoch and requires
that exact current epoch/visible WebView as well as the unchanged release-list
owner, source generation and daemon owner. Missing native route context admits
no action. macOS captures exact focus owner, native WebView and content controller
plus release list/source generation. Closing retires action authority while an
already running native install follows its existing completion lifecycle.

Windows observer closures now capture exact private operation identity as well
as tag. They cannot publish into a later same-tag transaction. The native failed
entry captures its exact Request+byte/case-identical release staging owner before
logging or COM probes. Classify/PerformAction use the shared native failure_host
and recheck the current terminal, window/list, staging and pause owner. Retry
uses the retained staging intent's native retry helper and its authenticated
asset/digest/pause/channel checks. It preserves the backup already created
before the first staging dispatch and restores the Versions observer before
retry, so install/verify/handoff phases remain visible.

Only public scalar phase data plus `{cause,message_key,actions:[{id,label_key}]}`
is serialized to the page. The prior explicit backup_path display remains;
no native receipt URL, receipt path, stderr, credentials, Request or release
metadata is included in the safe report. Windows JSON serializes a field
allowlist and strips arbitrary report/message metadata. A public
`managed_failure=true` marker suppresses the old unbound generic Retry even if
policy/native inspection fails or a managed report is malformed. Generic
integrity/backup/install failures retain their original retry behavior.

## Qualification still required

Authored controls: 12 pure Lua cases against the real canonical policy, retaining
all existing shared chosen-release sequence cases; seven real-page recording DOM
cases; two additive Windows native unit cases; six extra Chromium assertions.
The parent then granted one short exclusive slot. Sequential scratch replay
passed 22 Lua cases (12 new + 10 existing), seven managed page controls and all
55 original Versions page assertions, all exit 0. The untouched Lua preimage
passed the verification-preservation case and rejected 11 new expectations.
The untouched page chain failed the first translated proxy-cause assertion
(exit 1). A first authored page replay exposed an incorrect test expectation
for existing translation placeholders; that expectation was corrected using
the independent fixture tag/path without production edits or removed assertions.
The slot was explicitly closed before any root full-gate work resumed.

macOS chosen-release stage currently does not guarantee a typed failure receipt.
Its consumer forwards an optional fourth value without inferring from detail or
stderr: actual absent evidence stays unknown. macOS/Linux Versions advertise
only an actually bound retry in this tranche. No qualified native settings/log
opener or privately owned output folder is provided here, so those actions are
honestly unavailable. Windows uses the actual settings handler and inspected
native log/opener capabilities from the sibling adapter; no output folder or
alternative backend capability is invented.

Focused controls prove shared caller/page behavior under controlled I/O, not
actual network, GTK/WebKit, AHK, native Windows/macOS installation or packaging.
Those gates and the existing real Chromium scenario remain parent-owned.
