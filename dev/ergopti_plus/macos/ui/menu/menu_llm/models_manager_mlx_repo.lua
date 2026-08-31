--- ui/menu/menu_llm/models_manager_mlx_repo.lua

--- =============================================================================
--- MODULE: MLX Repository Identifier
--- DESCRIPTION:
--- Owns the trust-boundary grammar for HuggingFace repository identifiers used
--- by catalogue lookup, detached session replay, and download script creation.
--- =============================================================================

local M = {}

local REPOSITORY_PATTERN = "^[%w%._%-]+/[%w%._%-]+$"

--- Reports whether a value is one canonical HuggingFace `owner/model` identifier.
--- @param repository any Candidate value from a catalogue, UI, or session file.
--- @return boolean valid True only for the exact repository grammar.
function M.is_valid(repository)
	return type(repository) == "string"
		and repository:match(REPOSITORY_PATTERN) ~= nil
end

return M
