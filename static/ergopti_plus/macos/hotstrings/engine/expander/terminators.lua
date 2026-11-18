--- hotstrings/engine/expander/terminators.lua

--- ==============================================================================
--- MODULE: Keymap Terminators (Hammerspoon shim)
--- DESCRIPTION:
--- Hammerspoon-local re-export of the shared terminator catalogue. Delegates
--- all logic to _shared/layouts/engine/layers/terminators.lua. Built-in slots carry a
--- `label_key`, which the hotstrings menu resolves in the active language each
--- time it renders, so this shim does not rewrite any label.
--- ==============================================================================

return require("layouts.engine.layers.terminators")
