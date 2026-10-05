# Focused verification results

Executed in the exclusive focused slot granted by root. Slot explicitly closed after completion; no command remains active. All commands used the project RTK launcher and scratch `qualification/` overlay. No main working tree mutation, full JavaScript suite or native suite ran.

| Check                                                                       | Result                                | Scope                                                                                                                                                            |
| --------------------------------------------------------------------------- | ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Repository AHK encoding gate                                                | Passed, exit 0                        | 1820 AHK files in scratch overlay, BOM/LF plus unchanged staged-fixer controls                                                                                   |
| Repository static AHK v2 antipattern guard                                  | Passed, exit 0                        | 1807 Windows source files in scratch overlay; not a compiler                                                                                                     |
| Actual verify-change gate selection and include registration                | Passed, exit 0 after setup correction | 29 authored controls present; actual new unit reachable; removing its include only in scratch makes the registration gate reject it; exact runner bytes restored |
| Existing independent shared receipt corpus                                  | Passed, 57/0, exit 0                  | Unchanged 53 manually authored vectors plus four boundary controls, optional shared presentation metadata added                                                  |
| Actual AHK compiler coverage wrapper                                        | Skipped, exit 0 with explicit SKIP    | Ahk2Exe is Windows-only                                                                                                                                          |
| New AHK caller controls                                                     | Not executed                          | 29 authored controls, including eight render deadline controls                                                                                                   |
| Native Windows updater/WebView/settings/log actions, packaging/installation | Not executed                          | Windows runner required                                                                                                                                          |
| Full JS/native suite and packet strict conventions/format gates             | Not executed                          | Final root composition owns these gates                                                                                                                          |

The initial registration command failed with MODULE_NOT_FOUND for `../lint/format.cjs`, because its unchanged dependency was not copied into the isolated scratch overlay. Copying the repository `tools/lint/` dependency resolved that setup issue; rerun passed. No source or assertion was weakened.

Exact command arguments (run from `<repository>` after sourcing `<saved-environment-helper>`):

```text
TMPDIR=packets/failure-callers-wip/validation/tmp tools/rtk/rtk.sh node packets/failure-callers-wip/qualification/tools/test/test-ahk-encoding.cjs
tools/rtk/rtk.sh node packets/failure-callers-wip/qualification/tools/test/test-ahk-v2-syntax-antipatterns.cjs
tools/rtk/rtk.sh node packets/failure-callers-wip/validation/plan-registration.cjs
tools/rtk/rtk.sh node packets/failure-callers-wip/qualification/tools/test/test-ahk-parse-coverage.cjs
tools/rtk/rtk.sh luajit dependencies/shared-contract/tools/test/prove_failure_contract.lua packets/failure-callers-wip/qualification <repository>
```

verify-change selected format, ahk-encoding, ahk-suite, ahk-parse, ahk-e2e and js. Gate selection and reachability do not claim those unexecuted suites pass. Original frozen pre-timeout source files remain in causal-preimages; actual AHK baseline/candidate causal replay is unavailable here.

## Final source-only revision after user deferral

The user subsequently deferred Windows-dependent work to their Windows PC. Nine bounded reviewer controls brought the final authored inventory to 38. No further gate, compiler, runtime, native or full suite ran after those source changes. The passed 1820-file encoding, 1807-file antipattern and 29-control reachability results above belong to the preserved reviewed-timeout packet, not the final source revision. The shared presentation JSON and Lua classifier bytes did not change, so the recorded 57/0 pure policy result retains that limited scope. See REVIEW-FINDINGS.md and WINDOWS-PC-RESUMPTION.md.
