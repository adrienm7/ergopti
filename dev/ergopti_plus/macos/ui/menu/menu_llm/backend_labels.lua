--- ui/menu/menu_llm/backend_labels.lua

--- ==============================================================================
--- MODULE: AI Backend Labels
--- DESCRIPTION:
--- How the AI menu names a backend: the option of the Backend submenu,
--- « MLX 🚀 — Recommandé (natif Apple Silicon) », and everything before its em
--- dash where the selection is shown, « MLX 🚀 ».
---
--- FEATURES & RATIONALE:
--- 1. The Backend row read « Moteur IA (Backend) : » and a second copy of each
---    brand; the maintainer asked on 2026-09-30 for the selected option itself,
---    cut before its em dash, emoji included.
--- 2. The brand and its emoji are not translated; only the description after
---    the dash comes from the locale.
--- ==============================================================================

local TextUtils = require("text_utils")
local Paths     = require("infra.paths")
local JsonCodec = require("adapters.json_codec")
local M = {}

-- The brand and emoji come from the file the three drivers and the model page
-- share; only the description key after the em dash is this menu's own.
local BRANDS_PATH = "modules/llm/backends.json"
local DESCRIPTION_KEYS = {
	mlx    = "menu.llm.backend_mlx_suffix",
	ollama = "menu.llm.backend_ollama_suffix",
	api    = "menu.llm.backend_api_suffix",
}

--- Reads the shared brand table once; a missing or malformed file is a broken
--- install, so it raises instead of inventing a label.
--- @return table brands backend id -> { brand, emoji, kind }
local function load_brands()
	local path = Paths.shared(BRANDS_PATH)
	local handle = type(path) == "string" and io.open(path, "r") or nil
	if not handle then error("backend_labels: shared " .. BRANDS_PATH .. " is unreadable") end
	local raw = handle:read("*a")
	handle:close()
	local decoded, decode_err = JsonCodec.decode(raw)
	if decode_err ~= nil or type(decoded) ~= "table" or type(decoded.backends) ~= "table" then
		error("backend_labels: shared " .. BRANDS_PATH .. " is malformed: " .. tostring(decode_err))
	end
	for id, entry in pairs(decoded.backends) do
		if type(entry) ~= "table" or type(entry.brand) ~= "string" or type(entry.emoji) ~= "string" then
			error("backend_labels: backend " .. tostring(id) .. " has no brand or emoji")
		end
	end
	return decoded.backends
end

local BRANDS = load_brands()

-- Brand, emoji and description key of every backend the Backend submenu offers
local OPTIONS = {}
for id, key in pairs(DESCRIPTION_KEYS) do
	local entry = BRANDS[id]
	if not entry then error("backend_labels: shared brands lack backend " .. id) end
	OPTIONS[id] = { brand = entry.brand .. " " .. entry.emoji, description_key = key }
end

-- What sets an option's description apart from what it names
local EM_DASH = "—"





-- ================================
-- ================================
-- ======= 1/ Public API ==========
-- ================================
-- ================================

--- The brand and emoji of a backend: "MLX 🚀", "Ollama 🦙" or "API 🌐".
--- @param backend string Backend identifier.
--- @return string|nil label Nil for a backend the submenu does not offer.
function M.brand(backend)
	local option = OPTIONS[backend]
	return option and option.brand or nil
end

--- The brand alone, without its emoji: "MLX", "Ollama" or "API". The model
--- selector page writes the emoji itself, before the brand; handing it brand()
--- drew « 🦙 Ollama 🦙 ».
--- @param backend string Backend identifier.
--- @return string brand
function M.name(backend)
	local entry = BRANDS[backend]
	if not entry then error("backend_labels.name: unknown backend " .. tostring(backend)) end
	return entry.brand
end

--- The emoji of a backend: "🚀", "🦙" or "🌐".
--- @param backend string Backend identifier.
--- @return string|nil emoji Nil for a backend the shared table does not name.
function M.emoji(backend)
	local entry = BRANDS[backend]
	return entry and entry.emoji or nil
end

--- The tray's model button: the backend's emoji, then the model it runs, so the
--- selected backend reads at a glance ("🦙 qwen3:4b", "🌐 OpenAI/gpt-4o-mini").
--- @param backend string Backend identifier.
--- @param model_text string Model name, or the API entry's "<provider>/<model>".
--- @return string caption
function M.selector_caption(backend, model_text)
	local emoji = M.emoji(backend)
	if not emoji then error("backend_labels.selector_caption: unknown backend " .. tostring(backend)) end
	if type(model_text) ~= "string" or model_text == "" then
		error("backend_labels.selector_caption: model text must be a non-empty string")
	end
	return emoji .. " " .. model_text
end

--- The label of a backend's option in the Backend submenu.
--- @param backend string "mlx", "ollama" or "api".
--- @return string label
function M.option(backend)
	local option = OPTIONS[backend]
	if not option then error("backend_labels.option: unknown backend " .. tostring(backend)) end
	return option.brand .. " " .. EM_DASH .. " " .. require("infra.i18n").get(option.description_key)
end

--- What an option names: its label before the first em dash, trimmed, or the
--- whole label when it has none.
--- @param label string An option label.
--- @return string head
function M.head(label)
	local text = tostring(label)
	local dash = text:find(EM_DASH, 1, true)
	if dash then text = text:sub(1, dash - 1) end
	return TextUtils.trim(text)
end

return M
