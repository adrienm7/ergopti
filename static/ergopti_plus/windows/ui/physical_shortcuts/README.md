# physical_shortcuts (Windows)

STATUS: unavailable; the native Windows host and physical input implementation
are pending validation on the maintainer's Windows PC.

This Convention S marker records the feature's canonical driver path. It does
not provide a runtime module, a bridge, a synthetic input adapter or a stub.
The canonical shortcut menu keeps the editor disabled on Windows with its
translated unavailable reason.

The form and policy live in `_shared/ui/physical_shortcuts/` and the shared
`shortcuts.physical_slots`, `shortcuts.physical_entries` and physical editor
modules. Native availability remains a separate decision: a structural
counterpart and shared assets do not prove native keyboard support.

Windows continuation requires a WebView2 host with exact window/bridge lifetime
ownership, authoritative configuration receipts and acknowledged joint edits.
Its physical input owner must qualify physical positions, modifiers, collision
checks and output retirement with the shared model. Stale callbacks, refused
cleanup and private parameter/source changes must refuse publication. Validate
these contracts on Windows before enabling the canonical menu entry; retain
all existing shortcut settings and legacy menus during that work.
