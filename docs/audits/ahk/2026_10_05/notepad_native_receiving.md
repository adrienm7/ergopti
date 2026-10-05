<!-- docs/audits/ahk/2026_10_05/notepad_native_receiving.md -->

# Modern Notepad native receiving evidence

On 2026-10-05, six finite owned Notepad cases exercised the actual native editor
DLL through the canonical HSE literal and LLM acceptance callers. Every case
matched an independent complete-document literal and collapsed full DWORD caret.
The sender exited naturally with status 0 and empty stderr before the exact owned
Notepad child and package launcher were retired. No clipboard or keyboard
transport was used.

| Case                    | Receiving oracle                                                                  |
| ----------------------- | --------------------------------------------------------------------------------- |
| LLM insertion           | `déjà célèbre`, caret 12                                                          |
| Reported LLM correction | `Napoleon is the greatest emperor in French history`, caret 50; deletion count 16 |
| Supplementary suffix    | `Avant. Je suis déjà allé.`, caret 25; two code points consume three UTF-16 units |
| HSE literal             | `ct★ → c’était`, caret 7                                                          |
| HSE case conformity     | `CT★ → C’ÉTAIT`, caret 7                                                          |
| Consumed delimiter      | `ct` followed by a consumed space becomes `c’était`, caret 7                      |

The measured DLL SHA-256 was
`fd5cc433e6344155c6015e660fb2f10d4eb7139aa3cfe00a56de1f6f5d387676`.
AutoHotkey's SHA-256 was
`a2a54b8abc476d7671d4de0771bb54bf5f2373d79ff6871d0ba6a62c3b88ae00`.
The receiver was Microsoft.WindowsNotepad 11.2607.14.0, `RichEditD2DPT`.
All 268 direct source/include references were identical before and after the run.
The full original receipt and output are retained under
[`notepad_receiving_v8/`](notepad_receiving_v8/).

This is receiving and canonical caller evidence with synthetic documents,
controlled scheduling and controlled presentation admission. It does not prove
physical InputHook triggering, driver startup, performance percentiles, every
application, or persisted journal rows. The broad private include graph emitted
48 LocalSameAsGlobal warnings; they remain in the output and are not described as
clean parsing. Earlier setup/oracle failures were corrected without changing the
six receiving expectations. No keyboard/paste fallback was admitted by this proof.

The reproducible manual entry is
[`tools/diagnostics/notepad-callers.ps1`](../../../../tools/diagnostics/notepad-callers.ps1).
The tracked entry subsequently ran all six cases successfully on the same
receiver and DLL, with natural sender exit 0, empty stderr, unchanged source/DLL
hashes, and acknowledged retirement of both owned Notepad processes. Its receipt
SHA-256 is `753f7817c604685e555e98904baa7e2b53e6e3e5cfc7a1408fdbaace5097cdd1`. The output retains the same 48 warnings.
