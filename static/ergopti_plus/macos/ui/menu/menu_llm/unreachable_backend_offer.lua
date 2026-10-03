--- ui/menu/menu_llm/unreachable_backend_offer.lua

--- ==============================================================================
--- MODULE: Unreachable Backend Offer
--- DESCRIPTION:
--- Tells the user that the local Ollama backend does not answer, names the
--- address where nothing answers, and offers the buttons that fix it: one per
--- local OpenAI-compatible server that answers (use it instead), start Ollama
--- when it is installed, install Ollama and its model when it is not. The AI
--- stays off until one is chosen.
---
--- FEATURES & RATIONALE:
--- 1. A button, never a guess: the check used to end in "requirements check
---    failed" or "Network request failed", which named neither the backend nor
---    what to do. Each fix here is one button; the menu owns what it does.
--- 2. Fresh servers: the local servers are swept when the error is shown
---    (modules/llm/local_servers.lua), so a server started a moment ago is
---    offered and a stopped one is not.
--- 3. Confirmed, never silent: the Ollama backend is the user's choice, or on an
---    Intel Mac the platform default (the neutral backend (W1) is MLX on Apple
---    silicon only). It is never replaced behind the user's back; a server that
---    answers is only the first button.
--- 4. Never while typing: a failure found in the background (startup, a start
---    that timed out) posts one notification whose click opens the dialog, as
---    modules/llm/local_model_offer.lua does.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local i18n   = require("infra.i18n")

local LOG = "menu_llm.unreachable_offer"

-- The one backend this error covers: the local runtime the AI menu installs
-- and starts, whose address the user never typed
local BACKEND = "ollama"
local BACKEND_LABEL = "Ollama"

-- The collaborators are resolved at call time: the dialogs and the sweep are
-- stateful singletons, and tests replace them
local function dialogs() return require("infra.dialog_util") end
local function notifications() return require("infra.notifications") end
local function runtime_offer() return require("ui.menu.menu_llm.runtime_install_offer") end
local function servers() return require("modules.llm.local_servers") end
local function endpoint() return require("modules.llm.ollama_endpoint") end
local function remote() return require("modules.llm").api_remote end

-- The dialog is modal: a second failure while it is open, or while its
-- servers are swept, asks nothing more
local _asking = false

-- The notification of a background failure is posted once until clicked
local _notified = false




-- =====================================
-- =====================================
-- ======= 1/ Internal Helpers =========
-- =====================================
-- =====================================

--- Validates an offer request before any side effect.
--- @param request table { backend, automatic, actions = { use_server, start, install } }.
local function validate(request)
	if type(request) ~= "table" or request.backend ~= BACKEND then
		error("unreachable_backend_offer.offer: only the Ollama backend is covered", 3)
	end
	local actions = request.actions
	if type(actions) ~= "table" or type(actions.use_server) ~= "function"
		or type(actions.start) ~= "function" or type(actions.install) ~= "function" then
		error("unreachable_backend_offer.offer: use_server, start and install actions are required", 3)
	end
end

--- The host and port of a base URL, for a button.
--- @param base_url string
--- @return string
local function host_of(base_url)
	return tostring(base_url):match("^%a[%w+.-]*://([^/]+)") or tostring(base_url)
end

--- The servers of the last sweep that answer with at least one model.
--- @return table servers Array of { id, label, host, model }.
local function answering_servers()
	local Servers = servers()
	local found = {}
	for _, id in ipairs(Servers.detected()) do
		local verdict = Servers.result(id)
		if verdict and verdict.status == Servers.STATUS_UP and #verdict.models > 0 then
			found[#found + 1] = {
				id = id,
				label = Servers.SERVERS[id].label,
				host = host_of(verdict.base_url),
				-- The server's first model; the engine menu lists the others
				model = verdict.models[1],
			}
		end
	end
	return found
end

--- Runs the fix the user chose, logging a refusal instead of raising.
--- @param label string The button, for the log.
--- @param fix function
local function run_fix(label, fix)
	Logger.info(LOG, "Fix chosen: %s.", label)
	local ok, result = pcall(fix)
	if not ok then
		Logger.error(LOG, "The fix '%s' raised: %s.", label, tostring(result))
	elseif result ~= true then
		Logger.warn(LOG, "The fix '%s' was refused.", label)
	end
end

--- Shows the error with its buttons, after the servers were swept.
--- @param request table A validated request.
--- @return string|nil label The chosen button, nil when the AI stays off.
--- @return function|nil fix What the chosen button does.
local function ask(request)
	local url = endpoint().get_base_url()
	local installed = runtime_offer().is_installed(BACKEND) == true
	local found = answering_servers()
	local choices, fixes = {}, {}
	for _, server in ipairs(found) do
		choices[#choices + 1] = i18n.format("llm.unreachable.use_server", server.label, server.model, server.host)
		fixes[#fixes + 1] = function() return request.actions.use_server(server.id, server.model) end
	end
	if installed then
		choices[#choices + 1] = i18n.format("llm.unreachable.start", BACKEND_LABEL)
		fixes[#fixes + 1] = request.actions.start
	else
		choices[#choices + 1] = i18n.format("llm.unreachable.install", BACKEND_LABEL)
		fixes[#fixes + 1] = request.actions.install
	end

	local lines = {
		i18n.format(request.unconfirmed == true and "llm.unreachable.body_unconfirmed"
			or (installed and "llm.unreachable.body_stopped" or "llm.unreachable.body_missing"),
			BACKEND_LABEL, url),
	}
	local names = {}
	if #found > 0 then
		for _, server in ipairs(found) do names[#names + 1] = server.label end
		lines[#lines + 1] = i18n.format("llm.unreachable.servers_found", table.concat(names, ", "))
	else
		for _, id in ipairs(servers().ORDER) do names[#names + 1] = servers().SERVERS[id].label end
		lines[#lines + 1] = i18n.format("llm.unreachable.no_server", table.concat(names, ", "))
	end
	Logger.warn(LOG, "%s does not answer at %s (%s); offering %d fix(es).", BACKEND_LABEL, url,
		installed and "installed" or "not installed", #choices)

	local index = dialogs().choose(i18n.format("llm.unreachable.title", BACKEND_LABEL),
		table.concat(lines, "\n\n"), choices, i18n.get("llm.unreachable.keep_off"),
		i18n.get("llm.unreachable.apply"))
	if index == nil then return nil, nil end
	return choices[index], fixes[index]
end

--- Asks, then runs the chosen fix once the dialog no longer counts as open:
--- a fix that fails at once may offer again.
--- @param request table A validated request.
local function present(request)
	local ok, label, fix = xpcall(ask, debug.traceback, request)
	_asking = false
	if not ok then
		Logger.error(LOG, "The unreachable-backend dialog failed: %s.", tostring(label))
		return
	end
	if fix == nil then
		Logger.info(LOG, "The AI stays off: the user kept it off.")
		return
	end
	run_fix(label, fix)
end




-- =====================================
-- =====================================
-- ======= 2/ Public API ===============
-- =====================================
-- =====================================

--- Tells the user that the backend does not answer and offers its fixes.
--- @param request table {
---   backend = "ollama",
---   automatic = boolean|nil  -- true for a failure found in the background:
---                            -- a notification whose click opens the dialog,
---   unconfirmed = boolean|nil, -- use receipt-neutral wording before enable admission,
---   actions = {
---     use_server = function(id, model) -> boolean,  -- switch to a local server
---     start = function() -> boolean,                -- enable the AI, which starts Ollama
---     install = function() -> boolean,              -- install Ollama, then its model
---   },
--- }
--- @return boolean offered
function M.offer(request)
	validate(request)
	if request.automatic == true then
		if _notified then
			Logger.debug(LOG, "%s still does not answer; its notification is already posted.", BACKEND_LABEL)
			return false
		end
		_notified = true
		local url = endpoint().get_base_url()
		Logger.warn(LOG, "%s does not answer at %s; notifying the user.", BACKEND_LABEL, url)
		local interactive = { backend = request.backend, actions = request.actions, unconfirmed = request.unconfirmed }
		local ok, sent = pcall(notifications().notify, i18n.format("llm.unreachable.title", BACKEND_LABEL),
			i18n.format("llm.unreachable.click", BACKEND_LABEL, url), "warning", function()
				_notified = false
				M.offer(interactive)
			end)
		if not ok or sent ~= true then
			Logger.error(LOG, "The unreachable-backend notification was not posted: %s.", tostring(sent))
			_notified = false
			return false
		end
		return true
	end
	if _asking then
		Logger.info(LOG, "%s does not answer; its dialog is already open.", BACKEND_LABEL)
		return false
	end
	_asking = true
	-- A newer sweep carries this one's callback, so the dialog always opens
	local ok, started = pcall(remote().detect_local_servers, function() present(request) end)
	if not ok or started ~= true then
		Logger.error(LOG, "The local servers could not be swept (%s); offering the last sweep's servers.",
			tostring(started))
		present(request)
	end
	return true
end

--- Forgets the open dialog and the posted notification, for tests.
function M.reset()
	_asking, _notified = false, false
end

return M
