# macOS audit: 100 distinct defects goal

This ledger starts with the explicit request for at least 100 bugs. Earlier fixes are excluded until their individual evidence is reviewed. A shared root cause counts once even when it affects several actions or platforms. Passing focused tests does not establish native macOS validation or a complete CI pass.

Confirmed and regression-tested: **9 / 100**.

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

The listed modules were rerun after integration: 6 + 50 + 15 + 18 + 19 + 33 + 35 + 10 + 9 = 195 passing cases, plus 2 cleanup and 31 navigation-rule cases for defect 009. Native Hammerspoon, Swift and Windows execution remain outstanding. Two independent findings of defect 001 were deduplicated. Defect 006 affects two actions but is counted once.
