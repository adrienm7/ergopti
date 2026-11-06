# One-shot Shift audit metadata projections

`owner.json` is the root reviewer's adjudicated input for source
`9c565c88c9a1366a2e9b18c1b9d2868509510975`, dated November 5, 2026.
Each of the four exact roles (`windows`, `macos`, `linux`, `shared`) has a
qualified coverage register, report and evidence; findings may be empty.
No source, runtime, native or physical coverage is inferred from metadata
acceptance. Original submitted evidence and any archive transformations must
retain explicit provenance.

From this campaign directory, with the repository's pinned Node on PATH:

```sh
python3 project.py --repo-root /path/to/ergopti
python3 project.py --repo-root /path/to/ergopti --check
python3 check_project.py /path/to/ergopti
python3 check_sources.py /path/to/ergopti --output /tmp/one-shot-source-check.json
python3 validation/replay.py /path/to/ergopti /tmp/one-shot-replay
python3 validation/check_source_guards.py /path/to/ergopti /tmp/one-shot-guards
python3 validation/check_public_channel_admission.py /path/to/ergopti /tmp/one-shot-channel
python3 validation/check_config_domain.py /path/to/ergopti /tmp/one-shot-domain
python3 validation/check_menu_domain.py /path/to/ergopti /tmp/one-shot-ui
python3 validation/check_real_config.py /path/to/ergopti /tmp/one-shot-real
```

The generator validates the input before producing `index.json`,
`findings.json`, `capabilities.json` and `capabilities.md`. `--directory` selects
another campaign root. The check mode rejects missing or changed projections.

The source checker authenticates 132 role claims across 107 distinct files against
both pinned Git content and current bytes; changed files require a new review,
not automatic receipt updates. It works on descendants of the audit commit.
The frozen Linux worker source checker additionally requires the original HEAD,
so its execution is historical; the aggregate checker owns descendant checks.

The replay runner requires genuine Lua 5.4, LuaJIT, Node 22, Python and
libxkbcommon with standard XKB data on a Linux host. The other drivers run
through the qualified source/recorded-port checks described in their reports.
Put those tools on PATH; set
`PARITY_TOOLCHAIN_BIN` when a separate toolchain directory is needed. The saved
workspace-specific tool paths in receipts document the original environment.
Fresh replay outputs go into the explicitly selected directory, with private
TMPDIRs for subprocesses; frozen role logs remain unchanged. Logical owner
replays and the separate native XKB component control do not prove receiving
application behavior. Timing warnings and failed diagnostic attempts are
retained separately from final acceptance receipts.
Canonical IDs use `OSW-001`, `OSM-001`, `OSL-001` and `OSS-001` where applicable;
any normalization preserves `submitted_id` and is not another finding.

The supplemental commands accept explicit output directories so future runs
leave canonical evidence intact. They cover source-authentication controls,
Linux enabled-preset channel admission, macOS timing/formatter boundaries,
public-menu input and reopening, and original Config/TOML/FileSystem round
trips. Use these portable campaign wrappers. Frozen worker helpers retain
historical invocation paths and may write their own evidence directories;
they are not the recommended future replay entry points.

The initial source register contains 132 role claims across 107 distinct paths.
With the Linux admission, logger, UI and real-codec/persistence supplements,
the combined source union is **135 distinct authenticated paths**. The five
findings, 90 initial heterogeneous coverage summaries and 20 capability rows
remain unchanged. Overlapping receipts and repeated execution are not new
features or native scenarios. Original runner versions remain available where
a later CLI-only adaptation follows an earlier receipt.

The OSM-002 supplements execute the original public menu, setter, Config, TOML
codec and FileSystem on actual private Linux files in both enabled states.
Infinity and finite 1e20 persist/reload, but reopening the editor raises at its
original integer formatter before a second dialog call. API 0.1 persists zero;
NaN remains a separately qualified acknowledged-save-port observation. Native
macOS metadata, dialogs, leases, generation/deployment and receiving remain
unmeasured. See the [root report](report.md) and
[real-persistence qualification](macos/real-config-domain/report.md).
A passing replay reproduces the recorded counterexamples and their controls;
it does not mean the defects are fixed or semantic parity is established.

Every coverage/finding needs observation basis and qualification, and every
capability has an independent availability and observation basis for each OS.
Observed defects must reference confirmed findings. An absent declaration is
not itself absence of the whole capability. Intent, constraints and unresolved
product policy remain distinct. Source-only Windows review is not AutoHotkey
execution; actual Lua owners over recorded ports are not native receiving.

`sample-owner.json` is a synthetic schema example, not audit evidence. The
control program creates its proof files only in temporary directories. It
accepts both a populated and an all-zero-finding owner and rejects 22 malformed
controls, including missing roles/evidence/qualification, wrong provenance,
unsafe paths, symlinks, invalid or unlinked claims, and stale projections.

This is a custom composite metadata and custody schema. It is **not** the legacy
AHK/HS report-validator envelope, semantic parity certification, automatic
discovery of undeclared features or evidence that a real application consumed
keyboard output. New findings and refutations require root review of the
original source and retained observations.
