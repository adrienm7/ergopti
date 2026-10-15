# macOS conditional editor delivery after live retargeting

The conditional owner checked its effective source before calling its parent.
The parent then entered `Logger.callback` and executed the action without
rejoining that decision. A source, trigger, replacement, pause or parent change
inside that callback could dispatch the old shortcut.

The owner now passes a callable retaining its exact decision, handle, issuer,
generation, action and context. The parent checks it inside the real logger
callback immediately before executor entry, then rejoins its lifecycle again.
Stable input executes exactly once. None/personal priority, projection,
registration/retirement and publication compensation remain unchanged. Existing
internal callers retain their optional argument contract; production conditional
delivery always supplies the original owner's callable.

The four existing paths are `modules/shortcuts/magic_editor.lua`,
`modules/shortcuts/keyboard_shortcuts.lua` and their enrolled
`tests/unit/modules/shortcuts/test_magic_editor_source_owner.lua` and
`test_magic_editor_keyboard_transaction.lua`, all under the macOS driver.
Original assertions and registrations remain intact; eight owner cases and
three parent cases are additive.

## Focused receiving

Genuine Lua 5.4 helpers and shared policy receive five isolated software cohorts
with explicit private preloads and separate temporary folders:

| Source / tests        | Passed | Failed | Exit |
| --------------------- | -----: | -----: | ---: |
| Original / original   |     49 |      0 |    0 |
| Original / expanded   |     49 |     11 |    1 |
| Candidate / expanded  |     60 |      0 |    0 |
| Withdrawal / expanded |     49 |     11 |    1 |
| Restored / expanded   |     60 |      0 |    0 |

The parent independently reviews the code and original-case preservation before
adoption. A separate focused check then loads the real canonical files without
preloads, from the ordinary Mac driver working directory. The first attempt
used the repository working directory and failed fixture acquisition of
`tests/stubs/hs.lua`; its failure remains retained, with no assertion changed.

These are portable software controls with recorded Hammerspoon ports. Native
TIS/GUI, physical delivery, package/install and the next composed broad gates
remain open. Existing unseen source ABA, other-owner collisions and native
source/epoch acceptance are separate work. No physical availability is enabled,
and TODO 108 remains partial. The latest maintainer instruction batches broad
qualification at integration while atomic fixes receive focused causal checks.
