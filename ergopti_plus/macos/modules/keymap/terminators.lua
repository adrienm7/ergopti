--- modules/keymap/terminators.lua

--- ==============================================================================
--- MODULE: Keymap Terminators (Hammerspoon shim)
--- DESCRIPTION:
--- Hammerspoon-local re-export of the shared terminator catalogue. Delegates
--- all logic to _shared/lua/keymap/terminators.lua. Built-in slots carry a
--- `label_key`, which the hotstrings menu resolves in the active language each
--- time it renders, so this shim does not rewrite any label.
--- ==============================================================================

return require("keymap.terminators")
