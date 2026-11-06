# macOS audit: 100 distinct defects goal

This ledger starts with the explicit request for at least 100 bugs. Earlier fixes are included only after their individual evidence is reviewed. A shared root cause counts once even when it affects several actions or platforms. Passing focused tests does not establish native macOS validation or a complete CI pass.

Confirmed and regression-tested: **103 verified / 100**, plus one excluded historical candidate under revalidation.

| ID  | Reproduced failure                                                                                        | Fix commit | Focused regression module                                          |
| --- | --------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------ |
| 001 | Failed mouse-button reads permit a gesture during a drag.                                                 | c25bc11    | test_click_drag_is_not_a_gesture                                   |
| 002 | An out-of-range GitHub reset header raises during quota error formatting.                                 | 0aac947    | test_update_check_session_vectors                                  |
| 003 | Invalid or regressing clipboard generations can report a stale image as a successful capture.             | 0ad272b    | test_screen_capture_adapter; test_interactive_screenshot_clipboard |
| 004 | Refused prompt-editor callback registration opens an unusable window.                                     | 78dabea    | test_prompt_editor_native_boundaries                               |
| 005 | An unformattable process callback error prevents subsequent settlement observers.                         | ca6e2ab    | test_shell_runner_start_rollback_ownership                         |
| 006 | Reentrant pause during pixel-action temporary-file acquisition loses cleanup ownership.                   | 5600a72    | test_system_pixel_pause_ownership                                  |
| 007 | A future reload sentinel remains fresh indefinitely and can suppress shutdown cleanup.                    | 9e274e1    | test_reload_guard                                                  |
| 008 | A refused Sparkle failure dialog suppresses the fallback notification.                                    | 0c8979d    | test_update_launcher                                               |
| 009 | Refused navigation-layer import or compensation loses its cleanup receipt and admits another hold change. | 20ce683    | test_nav_layer_hold_cleanup; test_nav_layer_rule                   |
| 010 | A valid TOML header with an adjacent comment is missed, producing duplicate sections.                     | 017eb94    | test_toml_record_editor                                            |
| 011 | A failed fallback update notification escapes the boolean refusal contract.                               | b6f4545    | test_update_launcher                                               |
| 012 | Clock rollback keeps stale window/privacy classification fresh.                                           | 555b7df    | test_ignored_window_cache_lifecycle                                |
| 013 | Failed or malformed model catalogue production escapes the browser update boundary.                       | 0786460    | test_javascript_completion_owner                                   |

The listed modules were rerun after integration: 6 + 50 + 15 + 18 + 19 + 33 + 35 + 10 + 9 = 195 passing cases, plus 2 cleanup and 31 navigation-rule cases for defect 009. Native Hammerspoon, Swift and Windows execution remain outstanding. Two independent findings of defect 001 were deduplicated. Defect 006 affects two actions but is counted once.

Follow-up verification: 15 screenshot ownership cases for defect 006 (5e16f70); 34 process rollback cases for the native error variant of defect 005 (43a8732). These variants do not increase the distinct count. The modules for 010–013 passed with 7, 10, 15 and 10 cases respectively.

Historical evidence review lists 86 historical defects (IDs 014–098 and 100), including one under revalidation, with commits, scenarios and focused results in [the historical inventory](macos-2026-11-04-history.json). Runtime entries additionally reproduce the failure by loading the pre-fix module into the current focused tests. Other entries have reviewed regression scenarios and passing current modules; their original pre-fix runs were not repeated in this inventory pass. Menu reason improvements and overlapping causes were excluded.

Installation history groups nested discovery-cache invalidations, malformed version suffixes and version numeric precision variants. An additional protected diagnostic-clock variant (53c4359) passes 35 ShellRunner tests; it is not counted separately from historical invalid-clock handling.

A second history review adds IDs 080–094. Repeated Apple Shortcut deadline and switcher findings were excluded; CSS color parsing/rendering variants count once. Runtime and UI extras include explicit failing pre-fix overlays. Configuration and action extras record current passing modules and reviewed historical scenarios.

ID 095 records the unsafe privileged launcher substitution boundary. Automatic system-scope keyboard installation is disabled before authorization as containment; user-scope installation remains available. Its focused regression proves refusal, not native privileged execution.

IDs 096–098 cover conservative power-source pacing, caret invalidation on bridge shutdown, and duplicate gesture-probe settlement observers. Each has an explicit failing pre-fix overlay and passing current module. ID 099 is the new damaged release-cache defect (50c71a5): a truncated cached list retained its ETag and could be repeatedly reused on HTTP 304; the 40-case auto-check module passes after JSON/tag validation. Cross-driver cache handling is still under examination.

ID 100 covers clipped or miscentered menu badges (4d8944e); its geometry assertion fails with pre-fix production code and the 52-case current module passes. Historical d609b63 is temporarily excluded from the verified total: its previous regression assertions could be swallowed inside a protected callback. A replacement observable regression is required. Quoted TOML assignment-key support (0230b7d, 9 passing tests) is grouped with ID 010 instead of increasing the count.

The damaged-cache fix also covers Linux and Windows (16eba64). Five focused Linux persistence cases pass; the Windows regression is added but has not run natively. Protected rollback assertions are now observed externally (4cc65c6); its pre-fix overlay fails because the older contract lacks the new rollback capability, so historical d609b63 remains outside the verified total pending an end-to-end baseline.

ID 101 is a newly reproduced malformed notification receipt (6ea6ff1): a native constructor returning a boolean or an object with a failing send-property access escaped the refusal boundary. Access is protected before owner publication; the 13-case notification module passes. This brings the verified total to 100 while continuing to exclude d609b63. IDs are stable and are not renumbered to hide the exclusion. The new TOML neighbor-preservation test (9070271) adds coverage only and no bug count.

ID 102 is the newly reproduced hotstring deadline extension after a backward wall-clock correction (eadd7bd with 6d69e87). Input suppression, previews and tooltip expiration share nondecreasing elapsed time. Observable sleep and significant forward wall-clock jumps expire short deadlines; invalid wall samples preserve awake-time progress. Integrated focused results: clock 1, state 15, actual key callback 28 and tooltip ownership 13 cases all pass. The paired sleep correction avoids introducing a migration regression and does not add another bug count. Native macOS sleep/wake acceptance remains outstanding.

ID 103: a duplicate manual-update API callback overtakes the active Atom fallback (2142e2f). The first callback now owns the transition; the integrated auto-check module passes 41 cases. ID 104: a ready model-browser view reports successful catalogue/progress updates when JavaScript delivery refuses or is unavailable (6817a5f). Delivery receipts are propagated and undeliverable scripts are not queued; the integrated lifecycle module passes 12 cases. Both new regressions were reproduced before their fixes.
