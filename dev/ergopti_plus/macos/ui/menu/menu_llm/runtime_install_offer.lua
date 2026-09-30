--- ui/menu/menu_llm/runtime_install_offer.lua

--- ==============================================================================
--- MODULE: AI Runtime Selection
--- DESCRIPTION:
--- Owns what happens when the user selects a local AI backend whose runtime
--- may be absent. Ollama is reused when the resolver finds it; otherwise the
--- user is asked, never silently, whether to download the official release or
--- open the Ollama website. MLX is provisioned by its own selection.
---
--- FEATURES & RATIONALE:
--- 1. One entry per backend: select_ollama() and select_mlx() are the only
---    callers of the checkers' install_for_selection(), so no boot, update or
---    other-backend path can reach a download.
--- 2. Clear decline: refusing the download opens the website and posts a
---    notification that says what stays in place (the AI off, or the current
---    backend during a switch) and how to install later.
--- 3. Stat-only detection: availability comes from filesystem probes, so the
---    menu can ask while it is being built without spawning a process.
--- ==============================================================================

local M = {}

local hs = hs

local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local OllamaBinary  = require("modules.llm.ollama_binary")

local LOG = "menu_llm.runtime_offer"

-- The runtime owners and the dialog/notification surfaces are resolved at
-- call time: they are stateful singletons, and this stateless router must
-- always talk to the instance that currently owns each runtime.
local function ollama_deps() return require("modules.llm.ollama_deps_checker") end
local function mlx_deps() return require("modules.llm.mlx_deps_checker") end
local function dialogs() return require("infra.dialog_util") end
local function notifications() return require("infra.notifications") end





-- ===================================
-- ===================================
-- ======= 1/ Runtime Presence =======
-- ===================================
-- ===================================

--- Reports whether the runtime of a local backend is installed.
--- @param backend string "ollama", "mlx" or any other backend identifier.
--- @return boolean installed True for backends without a local runtime.
function M.is_installed(backend)
	if backend == "ollama" then return ollama_deps().runtime_available() end
	if backend == "mlx" then return (mlx_deps().runtime_installed()) == true end
	return true
end





-- =========================================
-- =========================================
-- ======= 2/ Selection Entry Points =======
-- =========================================
-- =========================================

--- Asks whether to download Ollama. Modal, from a menu action only.
--- @return string choice "download" or "declined".
local function ask_ollama_download()
	local download_label = i18n.get("ollama.offer_download")
	local website_label = i18n.get("ollama.offer_website")
	local ok, choice = pcall(dialogs().block_alert,
		i18n.get("ollama.runtime_missing_title"), i18n.get("ollama.offer_body"),
		download_label, website_label, "informational")
	if not ok then
		Logger.error(LOG, "The Ollama download offer could not be shown: %s", tostring(choice))
		return "declined"
	end
	if choice == download_label then return "download" end
	if choice == website_label then
		local opened, open_err = pcall(hs.urlevent.openURL, OllamaBinary.DOWNLOAD_PAGE_URL)
		if not opened then
			Logger.error(LOG, "The Ollama website could not be opened: %s", tostring(open_err))
		end
	end
	return "declined"
end

--- Selects the Ollama backend's runtime: reuses an installed Ollama, or offers
--- the download once. A decline changes nothing and says what stays in place.
--- @param on_complete function|nil Receives the terminal result when accepted.
--- @param opts table|nil { keeps_current_backend = true } when the user is
---   switching from another backend, which a decline leaves running.
--- @return boolean accepted False when the user declined or the check refused.
function M.select_ollama(on_complete, opts)
	if ollama_deps().runtime_available() then
		Logger.info(LOG, "Ollama already installed; reusing it without a download.")
		return ollama_deps().check_and_install_deps(on_complete) == true
	end
	if ollama_deps().is_task_running() then
		-- The download accepted moments ago is still running: join it rather
		-- than asking a second time.
		Logger.debug(LOG, "Ollama provisioning already running; joining it.")
		return ollama_deps().check_and_install_deps(on_complete) == true
	end
	Logger.start(LOG, "Offering the Ollama download…")
	if ask_ollama_download() ~= "download" then
		-- Declining a switch leaves the previous backend running, so "the AI
		-- stays off" would be false there; it is true when enabling the AI.
		local keeps_backend = type(opts) == "table" and opts.keeps_current_backend == true
		Logger.warn(LOG, keeps_backend
			and "Ollama download declined; the current backend stays active."
			or "Ollama download declined; the AI stays off with this backend.")
		pcall(notifications().notify, i18n.get("ollama.runtime_missing_title"),
			i18n.get(keeps_backend and "ollama.switch_declined_body" or "ollama.runtime_missing_body"),
			"warning")
		Logger.success(LOG, "Ollama download offer settled (declined).")
		return false
	end
	Logger.success(LOG, "Ollama download offer settled (accepted).")
	return ollama_deps().install_for_selection(on_complete) == true
end

--- Selects the MLX backend's runtime: reuses it, or provisions it once.
--- @param on_complete function|nil Receives the terminal result.
--- @return boolean accepted
function M.select_mlx(on_complete)
	return mlx_deps().install_for_selection(on_complete) == true
end

--- Dispatches a backend selection to its runtime owner.
--- @param backend string Backend identifier.
--- @param on_complete function|nil Receives the terminal result.
--- @return boolean accepted
function M.select(backend, on_complete)
	if backend == "ollama" then return M.select_ollama(on_complete) end
	if backend == "mlx" then return M.select_mlx(on_complete) end
	if type(on_complete) == "function" then on_complete(true) end
	return true
end

--- Tells the user, once per boot, that the configured backend has no runtime.
--- Never downloads anything; the menu selection remains the only install path.
--- @param backend string Backend identifier restored from preferences.
--- @return boolean missing True when a notice was posted.
function M.notify_if_missing(backend)
	if M.is_installed(backend) then return false end
	local prefix = backend == "ollama" and "ollama" or "mlx"
	Logger.warn(LOG, "The %s runtime is not installed; the AI waits for a backend selection.",
		tostring(backend))
	pcall(notifications().notify, i18n.get(prefix .. ".runtime_missing_title"),
		i18n.get(prefix .. ".runtime_missing_body"), "warning")
	return true
end

return M
