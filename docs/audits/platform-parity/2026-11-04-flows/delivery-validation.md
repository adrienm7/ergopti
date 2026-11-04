# Delivery validation

Source and registered tests remained unchanged at `213d65af24d2aa4845ba47743c9bab6787b61964` while the 12 scopes and independent counterchecks ran. Earlier audit reports are unchanged.

Root inspected the actual proof programs and native return contracts and replayed safe clipboard, real native crypto/SQL-composition, key publication, locale/startup and legacy-import sequences, plus the exact PowerShell worker/POSIX-shell controls. Windows AHK remains unexecuted. Linux secret-write reproduction requires the native-capable LuaJIT runtime; an initial root Lua5.4 attempt refused API setup and was superseded by the successful genuine LuaJIT replay. The root logs retain both outcomes.

The Linux clipboard multi-module batch contains one order-dependent locale test failure on both runtimes; the isolated test passes on each. The Windows config Lua comparator is an unsupported/incomplete harness, not an AHK pass or a product failure. Scope reports retain the exact limitations; aggregate registered-case totals are not summed across overlapping sweeps/runtimes.

The existing canonical audit workflow rejects scratch/campaign paths, Linux and confidentiality-only entries. This campaign preserves that existing validator and its earlier envelopes; a separate strict artifact check validates this campaign’s source identity, IDs, types, additional properties, shared-root membership, TODO coverage and evidence links. It does not claim runtime parity certification.

## Local selected gates at the audited source

`verify-change` selected formatting, AHK encoding and the full JS suite. Formatting and encoding passed. The [complete receipt](validation/verify-change-213d65a.txt) records 570 JS checks completed with four failures and one explicitly unexecuted AHK host case; this was not a green suite.

One failure was a task-generated, ignored CPython bytecode file accidentally admitted by the bundle scanner. Only that confirmed transient file was removed ([receipt](validation/bytecode-cleanup.json)); the unchanged [Windows bundle test then passed](validation/bundle-rerun.txt), including its 60 negative controls. Later Python invocations disable bytecode writing.

Two source/CI failures (release fixture missing ref and obsolete Pages-wiring expectation) reproduce at the older baseline; their immutable receipts remain in the earlier deep audit. The [source identities](site-baseline-identities.json) apply through reviewed dev `1fa4c28`, not later migration commits. A third failure is the existing macOS native installer invocation missing from the owned-runtime program registry. Baseline attribution is separately recorded; no production registry or failing assertion was weakened to make this documentation pass.

The [strict convention lint](validation/conventions.txt) passed. These repository checks supplement the individual safe probe replays; they do not execute a Windows or macOS desktop. Later source integration and hosted outcomes are recorded separately below.

## Intervening dev source changes

Reviewed dev advanced to `1fa4c28f318258dd1af31920b1a55b8bb4c33de1` while this revision-pinned audit ran. The three intervening commits repair Windows word-start matching and strict-case personal-editor serialization, plus their TODO. The [Windows delivery delta review](delivery-delta-windows.md) confirms the six new Windows flow entries and the Unicode/wrapping/clipboard mechanism rows remain applicable. Do not advertise the repaired punctuation word-start or strict-case save behavior as a current gap; the prior immutable reports retain their historical source. New source does not by itself qualify native preview/focus/performance.

## Folder-migration delivery delta

Fetched dev then advanced to `89d477dcc06b85b71071e6d5f1fe8d701bf51649`. Independent bounded reviews for [Windows](delivery-delta-paths-windows.md), [macOS](delivery-delta-paths-macos.md) and [Linux/shared](delivery-delta-paths-linux.md) retain all 26 findings by unchanged causal code or path-only changes. Root checked the macOS/shared owner Git blob register independently ([receipt](validation/delta-macos-identities.json)). The new boot migration is a material added owner, outside the original dry-pass coverage. Historical paths remain qualified by these delivery mappings. Notably Linux bootstrap storage now shares the default config directory, but still uses a separate file and commit owner; macOS compiled Karabiner runtime paths retain an explicit exception.

The [installer baseline replay](validation/installer-baseline/report.md) uses the exact immutable parser, Swift source and validated registry at `213d65a`, `1fa4c28` and `89d477d`; all reproduce the missing installer declaration. Root opened and independently replayed it. Diagnostic exit zero confirms the omission, not a passing full inventory test. An optional full git-backed scan was stopped without completion and is not counted. The code/registry mismatch is now separately tracked in TODO.

## Checks after integration with dev

The first audit commit was rebased onto `89d477dcc06b85b71071e6d5f1fe8d701bf51649`; all production files, registered tests, workflow files and package manifests are identical to that parent. Documentation/proof artifacts are the only delivery changes. The selected [verification plan](validation/delivery-plan.txt) remains format, AHK encoding and JS; the full 570-check result above applies to the pinned source, not a newly repeated complete suite on this later parent.

Targeted reruns at integrated audit commit `7eb0bc5`:

- [Release resolver](validation/delivery-site.txt): **passes**, 35 source controls. Upstream fixed its earlier fixture failure; it is not advertised as currently failing.
- [CI wiring](validation/delivery-ci.txt): **fails**, now on `remap-runtime-build.yml` / `install-acceptance` permissions (`contents: read actions: read`). This is a different assertion from the older Pages-wiring failure. The workflow/test bytes are unchanged from the fetched parent; it is not attributed to this audit.
- [Owned-runtime inventory](validation/delivery-owned.txt): **fails**, the same pre-existing missing macOS `installer` declaration proved above.
- [Windows bundle](validation/delivery-bundle.txt): **passes**, including 60 negative controls; no transient bytecode included.
- [Generated feature/action/menu/input inventory drift](validation/delivery-drift.txt): **passes**, exit zero with no output. The generator is the existing owner; no generated output was hand-edited.
- [JS test inventory](validation/delivery-inventory.txt), [AHK encoding](validation/delivery-encoding.txt), and [campaign metadata](validation/delivery-metadata.txt): **pass**. The campaign also has four refusing metadata negative controls. Encoding checks bytes only, not AHK execution.

The commit hook ran exact-file Prettier/Ruff formatting, staged AHK encoding and strict conventions successfully. Later receipt prose adds no runtime changes. A redundant verification invocation made while inspecting CLI options was stopped during formatting before another JS suite; it supplies no counted result.

Hosted preflight uses `tmp/preflight-dev` with `ci.yml` and `os_lanes=all`. Its live run must be inspected by exact commit in GitHub Actions; this report does not manufacture a green hosted verdict or qualify any unexecuted native scenario. Delivery follows the maintainer’s documented partial-work policy, leaving code and native gaps open.
