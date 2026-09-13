-- tools/diagnostics/hs274-context.lua
-- Native observation owner for the physical-input fixture, not production coverage admission.
local Context = require("modules.keylogger.physical_context")
local Privacy = require("modules.keylogger.privacy_context")
local Timestamp = require("modules.keylogger.timestamp")
local Lifecycle = require("adapters.process_lifecycle")
local Secure = require("adapters.secure_field_detector")
local PrivateWindow = require("keylogger.private_window")
local M = {}

function M.new(capacity, observations, on_error)
	local history = Context.new(capacity, Timestamp.format_epoch)
	local owner = { history = history }
	local active, generation, started, reading = false, 0, false, false
	local observer, observed_window
	function owner.inspect(view)
		local snapshot = { active = active, generation = generation, observations = #observations }
		local ok, err = xpcall(function()
			local fixture = view:hswindow()
			local focused = hs.window.focusedWindow()
			snapshot.accessibility = hs.accessibilityState()
			snapshot.fixture_id, snapshot.fixture_title = fixture:id(), fixture:title()
			snapshot.focused_id, snapshot.focused_title = focused:id(), focused:title()
			snapshot.observed_id, snapshot.observed_title = observed_window:id(), observed_window:title()
			local app = hs.axuielement.applicationElementForPID(focused:application():pid())
			local element = app:attributeValue("AXFocusedUIElement")
			snapshot.focused_role = element:attributeValue("AXRole")
			snapshot.focused_subrole = element:attributeValue("AXSubrole")
			snapshot.observer_running, snapshot.watchers = observer:isRunning(), {}
			for target, notifications in pairs(observer:watching()) do
				snapshot.watchers[#snapshot.watchers + 1] = {
					role = target:attributeValue("AXRole"), notifications = notifications,
				}
			end
		end, debug.traceback)
		if not ok then snapshot.error = err end
		return snapshot
	end
	local function detach()
		generation = generation + 1
		if observer then
			local stopped = observer:stop()
			assert(stopped ~= false and observer:isRunning() == false, "Native context observer did not stop")
			observer = nil
		end
	end
	function owner.stop()
		active = false
		history.stop()
		local detached, detail = pcall(detach)
		local lifecycle_stopped = Lifecycle.stop()
		assert(detached, detail)
		assert(lifecycle_stopped == true, "Native context lifecycle did not stop")
		observed_window = nil
	end
	local refresh
	local function guarded_refresh()
		if not active then return end
		local ok, detail = xpcall(function()
			assert(not reading, "Native context observation re-entered")
			reading = true
			refresh()
			reading = false
		end, debug.traceback)
		if not ok then
			active = false
			history.stop()
			on_error(detail)
		end
	end
	refresh = function()
		detach()
		local app = hs.application.frontmostApplication()
		local win = hs.window.focusedWindow()
		assert(app and win and win:application():pid() == app:pid(), "Native context has no stable foreground window")
		local app_name, bundle, path, pid = app:name(), app:bundleID(), app:path(), app:pid()
		assert(type(app_name) == "string" and app_name ~= "", "Native context has no application name")
		local secure, detail = Secure.inspectFocusedElement(pid)
		assert(type(secure) == "boolean", detail)
		local state = { private_filter_enabled = true, secure_field_filter_enabled = true,
			system_auth_filter_enabled = true, disabled_apps = {}, active_app_bundle = bundle, active_app_path = path,
			is_private_window = PrivateWindow.matches(win:title()),
			is_secure_field = secure or Secure.isSecureApp(app_name) }
		local epoch = Timestamp.now_epoch()
		local observed_ns = hs.timer.absoluteTime()
		assert(hs.application.frontmostApplication():pid() == pid and hs.window.focusedWindow():id() == win:id(),
			"Native context changed while being observed")
		local allowed = Privacy.allows_logging(state)
		assert(active, "Native context observation was revoked")
		history.observe(observed_ns, { allowed = allowed, app = app_name, epoch = epoch })
		observations[#observations + 1] = { observed_ns = tostring(observed_ns), allowed = allowed,
			app = allowed and app_name or nil, epoch = allowed and epoch or nil }
		local current = generation
		local failure, committed
		observer, failure, committed = Secure.watchFocusedElementChanges(pid, function()
			if current == generation then guarded_refresh() end
		end)
		assert(observer and committed ~= false, failure)
		assert(observer:addWatcher(hs.axuielement.windowElement(win), "AXTitleChanged") ~= false,
			"Native window-title observer refused setup")
		observed_window = win
	end
	function owner.start()
		assert(not started, "Native context owner already started")
		active, started = true, true
		Lifecycle.onAppActivate(guarded_refresh)
		Lifecycle.onFocusChange(guarded_refresh)
		assert(Lifecycle.start() == true, "Native context lifecycle refused startup")
		guarded_refresh()
		assert(active, "Native context observation failed during startup")
	end
	return owner
end

return M
