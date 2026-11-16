--- ai/ui/menu/models/manager_mlx_repo.lua

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
	if type(repository) ~= "string" or not repository:match(REPOSITORY_PATTERN) then return false end
	local owner, name = repository:match("^([^/]+)/([^/]+)$")
	if owner == "." or owner == ".." or name == "." or name == ".." then return false end
	if #name > 96 or name:match("^[%.%-]") or name:match("[%.%-]$")
		or name:find("..", 1, true) or name:find("--", 1, true) then return false end
	return true
end

return M
