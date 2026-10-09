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

local M = {}

-- Brand, emoji and description key of every backend the Backend submenu offers
local OPTIONS = {
	mlx    = { brand = "MLX 🚀", description_key = "menu.llm.backend_mlx_suffix" },
	ollama = { brand = "Ollama 🦙", description_key = "menu.llm.backend_ollama_suffix" },
	api    = { brand = "API 🌐", description_key = "menu.llm.backend_api_suffix" },
}

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
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

return M
