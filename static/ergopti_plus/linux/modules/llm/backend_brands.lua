--- modules/llm/backend_brands.lua

--- ==============================================================================
--- MODULE: AI Backend Brands (Linux)
--- DESCRIPTION:
--- Reads _shared/modules/llm/backends.json, the file the macOS and Windows
--- drivers and the model selector page read, for the brand and emoji of every
--- AI backend: the tray's model button reads "<emoji> <model>".
---
--- WHY THIS EXISTS:
--- Each driver had its own literal "Ollama 🦙"; one file keeps the three trays
--- and the page on the same emoji (tools/test/test-llm-backend-brands-single-source.cjs).
--- ==============================================================================

local M = {}

local Json = require("json")
local Paths = require("infra.paths")

local _brands = nil

--- The parsed brand table. A missing or malformed file fails loudly.
--- @return table brands backend id -> { brand, emoji, kind }
local function brands()
	if _brands then return _brands end
	local path = Paths.shared("modules/llm/backends.json")
	local fh = path and io.open(path, "r")
	local root = fh and Json.decode(fh:read("*a")) or nil
	if fh then fh:close() end
	if type(root) ~= "table" or type(root.backends) ~= "table" then
		error("backends.json is missing or malformed: " .. tostring(path), 0)
	end
	for id, entry in pairs(root.backends) do
		if type(entry) ~= "table" or type(entry.brand) ~= "string" or type(entry.emoji) ~= "string" then
			error("backends.json: backend " .. tostring(id) .. " has no brand or emoji", 0)
		end
	end
	_brands = root.backends
	return _brands
end

--- One backend's entry.
--- @param backend string
--- @return table
local function entry(backend)
	local found = brands()[backend]
	if not found then error("backends.json names no backend " .. tostring(backend), 0) end
	return found
end

--- The emoji of a backend: "🦙", "🚀" or "🌐".
--- @param backend string
--- @return string
function M.emoji(backend) return entry(backend).emoji end

--- The brand and emoji, as the Backend choice names it: "Ollama 🦙".
--- @param backend string
--- @return string
function M.label(backend)
	local found = entry(backend)
	return found.brand .. " " .. found.emoji
end

--- The kind of a backend: "local" or "remote".
--- @param backend string
--- @return string
function M.kind(backend) return entry(backend).kind end

--- The tray's model button: "🦙 qwen3:4b", "🌐 OpenAI/gpt-4o-mini".
--- @param backend string
--- @param model_text string
--- @return string
function M.selector_caption(backend, model_text)
	if type(model_text) ~= "string" or model_text == "" then
		error("backend_brands.selector_caption: model text must be a non-empty string", 0)
	end
	return M.emoji(backend) .. " " .. model_text
end

--- Test seam: forgets the parsed file.
function M._reset() _brands = nil end

return M
