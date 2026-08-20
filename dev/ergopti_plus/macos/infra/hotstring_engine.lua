--- infra/hotstring_engine.lua

--- ==============================================================================
--- MODULE: Hotstring Engine (Hammerspoon re-export)
--- DESCRIPTION:
--- Hammerspoon-local re-export of the shared hotstring matcher core. Delegates
--- entirely to _shared/lua/hotstring_engine and adds no HS-specific extensions.
---
--- WHY macOS TAKES ONLY PART OF IT:
--- the core also carries a whole engine instance — its own rolling buffer, its
--- own dispatch between the auto and terminator paths. macOS cannot take those:
--- its buffer belongs to the keymap core state and is read by the keylogger, the
--- LLM preview, the tooltip and script control. What it takes is `M.decide`, the
--- pure firing decision, which needs no buffer at all — only the tail that was
--- typed and the codepoint in front of it. That is the whole reason the decision
--- was separated from the traversal: the traversal is representation-specific and
--- the decision is not.
--- ==============================================================================

return require("hotstring_engine")
