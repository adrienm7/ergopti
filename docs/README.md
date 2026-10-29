<!-- docs/README.md -->

# What is in docs/

The only checklist is [`TODO.md`](../TODO.md) at the repository root: open work,
maintainer checks and open questions all live there. Nothing in this folder is
a task list.

- [`ERGOPTI_PLUS.md`](ERGOPTI_PLUS.md): how the project works and how to change
  it, with step-by-step runbooks (in French).
- [`TESTING.md`](TESTING.md): how to run every test suite locally exactly as CI
  does, and how to read a red CI check.
- [`glossary.md`](glossary.md): the technical terms of the code; a test checks
  it against the code.
- [`memory/`](memory/README.md): short lessons that stop the same bug coming
  back, read by agents and developers before touching an area.
- [`design/`](design/): how a feature works or is planned (layout composer,
  developer mode, shortcuts model, Windows input hooks and state transitions).
- [`tooling/`](tooling/): maintainer how-tos (RTK, update signing, Windows live
  checks and diagnostics, SignPath application, antivirus false positives).
- [`audits/`](audits/): the three 28 October audit handovers, whose evidence
  archives are the only copy, and two data files that a test or a tool reads.

Older handovers, prompts and reports were removed on 29 October; they stay in
Git history at commit `49c62d77a1`.
