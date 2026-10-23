--- _shared/lua/llm/ollama_registry.lua

--- ==============================================================================
--- MODULE: Ollama Model Registry
--- DESCRIPTION:
--- Names the one registry the Ollama daemon pulls models from. It is hard-coded
--- upstream and never user input; the drivers resolve their system proxy for
--- this origin (a company PAC may answer differently per host) and hand the
--- daemon the resulting HTTPS_PROXY.
--- ==============================================================================

local M = {}

--- The registry origin, with no path, query or credentials.
M.URL = "https://registry.ollama.ai"

return M
