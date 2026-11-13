--- ui/menu/compose_input_method_row.lua

--- ==============================================================================
--- MODULE: Compose Input Method Row (Linux)
--- DESCRIPTION:
--- One disabled row under Layout > « Custom layouts » saying how far GTK 3
--- applications compose the installed layouts' Compose sequences.
---
--- FEATURES & RATIONALE:
--- 1. GTK 3's built-in input method composes only the single-character rules
---    the installer inlines in ~/.XCompose; IBus composes them all. The user
---    installer (xkb_installation/user_layout_installer.py) decides whether to
---    enable IBus and records its state in the user XKB tree; this row reads
---    that word, so the detection has one owner.
--- 2. IBus enabled by Ergopti reaches GTK at the next login: until the
---    daemon's own environment names it, the row says so.
--- 3. No managed Compose block (no state file) draws no row; an unknown or
---    unreadable state is logged and draws none, never a guess.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "ui.menu.compose_input_method_row"

local LinuxDesktop = require("core.text.engine.identifiers").linux_desktop

-- Written by user_layout_installer.py (COMPOSE_STATE_NAME) in the user XKB tree.
M.STATE_FILE = LinuxDesktop.compose_state_file
-- The installer's override of the user XKB tree (ENV_USER_ROOT there).
M.ROOT_ENV = LinuxDesktop.xkb_user_root_env

-- Installer state -> label key (layout_package.IM_STATE_*).
local LABELS = {
	ibus_active = "menu.layout.compose_ibus",
	other_active = "menu.layout.compose_other_input_method",
	no_ibus = "menu.layout.compose_single_character",
}

--- The state file's path.
--- @param getenv function|nil os.getenv by default.
--- @return string
function M.state_path(getenv)
	getenv = getenv or os.getenv
	local root = getenv(M.ROOT_ENV)
	if root == nil or root == "" then root = require("infra.config_paths").config_home() .. "/xkb" end
	return root .. "/" .. M.STATE_FILE
end

--- The label key for one installer state.
--- @param state string
--- @param gtk_im_module string|nil The daemon's GTK_IM_MODULE.
--- @return string|nil key Nil for a state this row does not know.
function M.label_key(state, gtk_im_module)
	if state == "ibus_enabled" then
		return gtk_im_module == "ibus" and "menu.layout.compose_ibus" or "menu.layout.compose_ibus_next_login"
	end
	return LABELS[state]
end

--- Builds the row.
--- @param ctx table { t, read_file?, getenv? }: read_file(path) -> text|nil.
--- @return table rows Zero or one disabled row.
function M.rows(ctx)
	local getenv = ctx.getenv or os.getenv
	local path = M.state_path(getenv)
	local read_file = ctx.read_file or function(file_path)
		local handle = io.open(file_path, "rb")
		if handle == nil then return nil end
		local text = handle:read("*a")
		handle:close()
		return text
	end
	local text = read_file(path)
	if text == nil then return {} end
	local state = text:match("^(%S+)%s*$")
	local key = state and M.label_key(state, getenv("GTK_IM_MODULE"))
	if key == nil then
		Logger.error(LOG, "Unknown Compose input method state in %s: %q.", path, text)
		return {}
	end
	return { { label = ctx.t(key), disabled = true } }
end

return M
