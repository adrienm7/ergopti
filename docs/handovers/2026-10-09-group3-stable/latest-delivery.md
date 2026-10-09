<!-- docs/handovers/2026-10-09-group3-stable/latest-delivery.md -->

# Latest Group 3 partial delivery

The published SDK observation test `02ae39716b714f062a21e1b2a32ae2ea7c4c7e3f`
and original macOS editor source-issuer correction
`990c017f282338d600d37464ed3b5d279249790a` are integrated without squash in
`dev` at `2ebdb643ef8d8e1f9352eaca8c9490510a3c1fda`. Its parents are
`81f365c09976f8e38821f1d9216e422508ca9167` and
`f2336a7dfa9b6ee57a4fe5561ee21fbbbadc9b92`. Its tree
`0ccafe4cc617eae3052fcef8872ad83d3c0bcc18` matches the fully selected local
qualification. The preceding partial delivery remains an ancestor.

The SDK test exercises the production no-prompt permission observation worker;
it does not implement Shortcuts discovery or invocation. The editor correction
retains the original module/getter/request issuer and refuses its observed
replacement. It does not establish an unseen source epoch or finish editor
retargeting.

## Exact integrated qualification

Local `verify-change` passes formatting, all 404 JavaScript checks and 17,783
Hammerspoon assertions in 1,554 modules. Virtual E2E passes 101 scenarios; one
host scenario is skipped. This is controlled software qualification.

Manual macOS-only run
[37933681841](https://github.com/adrienm7/ergopti/actions/runs/37933681841)
tests exactly the integrated SHA and is terminal FAILURE:

- Core JavaScript, properties and macOS unit/E2E pass. Units report 17,783/0.
- All 12 native tooltip captures and cold MLX bootstrap pass.
- The distinct original native SDK cohort passes 41 cases on both architectures.
- The original 12 PAC/WPAD cases fail on both architectures. On arm64, five
  cases produce 19 assertion failures; the worker cohort passes seven and fails
  three, and both wire cases fail including trust/keychain cleanup refusal.
- The original 25-case archive cohort has one failing Homebrew case and two
  assertion failures: its normal owned Automation UI observation is refused.
  Sparkle passes 15/0, upgrade passes 8/0 and libpq passes 1/0.
- Packaging and installation are skipped. Windows and Linux lanes are skipped
  for this macOS-only change. Release is skipped and no release is published.

The new actual SDK observation case compiles but is not selected by the original
25 or 41 filters. Its native API execution is **unrun**. Neither those passing
cohorts nor compilation establish a permission grant, catalogue, invocation or
cause of the earlier JXA stall. Preserve every original admission and timeout.

The exact automatic Dev workflow `37933618835` was cancelled after push. The
owned empty lock `7d8e9d3d42e9c3ca989fe94b6d788477dd1bb45c` was removed only
once every manual job reached its final result. The official validation ref was
left at the integrated SHA; other groups' manual runs were preserved.

## Reviewed work awaiting adoption

[reviewed-source-recovery-v4.tar.gz](reviewed-source-recovery-v4.tar.gz) preserves
sealed patches, preimages, source reviews and failed/successful qualification
receipts. It is inactive source evidence, not a product input. SHA-256:

```text
adfb1c7f353f461873dca5d1d09a4c3887d4752b87622a3768eebc6b6e978939
```

Size: 9,846,192 bytes; 1,454 manifest entries. The outer manifest hash is
`d38678fe92f8a33c57fd4ca2bfef4a49105c04817f1797201b0ef54637511109`.
All outer entries and retained source seals were checked. Reviewer scratch
projections are excluded. Extract only into an owned temporary directory and
verify both outer and inner manifests before reconciling current Dev.

SDK enrollment requires ordered V10 and V11 patches. The final five-path
private tree `5d674e06e276ad13be43f302abeea4e36e3210c2` passes 355 formatting
checks and all 404 JS checks. The original failed attempt remains recorded:
`/tmp` contained a `.git` ancestor, causing the uninstall fixture to refuse,
and the drift fixture reported ENOSPC. Git clone returned 128 with write/checkout
errors; its errno was not exposed. The unchanged retry uses validated writable
`var/tmp`. Shared workflow/condition-owner custody and actual macOS execution
remain prerequisites. Adopt the two patches, not the private validation commit,
which also retains/restores the preceding private Linux proposal.

Linux public V1 alone is HOLD; V1 followed by V2 is source clear only. Its final
selected gates fail four JS controls and the original Manager reload refusal
(12,563 Linux passes, one failure). An additive successor is preparing the
causal loader fence, precise refusal-detail control, menu separator/reason,
two software-evidence records and Czech/Polish reason corrections. The old
assertions and failures remain intact. Reconcile G1's published menu source and
its approved narrow regions before adoption, and regenerate all outputs with
real owners. Actual kernel/device receiving remains unrun.

The nested native-join packet retains Caps Word and number-row prerequisites.
Read-only row descriptors and controlled model ACKs do not create native output
or physical capture authority. These are software-owner joins, not tasks that
can be handed to a device tester.

## Completion boundary

All thirteen Group 3 TODO items remain partial; zero are removed. Items 16 and
38 retain their validation requirements, and item 22 remains withdrawn. The
feature branch is retained while native gates and source-owner joins remain
open. The website is outside this delivery.

Use the original remaining-work table together with the latest TODO. Finish
software owners and exact-source CI first. Device acceptance is a last resort
for actual brightness, genuine AltGr/input hardware and two-display switching;
ordinary discovery, packaging, GUI capture and migration failures are still
software or automated qualification work.
