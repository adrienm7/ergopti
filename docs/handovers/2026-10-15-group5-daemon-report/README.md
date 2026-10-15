<!-- docs/handovers/2026-10-15-group5-daemon-report/README.md -->

# Daemon report source handoff

This checkpoint preserves a reviewed, unapplied 15-path proposal for a passive
VirtualHID daemon report. It is based on
`56c4c98ab4b673213b20d90199794fdcd4a43ee3`. The preparation base had received Dev `7cf0c151`. The receiving branch also
receives Dev `d60ad231ae41c7391c1012c5feb9fc5723bbcca4` through a normal merge;
this handoff adds only these documents and the TODO item 31 note.

This is **not a standalone Dev backport**. The reviewed G5 source base supplies
`VHDChannelClock` from `OwnedVirtualHIDDriverPublicationTransport.swift`,
`OwnedVirtualHIDDriverPublicationReference` for the fixed daemon catalogue, and
`ergopti_vhd_publication_channel_peer` through its C/header owner. Those dependencies
are absent from standalone Dev `d60ad231…`; the CPOSIX, Main, installer and builder
preimages also differ from that Dev tree. Matching the 15 proposal preimages on
the receiving G5 branch does not establish a complete standalone dependency
closure. Root/G3 retain adoption and SDK roster ownership. A separate bounded
Dev-compatible successor is needed; do not import the G5 history to fill these
seams automatically.

`SOURCE.patch.gz` losslessly preserves the exact prepared production/test patch.
Its decompressed SHA-256 is
`18877591f7aca83ac845964d8878ebe160eb45b5d26030786cbc2ae84687a942`.
`MANIFEST.json` lists all repository-relative paths, exact preimage/postimage
hashes, new-file absences and relative receipt locations. `PATCH-RECEIPT.json.receipt`
records 15 exact forward and inverse images in a small private source view.
The three JSON review receipts use a `.receipt` suffix and retain their original bytes; their historical private
preparation locations are provenance references, not required inputs or commands.

The proposed observer admits only a protected, authenticated daemon endpoint and
an exact report/ACK exchange. Its five Boolean observations describe a historical
sample. The connected worker, staged owner and Main relay preserve source and
retirement checks; unknown partial acquisition, identity or closure retains
refusal/debt. No report grants numeric ABI compatibility, live READY, installed
readiness, remote daemon cleanup, an input capability or an installation/update
permission. This does not establish the cause of the lease incident.

Independent source review covers the component, worker enrollment and connected
relay. The proposal authors 28 XCTest methods; **zero have executed**. There is
no Swift compilation, real SDK, Darwin endpoint, ARM/Intel or privileged receiving
proof. Source review and exact patch inversion are not runtime acceptance.

Before adoption, the receiving owner must compare every manifest preimage against
its current source and obtain the current Root/G3 shared-file handoff for the
C/header, Main, installer entry and product builder. Preserve existing assertions,
source approvals and ordinary startup/publication behavior. Do not import a whole
feature branch or apply this patch over changed preimages. A non-mutating initial
check from the repository root is:

```sh
set -o pipefail
gzip -dc docs/handovers/2026-10-15-group5-daemon-report/SOURCE.patch.gz | git apply --check --whitespace=error -
```

After authorized source receiving, qualify the genuine signed dependency closure
with a real macOS SDK, execute all 28 authored methods on ARM64 and Intel, and
perform the privileged success/refusal/peer/signature/descriptor/debt/retirement
cases. Remote cleanup and physical installation remain separate observations.
The feature requires Darwin Security, native process/socket identity and the
macOS daemon; Windows and Linux cannot supply those authorities. No workflow,
compiler roster or shared production source is enrolled by this checkpoint.
