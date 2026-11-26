--- tests/unit/ai/engine/vectors/test_ollama_uninstall_vectors.lua

--- ==============================================================================
--- MODULE: Managed Ollama Uninstall Sequence
--- DESCRIPTION:
--- Replays the uninstall vectors through the shared sequence this driver and
--- Linux run; Windows replays the same vectors through its port.
--- ==============================================================================

local helpers = require("tests.helpers")

require("tests.lua.ai.ollama_uninstall_contract").register(helpers, helpers.shared)
