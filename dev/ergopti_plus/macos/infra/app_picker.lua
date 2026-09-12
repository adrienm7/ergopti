--- infra/app_picker.lua

--- ==============================================================================
--- MODULE: Application Picker
--- DESCRIPTION:
--- Provides shared logic for discovering installed applications and building
--- a standardized exclusion menu.
---
--- FEATURES & RATIONALE:
--- 1. App Discovery: Scans the system for installed applications.
--- 2. Menu Building: Creates a standardized exclusion list submenu.
--- ==============================================================================

local M = {}
local hs     = hs
local ShellRunner = require("adapters.shell_runner")
local FileSystem = require("adapters.file_system")
local DeferredWork = require("infra.deferred_work")
local Logger = require("infra.logger")
local i18n   = require("infra.i18n")
local text_utils = require("infra.text_utils")

local LOG = "app_picker"





-- ========================================
-- ========================================
-- ======= 1/ Application Discovery =======
-- ========================================
-- ========================================

--- Scans the system for installed applications.

-- Discovered-application cache. Declared above the function that reads it: a
-- local placed below would bind the nil global instead.
local _apps_cache    = nil
local _apps_cache_at = 0
local _apps_cache_home = nil
local _latest_discovery = nil

-- Forward declaration: discover_apps's completion callback calls build_choices,
-- which is defined below it. A local declared after the closure would bind the
-- nil global instead.
local build_choices

-- How long a discovery result stays warm. Long enough that reopening the picker
-- costs nothing, short enough that an app installed during the session shows up
-- without a reload.
local APPS_CACHE_TTL_SEC = 60

-- Absolute path: this process does not inherit the login shell's PATH.
local FIND_BIN = "/usr/bin/find"
local REQUIRED_APP_ROOTS = { "/Applications", "/System/Applications" }
local FIND_EXPRESSION = { "-maxdepth", "2", "-name", "*.app", "-not", "-name", ".*", "-print0" }

-- A chooser's Lua userdata owns its completion callback. Keep the exact native
-- object alive until dismissal; a function-local chooser can be finalized as
-- soon as the discovery continuation returns.
local _active_chooser = nil

-- A discovery can finish after a newer menu invocation. The chooser is a native
-- cleanup owner, while this token is the authority to publish its result.
-- Keeping them separate prevents an old subprocess from deleting a newer panel.
local _active_request = nil
local _next_request_id = 0
-- Deliberately strong: a failed native delete leaves a real cleanup debt. A
-- weak key would collect the only capability to retry that exact deletion.
local _chooser_cleanup_debt = {}
-- Weak terminal receipts prevent duplicate teardown without retaining dead owners
local _chooser_lifecycle = setmetatable({}, { __mode = "k" })

local function request_is_active(request)
	return _active_request == request and request.settled ~= true
end

local function retire_request(request)
	if _active_request == request then _active_request = nil end
	request.settled = true
end

-- A native willOpen callback can retain the old chooser and reenter before its
-- window takes focus. Never nest another presentation inside that native stack
local _presentation_running = false
local _pending_presentation = nil
local _presentation_handoff = nil
local run_presentation

local function refuse_handoff(token, reason)
	if _presentation_handoff ~= token then return end
	_presentation_handoff = nil
	local pending = _pending_presentation
	_pending_presentation = nil
	if pending and request_is_active(pending.request) then retire_request(pending.request) end
	Logger.error(LOG, "Application picker presentation handoff refused: %s.", reason)
end

local function defer_pending_presentation()
	if not _pending_presentation or _presentation_handoff then return end
	local token = { arming = true }
	_presentation_handoff = token
	local ok, committed = xpcall(function()
		return DeferredWork.after(0, function()
			if _presentation_handoff ~= token then return end
			if token.arming or _presentation_running then
				refuse_handoff(token, "callback arrived before presentation unwound")
				return
			end
			_presentation_handoff = nil
			local pending = _pending_presentation
			_pending_presentation = nil
			if pending and request_is_active(pending.request) then run_presentation(pending) end
		end, "app_picker.presentation")
	end, debug.traceback)
	token.arming = false
	if not ok or committed ~= true then
		refuse_handoff(token, "deferred timer did not commit")
	end
end

run_presentation = function(item)
	_presentation_running = true
	local ok, failure = xpcall(item.run, debug.traceback)
	_presentation_running = false
	-- One retained successor per runloop turn bounds arbitrarily chained reentry
	defer_pending_presentation()
	if not ok then error(failure, 0) end
end

local function present_when_ready(request, present)
	if not request_is_active(request) then return end
	local item = { request = request, run = present }
	if _presentation_running or _presentation_handoff then
		_pending_presentation = item
		Logger.debug(LOG, "Application picker request %d queued behind native presentation.", request.id)
		return
	end
	run_presentation(item)
end

local function delete_chooser(chooser, context)
	local phase = _chooser_lifecycle[chooser]
	if phase == "deleted" then return true end
	if phase == "deleting" then return false end
	_chooser_lifecycle[chooser] = "deleting"
	-- Reentrant native callbacks must never observe the retiring owner as active
	if _active_chooser == chooser then _active_chooser = nil end
	local ok, err = xpcall(function() return chooser:delete() end, debug.traceback)
	if ok then
		_chooser_lifecycle[chooser] = "deleted"
		_chooser_cleanup_debt[chooser] = nil
		Logger.debug(LOG, "Application chooser cleanup completed for %s.", context)
		return true
	end
	-- Do not discard the exact native owner after a refused deletion: it is the
	-- only capability that can be retried without accidentally touching a successor.
	_chooser_cleanup_debt[chooser] = true
	_chooser_lifecycle[chooser] = "pending"
	Logger.error(LOG, "Application chooser cleanup failed for %s; exact owner retained: %s.",
		context, tostring(err))
	return false
end

--- Retires the previous chooser and retries a bounded snapshot of cleanup debt.
--- @return boolean settled
local function delete_active_chooser()
	local owner = _active_chooser
	if owner and not delete_chooser(owner, "active owner") then return false end
	-- Snapshot debt so reentrant additions cannot turn one request into an
	-- unbounded retry loop or make cleanup follow a newly published owner
	local pending = {}
	for candidate in pairs(_chooser_cleanup_debt) do pending[#pending + 1] = candidate end
	local settled = true
	for _, candidate in ipairs(pending) do
		if _chooser_lifecycle[candidate] ~= "deleting"
			and not delete_chooser(candidate, "retained owner") then settled = false end
	end
	return settled
end

--- Scans the system for installed applications, asynchronously.
---
--- The enumeration is a `find` across standard and user application trees. It used to run
--- through the SYNCHRONOUS shell primitive on the main runloop, reached via a
--- short timer as if that moved it off the thread. It does not: a timer callback
--- runs on the same single runloop, so the picker froze the driver — and the
--- keyboard tap with it — for the whole scan. It goes through the async spawner
--- now, which also pins the task against the GC.
---
--- @param on_ready function Called as on_ready(choices, true) on success or
---        on_ready(nil, false) on failure. Invoked
---        synchronously when the cache is warm, and from the subprocess callback
---        otherwise, so callers must not depend on the return value.
function M.discover_apps(on_ready)
	if type(on_ready) ~= "function" then
		Logger.error(LOG, "discover_apps() requires a callback — nothing discovered.")
		return
	end
	-- Even a refused root validation supersedes older pending cache publications
	local discovery = {}
	_latest_discovery = discovery
	local home = os.getenv("HOME")
	if type(home) ~= "string" or home:sub(1, 1) ~= "/" then
		Logger.error(LOG, "Application discovery requires an absolute HOME directory; discovery refused.")
		on_ready(nil, false)
		return
	end
	-- Warm results avoid another subprocess and per-application native hydration
	-- A different HOME must never inherit another root set's cached snapshot
	local now = os.time()
	if _apps_cache and _apps_cache_home == home and (now - _apps_cache_at) < APPS_CACHE_TTL_SEC then
		local choices = _apps_cache
		Logger.debug(LOG, "Serving %d application(s) from cache.", #choices)
		on_ready(choices, true)
		return
	end

	Logger.debug(LOG, "Discovering installed applications…")
	-- argv, not a shell string: the roots are separate arguments, so a space or
	-- a quote in HOME can no longer be re-interpreted. The `| sort` is dropped
	-- because the choices are sorted in Lua further down anyway.
	-- Follow symlinks supplied as roots only, never symlinks among descendants
	local args, included_roots = { "-H" }, {}
	for _, root in ipairs(REQUIRED_APP_ROOTS) do
		local status, detail = FileSystem.directory_status(root)
		if status ~= "present" then
			Logger.error(LOG, "Cannot validate required application directory '%s' (%s); discovery refused: %s.",
				root, tostring(status), tostring(detail))
			on_ready(nil, false)
			return
		end
		args[#args + 1] = root
		included_roots[root] = true
	end
	local user_apps = home:gsub("/+$", "") .. "/Applications"
	if not included_roots[user_apps] then
		local status, detail = FileSystem.directory_status(user_apps)
		if status == "present" then
			args[#args + 1] = user_apps
		elseif status == "absent" then
			Logger.debug(LOG, "Optional user Applications directory is absent; scanning system applications only.")
		else
			Logger.error(LOG, "Cannot classify optional user Applications directory; discovery refused: %s.",
				tostring(detail))
			on_ready(nil, false)
			return
		end
	end
	for _, token in ipairs(FIND_EXPRESSION) do args[#args + 1] = token end
	local handle = ShellRunner.spawn(FIND_BIN, args, function(exit_code, stdout)
		if exit_code ~= 0 then
			Logger.warn(LOG, "Application discovery failed (exit %s); result was not cached.", tostring(exit_code))
			on_ready(nil, false)
			return
		end
		if type(stdout) ~= "string" then
			Logger.warn(LOG, "Application discovery returned nothing (exit %s).",
				tostring(exit_code))
			-- A failure is NOT cached: the next open should retry rather than serve
			-- an empty picker for the whole TTL.
			on_ready(nil, false)
			return
		end
		-- A nonempty stream must end at a complete pathname boundary before use
		if stdout ~= "" and stdout:sub(-1) ~= "\0" then
			Logger.warn(LOG, "Application discovery returned incomplete path framing; result was not cached.")
			on_ready(nil, false)
			return
		end
		local choices = build_choices(stdout)
		if _latest_discovery == discovery then
			_apps_cache = choices
			_apps_cache_at = os.time()
			_apps_cache_home = home
		else
			Logger.debug(LOG, "Obsolete application discovery completed; shared cache was not replaced.")
		end
		on_ready(choices, true)
	end)
	if not handle.start() then
		Logger.error(LOG, "Could not start the application discovery subprocess.")
		on_ready(nil, false)
	end
end


--- Turns the NUL-separated `find` output into hs.chooser choices.
--- @param raw string Subprocess stdout.
--- @return table
build_choices = function(raw)
	
	local choices, seen = {}, {}
	for app_path in raw:gmatch("[^%z]+") do
		local name = app_path:match("([^/]+)%.app$")
		if name and not seen[app_path] then
			seen[app_path] = true
			local info = hs.application.infoForBundlePath(app_path)
			local bid  = type(info) == "table" and info.CFBundleIdentifier or nil
			local icon = nil
			
			if bid then
				local ok_img, img = pcall(hs.image.imageFromAppBundle, bid)
				if ok_img and img then
					pcall(function() img:setSize({w=18, h=18}) end)
					icon = img
				end
			end
			
			table.insert(choices, {
				text     = name, 
				subText  = app_path, 
				image    = icon,
				bundleID = bid, 
				appPath  = app_path,
			})
		end
	end
	
	table.sort(choices, function(a, b) return a.text:lower() < b.text:lower() end)
	Logger.info(LOG, "Application discovery completed (%d app(s)).", #choices)
	return choices
end





-- ================================
-- ================================
-- ======= 2/ Menu Building =======
-- ================================
-- ================================

--- Escapes a string so it is safe to use as the REPLACEMENT argument of gsub.
--- Lua treats "%" specially on that side: "%1".."%9" are capture references,
--- "%%" is a literal percent, and "%" followed by anything else RAISES
--- "invalid use of %". Application names are third-party-controlled (an app may
--- legitimately be called "100% Orange Juice"), so every interpolation of one
--- into a template must go through here or the whole menu build throws.
--- @param s any The replacement text (coerced with tostring).
--- @return string The text with every "%" doubled.
-- Single source of truth: lib.text_utils (shared with the other Lua drivers).
local escape_replacement = text_utils.escape_gsub_replacement

--- Builds a standardized exclusion list submenu.
--- @param current_apps table The current list of disabled apps.
--- @param on_change function Callback triggered when the list changes.
--- @param placeholder_text string Text to display in the chooser.
--- @return table The menu structure.
function M.build_menu(current_apps, on_change, placeholder_text)
	Logger.debug(LOG, "Building application exclusion menu…")
	local _build_t0 = hs.timer.absoluteTime()
	local apps = type(current_apps) == "table" and current_apps or {}
	-- Sort a shallow copy by display name so the list is always alphabetical
	local sorted_apps = {}
	for _, a in ipairs(apps) do table.insert(sorted_apps, a) end
	table.sort(sorted_apps, function(a, b)
		return (a.name or ""):lower() < (b.name or ""):lower()
	end)
	local menu = {}

	for _, app in ipairs(sorted_apps) do
		if type(app) == "table" then
			local icon = nil
			if app.bundleID then
				local ok, img = pcall(hs.image.imageFromAppBundle, app.bundleID)
				if ok and img then
					pcall(function() img:setSize({w=16, h=16}) end)
					icon = img
				end
			end

			-- Capture identity by path so removal is order-independent after sort
			local app_path   = app.appPath
			local app_bundle = app.bundleID
			local styled = hs.styledtext.new(
				(app.name or "?") .. "\t✗",
				{ paragraphStyle = { tabStops = {{location = 260, alignment = "right"}} } }
			)

			table.insert(menu, {
				label  = styled,
				image  = icon,
				action = function()
					local new_apps = {}
					for _, a in ipairs(apps) do
						local same = (app_path   and a.appPath   == app_path)
						          or (app_bundle and a.bundleID  == app_bundle)
						if not same then table.insert(new_apps, a) end
					end
					on_change(new_apps)
				end,
			})
		end
	end

	if #menu > 0 then table.insert(menu, {title = "-"}) end

	table.insert(menu, {
		label  = i18n.get("app_picker.add_another_app"),
		action = function()
			_next_request_id = _next_request_id + 1
			local request = { id = _next_request_id, settled = false }
			local superseded = _active_request
			_active_request = request
			if superseded then
				superseded.settled = true
				Logger.debug(LOG, "Application picker request %d superseded request %d.",
					request.id, superseded.id)
			else
				Logger.debug(LOG, "Application picker request %d started.", request.id)
			end
			-- The chooser is built inside the discovery callback. The 0.1 s timer this
			-- used to rely on moved the scan off the click's stack frame but not off
			-- the runloop, so the whole driver froze for the duration of the `find`.
			local function present_result(choices, success)
				if not request_is_active(request) then
					Logger.debug(LOG, "Ignoring stale application picker result for request %d.", request.id)
					return
				end
				if success ~= true then
					local previous_chooser = _active_chooser
					retire_request(request)
					if previous_chooser then delete_chooser(previous_chooser, "failed discovery predecessor") end
					Logger.debug(LOG, "Application picker request %d retired after discovery failure; no chooser presented.", request.id)
					return
				end
				if not delete_active_chooser() then return end
				if not request_is_active(request) then
					Logger.debug(LOG, "Application picker request %d was superseded during cleanup.", request.id)
					return
				end
				local chooser
				local created, chooser_or_err = xpcall(function()
					return hs.chooser.new(function(choice)
						if not request_is_active(request) or _active_chooser ~= chooser then
							Logger.debug(LOG, "Ignoring stale application picker callback for request %d.", request.id)
							return
						end
						-- Retire authority before the settings callback: it may synchronously
						-- rebuild a menu or otherwise re-enter this module.
						if _active_chooser == chooser then _active_chooser = nil end
						retire_request(request)
						local completed, completion_err = xpcall(function()
							if not choice then
								Logger.debug(LOG, "Application picker request %d cancelled.", request.id)
								return
							end

							local already_excluded = false
							for _, a in ipairs(apps) do
								if type(a) == "table" and a.appPath == choice.appPath then
									already_excluded = true
									break
								end
							end

							if not already_excluded then
								local new_apps = {}
								for _, a in ipairs(apps) do table.insert(new_apps, a) end
								table.insert(new_apps, {
									name = choice.text,
									appPath = choice.appPath,
									bundleID = choice.bundleID,
								})
								on_change(new_apps)
							else
								Logger.debug(LOG, "Application picker request %d selected an already excluded application.", request.id)
							end
						end, debug.traceback)
						-- The native callback registry roots this closure and its chooser
						-- Release that root even if applying settings raises. Apply first so
						-- reentrant teardown cannot reverse the order of selected changes
						delete_chooser(chooser, "completed request")
						if not completed then error(completion_err, 0) end
					end)
				end, debug.traceback)
				if not created or chooser_or_err == nil or chooser_or_err == false then
					Logger.error(LOG, "Application chooser construction failed: %s.",
						tostring(chooser_or_err))
					return
				end
				chooser = chooser_or_err
				if not request_is_active(request) then
					delete_chooser(chooser, "stale candidate")
					Logger.debug(LOG, "Discarded stale application picker candidate for request %d.", request.id)
					return
				end
				_active_chooser = chooser

				local configured, configure_err = xpcall(function()
					chooser:placeholderText(placeholder_text or i18n.get("app_picker.search_placeholder"))
					chooser:choices(choices)
					chooser:bgDark(false)
					return chooser:show()
				end, debug.traceback)
				if not request_is_active(request) or _active_chooser ~= chooser then
					delete_chooser(chooser, "superseded candidate")
					Logger.debug(LOG, "Application picker request %d was superseded during presentation.", request.id)
				elseif not configured or configure_err ~= chooser then
					Logger.error(LOG, "Application chooser presentation failed: %s.",
						tostring(configure_err))
					delete_active_chooser()
				end
			end
			M.discover_apps(function(choices, success)
				present_when_ready(request, function() present_result(choices, success) end)
			end)
		end,
	})

	-- Static entry to exclude the current frontmost application (always up-to-date if build_menu is called before each display)
	local frontApp = hs.application.frontmostApplication()
	if frontApp then
		local bundleID = type(frontApp.bundleID) == "function" and frontApp:bundleID() or nil
		local appPath  = type(frontApp.path) == "function" and frontApp:path() or nil
		local appName  = type(frontApp.name) == "function" and frontApp:name() or nil

		local already_excluded = false
		for _, a in ipairs(apps) do
			if type(a) == "table" and ((a.appPath and a.appPath == appPath) or (a.bundleID and a.bundleID == bundleID)) then
				already_excluded = true
				break
			end
		end

		if not already_excluded and appName and appName ~= "Hammerspoon" then
			local icon = nil
			if bundleID then
				local ok, img = pcall(hs.image.imageFromAppBundle, bundleID)
				if ok and img then
					pcall(function() img:setSize({w=16, h=16}) end)
					icon = img
				end
			end
			table.insert(menu, {
				label  = i18n.get("app_picker.exclude_current"):gsub("{app}", escape_replacement(appName)),
				image  = icon,
				action = function()
					local new_apps = {}
					for _, a in ipairs(apps) do table.insert(new_apps, a) end
					table.insert(new_apps, {
						name = appName, appPath = appPath, bundleID = bundleID,
					})
					on_change(new_apps)
				end,
			})
		end
	end

	-- Timing surfaced so the boot log shows the cost of each exclusion-menu build
	-- (built once per picker per menu tree rebuild — keylogger + LLM = two per tree).
	Logger.info(LOG, "Application exclusion menu built successfully (%d excluded app(s), %.1f ms).",
		#sorted_apps, (hs.timer.absoluteTime() - _build_t0) / 1e6)
	-- PROVIDER rows, not an hs.menubar tree. They used to be `title`/`fn`/`image`
	-- and every caller handed the result over as `submenu`, which meant the icons
	-- survived and the rows were never the renderer's. The renderer carries
	-- `image` since 2026-08-07, so there is nothing left that only a hand-built
	-- tree could do here.
	if #menu == 0 then
		table.insert(menu, { label = i18n.get("app_picker.no_app_excluded"), disabled = true })
	end
	return type(menu) == "table" and menu or {}
end

return M
