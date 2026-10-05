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
---    other-backend path can reach a download. install_ollama() is the install
---    button of the unreachable-backend error, through select_ollama().
--- 2. Clear decline: refusing the download opens the website and posts a
---    notification that says what stays in place (the AI off, or the current
---    backend during a switch) and how to install later.
--- 3. Stat-only detection: availability comes from filesystem probes, so the
---    menu can ask while it is being built without spawning a process.
--- 4. A failure offers its repair: an MLX selection that fails, or a Mac that
---    cannot run MLX, opens the repair offer (mlx_repair_offer), which names
---    the cause and carries the button that fixes it, or offers Ollama.
--- 5. The boot notice of a missing runtime is clickable: the click opens the
---    Ollama download offer, or the MLX offer's install button, instead of
---    naming the menu row that installs it.
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
local function mlx_repair_offer() return require("ui.menu.menu_llm.mlx_repair_offer") end
local function backend_detector() return require("modules.llm.backend_detector") end
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
---   switching from another backend, which a decline leaves running;
---   { install_consented = true } when the user already pressed an install
---   button, which is not asked again.
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
	if type(opts) == "table" and opts.install_consented == true then
		Logger.info(LOG, "Ollama download already chosen by the user; not asking again.")
	else
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
	end
	return ollama_deps().install_for_selection(on_complete) == true
end

--- Installs Ollama without asking again: the user pressed the install button
--- of the error that says Ollama does not answer (unreachable_backend_offer).
--- An installed Ollama is reused, as by select_ollama().
--- @param on_complete function|nil Receives the terminal result.
--- @return boolean accepted
function M.install_ollama(on_complete)
	return M.select_ollama(on_complete, { install_consented = true })
end

--- Opens the repair offer for a failed MLX selection, outside the caller's
--- stack: the terminal result arrives from a task callback.
--- @param cause table|nil Cause of the failure, the checker's when nil.
local function offer_mlx_repair(cause)
	local ok, offered = pcall(function() return mlx_repair_offer().offer(cause) end)
	if not ok or offered ~= true then
		Logger.error(LOG, "The MLX repair offer could not be scheduled: %s.", tostring(offered))
	end
end

--- Refuses MLX on a Mac that cannot run it, before anything is downloaded.
--- @return boolean supported
local function mlx_supported_here()
	local ok, supported, platform = pcall(function() return backend_detector().mlx_support() end)
	if not ok then
		-- An unreadable probe proves nothing: the installation names its own failure
		Logger.error(LOG, "The MLX platform probe failed: %s.", tostring(supported))
		return true
	end
	if supported ~= false then return true end
	platform = type(platform) == "table" and platform or {}
	Logger.warn(LOG, "MLX cannot run on this Mac (arch=%s, macOS major=%s); offering the other backends.",
		tostring(platform.arch), tostring(platform.macos_major))
	local Diagnosis = require("modules.llm.mlx_bootstrap_diagnosis")
	offer_mlx_repair({
		kind = "unsupported",
		machine = Diagnosis.describe_machine(platform.arch, platform.macos_major),
		repairable = false,
	})
	return false
end

--- Selects the MLX backend's runtime: reuses it, or provisions it once. A
--- runtime flagged broken, or opts.repair, is removed and rebuilt. A failure,
--- and a Mac that cannot run MLX, open the repair offer: the next selection,
--- or its button, always tries again.
--- @param on_complete function|nil Receives the terminal result.
--- @param opts table|nil { repair = true } for the repair button;
---   { failure_revision = integer } retains the failed intent through the selection router.
--- @return boolean accepted
function M.select_mlx(on_complete, opts)
	if not mlx_supported_here() then
		if type(on_complete) == "function" then
			Logger.callback(LOG, "MLX unsupported selection callback", on_complete, false)
		end
		return false
	end
	local function settle(ok)
		if ok ~= true then offer_mlx_repair(mlx_deps().get_failure_cause()) end
		if type(on_complete) == "function" then return on_complete(ok) end
		return ok
	end
	local install_opts = nil
	if type(opts) == "table" then
		if opts.repair == true then install_opts = { repair = true } end
		if opts.failure_revision ~= nil then
			install_opts = install_opts or {}
			install_opts.failure_revision = opts.failure_revision
		end
	end
	return mlx_deps().install_for_selection(settle, install_opts) == true
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
--- Never downloads anything by itself: a click on the notice opens the offer
--- that installs it, the Ollama download offer or the MLX install button, as
--- selecting the backend does.
--- @param backend string Backend identifier restored from preferences.
--- @return boolean missing True when a notice was posted.
function M.notify_if_missing(backend)
	if M.is_installed(backend) then return false end
	Logger.warn(LOG, "The %s runtime is not installed; its notice offers the install.",
		tostring(backend))
	local ollama = backend == "ollama"
	local ok, sent, detail = pcall(notifications().notify,
		i18n.get(ollama and "ollama.runtime_missing_title" or "mlx.runtime_missing_title"),
		i18n.get(ollama and "ollama.runtime_missing_click" or "mlx.runtime_missing_click"),
		"warning", function()
			if M.is_installed(backend) then
				Logger.info(LOG, "The %s runtime was installed since its notice; nothing to offer.",
					tostring(backend))
				return
			end
			-- The Ollama offer asks before it downloads, and a decline is not a
			-- failure; the MLX offer carries the install button.
			local called, err = pcall(function()
				if ollama then return M.select_ollama() end
				return mlx_repair_offer().offer({ kind = "missing", repairable = true })
			end)
			if not called then
				Logger.error(LOG, "The %s install offer raised: %s.", tostring(backend), tostring(err))
			end
		end)
	if not ok or sent ~= true then
		Logger.error(LOG, "The missing %s runtime notice was not posted: %s.",
			tostring(backend), tostring(ok and detail or sent))
		return false
	end
	return true
end

return M
