# Adversarial parity review: complete action and persistence flows

Audited SHA: `213d65af24d2aa4845ba47743c9bab6787b61964`. Date: 2026-11-04.

This continuation examines 12 OS × module scopes: clipboard/selection, secret and cipher storage, configuration persistence, and fixed native desktop actions, each on Windows, macOS and Linux. Six delegated reviewers and root followed entry points through the real owner, side effect, acknowledgment and cleanup. Each scope records two consecutive final sweeps without a new confirmed issue in its declared coverage. This is a stopping condition for those scopes, not proof that every product feature or native timing is correct.

## Reviewed follow-ups

There are **26 OS/flow follow-up entries**. The cipher marker collision is one shared cause with three OS manifestations; rejected-locale publication has macOS/Linux manifestations. These numbers are not 26 distinct root causes or 26 native-desktop reproductions. An approved-overwrite failure is explicitly classified as a reproduced data-loss risk rather than an unconsented overwrite or a promised atomicity violation.

| OS × module       | IDs                                                  | Evidence                                               |
| ----------------- | ---------------------------------------------------- | ------------------------------------------------------ |
| windows-clipboard | WCP-001, WCP-002                                     | [Scope, flows and limits](windows-clipboard/report.md) |
| windows-crypto    | WCR-001                                              | [Scope, flows and limits](windows-crypto/report.md)    |
| windows-config    | WCF-001                                              | [Scope, flows and limits](windows-config/report.md)    |
| windows-desktop   | WDS-001, WDS-002                                     | [Scope, flows and limits](windows-desktop/report.md)   |
| macos-clipboard   | MCP-001, MCP-002, MCP-003                            | [Scope, flows and limits](macos-clipboard/report.md)   |
| macos-crypto      | MCR-001, MCR-002, MCR-003, MCR-004, MCR-005, MCR-006 | [Scope, flows and limits](macos-crypto/report.md)      |
| macos-config      | MCF-001                                              | [Scope, flows and limits](macos-config/report.md)      |
| macos-desktop     | No new confirmed entry                               | [Scope, flows and limits](macos-desktop/report.md)     |
| linux-clipboard   | LCP-001, LCP-002, LCP-003, LCP-004                   | [Scope, flows and limits](linux-clipboard/report.md)   |
| linux-crypto      | LCR-001, LCR-002                                     | [Scope, flows and limits](linux-crypto/report.md)      |
| linux-config      | LCF-001, LCF-002                                     | [Scope, flows and limits](linux-config/report.md)      |
| linux-desktop     | LDS-001, LDS-002                                     | [Scope, flows and limits](linux-desktop/report.md)     |

## What is deeper in this pass

- Clipboard tests cross real Text/Apps owners, not just one module: a second borrower can snapshot an intermediate payload; delayed restoration can erase a newer copy; a transform can target a different application or range. Positive controls establish which producer owned the clipboard or selection.
- Crypto tests join raw typed-text ingress, actual SQL composition and migration. Linux controls use genuine native EVP/OpenSSL primitives with synthetic keys; a raw string colliding with the persistence marker bypasses protection. API credential tests follow actual metadata publication and replacement, not just a mocked encryption helper.
- Persistence tests use real storage/canonical-file writers with refusal injected at the native rename/settings boundary, then perform actual next-start adoption. They distinguish truthful saved intent from rejected choices that still become authoritative.
- Fixed desktop actions are checked for actual refusal reporting and overlapping state transitions. Two accepted Linux theme toggles demonstrably lose one update through the real public dispatcher and private native-settings tool. Linux executes the generated command through a real POSIX shell with a scratch fake native tool; Windows native integration remains source-derived, with the exact PowerShell worker body separately executed under a real engine and fake cmdlet.
- Findings were independently challenged. Windows clipboard claims were narrowed to external focus changes: a fixture calling Suspend inside a snapshot is not proof that an ordinary pause thread can preempt native ClipboardAll under Critical. Native focus changes are not prevented by Critical.

## Intent, security properties and evidence

Every scope has its own intentional-difference/rationale table; the [cross-OS register](intentional-differences.md) and [JSON snapshot](intentional-differences.json) summarize the principal behaviors. Explicit policy, implementation constraints, missing qualification and unknown intent remain distinct. None of the reported loss/race behavior is excused merely because its implementation is visible in source.

The five existing G1–G5 labels cover runtime/output/race/lag/preview guarantees. This review also names confidentiality, data integrity and persistence consistency directly instead of inventing G6 or forcing a loud failure into a silent-output guarantee. Reviewed `findings.json` takes precedence over broader submitted labels; `submitted-findings.json` preserves the pre-integration classification. Root qualifies WCP-001/WCP-002, WCF-001, MCR-001 and MCR-006 explicitly.

## Reproduction and validation

All 26 entries name an exact scenario, root cause, failure visibility, severity/confidence and root-cause regression to add when implementing a fix. Root opened the proof programs, checked native return contracts and replayed the available safe module probes. Reports retain per-module test receipts, failures and native exclusions. Do not add overlapping batches or two Lua runtimes as unique tests.

The artifacts use a new campaign directory because the earlier same-day dated AHK/Hammerspoon reports are immutable. The existing audit CLI only admits one dated envelope per OS/day and has no Linux or extra-property scope. It is unchanged and is not falsely reported as validating this campaign. Run `python docs/audits/platform-parity/2026-11-04-flows/validate.py` for this campaign’s structural/evidence-link checks; this is metadata validation, not runtime feature certification.

The generated inventory still exhaustively projects shared declarations/action catalogues/restricted menus, not every native behavior. The existing generator/drift gate owns the website data and linked README inventory. This manual, revision-pinned behavioral audit supplements that inventory; it is not regenerated from an assumed equivalence between catalogue presence and correctness.

## Native and reproduction boundaries

- No Windows/AHK desktop, macOS application/process-table permissions, real clipboard, user secret service, hardware input, actual trash or display topology was exercised. Recording ports and source-backed AHK probes are labeled accordingly.
- Linux/OpenSSL/POSIX shell/PowerShell engines really executed only private synthetic fixtures; this does not certify macOS AppleScript/LaunchServices, Windows PowerShell5.1 or actual device/provider behavior.
- G4 application latency and live heap/process retention remain unmeasured. Each scope maintains its memory/ownership watch-list and native acceptance exclusions.
- Proof programs retain their original absolute checkout/toolchain roots. Retarget and run copies in owned scratch space at the audited revision; some programs write fixture SQL or regenerate unexecuted AHK probes next to themselves. Do not replay into immutable published evidence or execute raw native-effect worker bodies outside their recording harness.

See [delivery validation](delivery-validation.md) for structural checks, source identity and selected repository/hosted outcomes. Earlier reports remain [separately available](../2026-11-04-deep/report.md).
