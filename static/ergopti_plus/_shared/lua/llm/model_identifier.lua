--- _shared/lua/llm/model_identifier.lua

--- ==============================================================================
--- MODULE: Model Identifier Validation
--- DESCRIPTION:
--- What the model selector page accepts when the user adds a model: an Ollama
--- name ("qwen3:4b", "hf.co/owner/repo:Q4_K_M") or a Hugging Face repository id
--- for MLX ("mlx-community/Qwen3-4B-4bit"). The identifier reaches a download
--- command line, so anything else is refused before any process starts.
---
--- FEATURES & RATIONALE:
--- 1. One rule per backend, three implementations pinned to one corpus:
---    this module (macOS, Linux), the page script and windows/modules/llm/models.ahk
---    all validate _shared/tests/corpus/llm/model_identifiers.json.
--- 2. Pure: no I/O, so the drivers' unit suites call it directly.
--- ==============================================================================

local M = {}

-- Longest identifier accepted; real names are far shorter.
M.MAX_LENGTH = 200

--- Whether one path segment is well formed.
--- @param segment string
--- @param lower_only boolean First Ollama segment: lowercase letters only.
--- @return boolean
local function segment_ok(segment, lower_only)
	if segment == "" then return false end
	local first = segment:sub(1, 1)
	if lower_only then
		if not first:match("^[a-z0-9]$") then return false end
		return segment:match("^[a-z0-9._%-]+$") ~= nil
	end
	if not first:match("^[A-Za-z0-9]$") then return false end
	return segment:match("^[A-Za-z0-9._%-]+$") ~= nil
end

--- Splits a string on one separator character, keeping empty fields.
local function split(text, separator)
	local parts, start = {}, 1
	while true do
		local at = text:find(separator, start, true)
		if not at then parts[#parts + 1] = text:sub(start); return parts end
		parts[#parts + 1] = text:sub(start, at - 1)
		start = at + 1
	end
end

--- Validates an Ollama model name: up to three path segments and one tag.
--- @param name any
--- @return boolean
function M.valid_ollama(name)
	if type(name) ~= "string" or name == "" or #name > M.MAX_LENGTH then return false end
	local fields = split(name, ":")
	if #fields > 2 then return false end
	local path, tag = fields[1], fields[2]
	if tag ~= nil and not segment_ok(tag, false) then return false end
	local segments = split(path, "/")
	if #segments > 3 then return false end
	for index, segment in ipairs(segments) do
		if not segment_ok(segment, index == 1) then return false end
	end
	return true
end

--- Validates a Hugging Face repository id for MLX: exactly owner/name.
--- @param repo any
--- @return boolean
function M.valid_mlx(repo)
	if type(repo) ~= "string" or repo == "" or #repo > M.MAX_LENGTH then return false end
	local segments = split(repo, "/")
	if #segments ~= 2 then return false end
	return segment_ok(segments[1], false) and segment_ok(segments[2], false)
end

--- Validates an identifier for one local backend.
--- @param backend string "ollama" or "mlx".
--- @param identifier any
--- @return boolean
function M.valid(backend, identifier)
	if backend == "ollama" then return M.valid_ollama(identifier) end
	if backend == "mlx" then return M.valid_mlx(identifier) end
	return false
end

return M
