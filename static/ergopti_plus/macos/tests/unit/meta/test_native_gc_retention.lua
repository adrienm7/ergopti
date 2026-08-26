--- tests/unit/meta/test_native_gc_retention.lua

--- ==============================================================================
--- MODULE: Native Callback GC-Retention Regression
--- DESCRIPTION:
--- Drives representative production timer, chooser, and notification owners
--- against weak native registries. Hammerspoon finalizes an unreferenced native
--- object, so a callback that survives only in a function local silently dies.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

--- Removes Lua line and long-bracket comments before executable assertions.
--- @param source string
--- @return string code
local function strip_lua_comments(source)
	local code = source
	local cursor = 1
	while true do
		local open_at, open_end, equals = code:find("%-%-%[(=*)%[", cursor)
		if not open_at then break end
		local close_token = "]" .. equals .. "]"
		local _, close_end = code:find(close_token, open_end + 1, true)
		if not close_end then
			code = code:sub(1, open_at - 1)
			break
		end
		local block = code:sub(open_at, close_end)
		local newlines = block:gsub("[^\n]", "")
		code = code:sub(1, open_at - 1) .. newlines .. code:sub(close_end + 1)
		cursor = open_at + #newlines
	end
	return (code:gsub("%-%-[^\n]*", ""))
end

local function count_pattern(source, pattern)
	local count = 0
	for _ in source:gmatch(pattern) do count = count + 1 end
	return count
end

--- Converts a loadable module name to its driver-relative source location.
--- Keeping the inventory module-based lets repository moves fail at the Lua
--- module boundary instead of pinning an independent filesystem spelling.
--- @param module_name string
--- @return string relative_path
local function module_source(module_name)
	return module_name:gsub("%.", "/") .. ".lua"
end

--- Lists every UI Lua source recursively.
--- @return table paths
local function ui_sources()
	local ok_lfs, lfs = pcall(require, "lfs")
	local paths = {}
	if ok_lfs then
		local function walk(relative)
			for entry in lfs.dir(DRIVER_ROOT .. relative) do
				if entry ~= "." and entry ~= ".." then
					local path = relative .. entry
					local attr = lfs.attributes(DRIVER_ROOT .. path)
					if attr and attr.mode == "directory" then
						walk(path .. "/")
					elseif entry:match("%.lua$") then
						paths[#paths + 1] = path
					end
				end
			end
		end
		walk("ui/")
	else
		local separator = package.config:sub(1, 1)
		local ui_root = DRIVER_ROOT .. "ui/"
		local command = separator == "\\"
			and ('cmd /c dir /b /s /a-d "' .. ui_root:gsub("/", "\\") .. '*.lua"')
			or ("find '" .. ui_root .. "' -type f -name '*.lua'")
		local pipe = io.popen(command)
		helpers.assert_not_nil(pipe, "the UI source fallback walk must start")
		for line in pipe:lines() do
			local normalized = line:gsub("\\", "/"):gsub("%s+$", "")
			paths[#paths + 1] = normalized:gsub("^.*/macos/", "")
		end
		pipe:close()
	end
	table.sort(paths)
	return paths
end

--- Temporarily installs exact package.loaded entries.
--- @param stubs table<string, any> Module stubs.
--- @param callback function Fixture body.
local function with_package_stubs(stubs, callback)
	local saved = {}
	for name, value in pairs(stubs) do
		saved[name] = package.loaded[name]
		package.loaded[name] = value
	end
	local outcome = table.pack(xpcall(callback, debug.traceback))
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not outcome[1] then error(outcome[2], 0) end
end

--- Installs faithful one-shot timer primitives backed only by weak references.
--- @return table weak_timers
--- @return function restore
local function install_weak_timers()
	local previous = hs.timer
	local weak_timers = setmetatable({}, { __mode = "v" })
	local sequence = 0
	local timer_api = {}

	function timer_api.new(delay, callback)
		local timer = {
			delay = delay,
			callback = callback,
			running_state = false,
		}
		function timer:start()
			self.running_state = true
			sequence = sequence + 1
			self.id = sequence
			weak_timers[self.id] = self
			return self
		end
		function timer:stop()
			self.running_state = false
			return self
		end
		function timer:running() return self.running_state end
		function timer:fire()
			if self.running_state ~= true then return false end
			self.running_state = false
			self.callback()
			return true
		end
		return setmetatable(timer, {
			__gc = function(owner) owner.running_state = false end,
		})
	end

	function timer_api.doAfter(delay, callback)
		local timer = timer_api.new(delay, callback)
		timer:start()
		return timer
	end

	hs.timer = timer_api
	return weak_timers, function() hs.timer = previous end
end

local function collect_twice()
	collectgarbage("collect")
	collectgarbage("collect")
end

--- Runs fixture cleanup even when the behavioral assertion is deliberately red.
--- @param callback function
--- @param cleanup function
local function with_cleanup(callback, cleanup)
	local outcome = table.pack(xpcall(callback, debug.traceback))
	local cleaned, cleanup_err = xpcall(cleanup, debug.traceback)
	if not cleaned then error(cleanup_err, 0) end
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

helpers.describe("native callback owners survive Hammerspoon GC", function()
	helpers.it("allows raw UI timers only at exact strongly-owned lifecycle sites", function()
		local expected = {
			[module_source("ui.menu.init")] = {
				count = 1,
				patterns = { "_menu_refresh_timer%s*=%s*hs%.timer%.doAfter" },
			},
			[module_source("ui.menu.menu_watchers")] = {
				count = 1,
				patterns = { "_debounce_timer%s*=%s*timer" },
			},
			[module_source("ui.tooltip.tooltip_hotstring")] = {
				count = 2,
				patterns = {
					"_idle_timer%s*=%s*timer_or_err",
					"_dequeue_timer%s*=%s*timer_or_err",
				},
			},
			[module_source("ui.tooltip.tooltip_llm")] = {
				count = 1,
				patterns = { "_idle_timer%s*=%s*timer_or_err" },
			},
		}
		local files = ui_sources()
		helpers.assert_true(#files >= 30,
			"the UI source walk must cover the class instead of an empty allowlist")
		local raw_sites = 0
		for _, relative in ipairs(files) do
			local handle = assert(io.open(DRIVER_ROOT .. relative, "rb"))
			local code = strip_lua_comments(handle:read("*a") or "")
			handle:close()
			local count = count_pattern(code, "hs%.timer%.doAfter")
			local contract = expected[relative]
			if contract then
				helpers.assert_eq(count, contract.count,
					relative .. " raw timer inventory changed; migrate fire-and-forget sites "
						.. "through infra.deferred_work")
				for _, pattern in ipairs(contract.patterns) do
					helpers.assert_true(code:find(pattern) ~= nil,
						relative .. " lost an exact strong owner for an allowed raw timer")
				end
			elseif count > 0 then
				error(relative .. " contains an unowned raw UI timer; use infra.deferred_work", 0)
			end
			raw_sites = raw_sites + count
		end
		helpers.assert_eq(raw_sites, 5,
			"the raw timer owner floor must change deliberately with the allowlist")
	end)

	helpers.it("requires every native chooser construction to publish and release a strong owner", function()
		local chooser_contracts = {
			[module_source("infra.app_picker")] = {
				"_active_chooser%s*=%s*chooser",
				"_active_chooser%s*==%s*chooser%s+then%s+_active_chooser%s*=%s*nil",
			},
			[module_source("ui.menu.menu_llm.models_selector")] = {
				"_model_browser_chooser%s*=%s*chooser",
				"_model_browser_chooser%s*==%s*chooser%s+then%s+_model_browser_chooser%s*=%s*nil",
			},
			[module_source("ui.metrics_apps.init")] = {
				"_chooser_owners%s*%[%s*owner_id%s*%]%s*=%s*chooser_or_err",
				"_chooser_owners%s*%[%s*owner_id%s*%]%s*=%s*nil",
			},
		}
		local paths = ui_sources()
		paths[#paths + 1] = module_source("infra.app_picker")
		local constructions = 0
		for _, relative in ipairs(paths) do
			local handle = assert(io.open(DRIVER_ROOT .. relative, "rb"))
			local code = strip_lua_comments(handle:read("*a") or "")
			handle:close()
			local count = count_pattern(code, "hs%.chooser%.new%s*%(")
			if count > 0 then
				local contract = chooser_contracts[relative]
				helpers.assert_not_nil(contract,
					relative .. " constructs a chooser outside the exact owner inventory")
				helpers.assert_eq(count, 1,
					relative .. " chooser inventory changed; prove every new owner separately")
				for _, pattern in ipairs(contract) do
					helpers.assert_true(code:find(pattern) ~= nil,
						relative .. " must both publish and release its exact chooser owner")
				end
			end
			constructions = constructions + count
		end
		helpers.assert_eq(constructions, 3,
			"the chooser construction floor must change deliberately with the owner inventory")
	end)

	helpers.it("retains a deferred personal-shortcuts launch until delivery", function()
		helpers.with_fresh_modules({
			"adapters.timer_scheduler",
			"infra.deferred_work",
			"infra.personal_shortcuts",
		}, function()
			local weak_timers, restore_timers = install_weak_timers()
			local previous_execute = hs.execute
			local launches = 0
			hs.execute = function()
				launches = launches + 1
				return "", true, "exit", 0
			end

			with_cleanup(function()
				with_package_stubs({
				["adapters.file_system"] = {
					read_with_status = function() return "source", "ok" end,
				},
				["infra.config_paths"] = {
					get = function() return "/tmp/personal_shortcuts.lua" end,
				},
				["infra.logger"] = helpers.make_logger_stub(),
				["infra.text_utils"] = {
					shell_quote = function(value) return value end,
				},
				}, function()
				local PersonalShortcuts = require("infra.personal_shortcuts")
				helpers.assert_true(PersonalShortcuts.open())
				collect_twice()
				helpers.assert_not_nil(weak_timers[1],
					"the deferred native timer must remain strongly owned after open() returns")
				helpers.assert_eq(launches, 0,
					"retention must not make the deferred callback run synchronously")
				helpers.assert_true(weak_timers[1]:fire())
				helpers.assert_eq(launches, 1)
				end)
			end, function()
				hs.execute = previous_execute
				restore_timers()
			end)
		end)
	end)

	helpers.it("retains the application chooser until its terminal callback", function()
		helpers.with_fresh_modules({ "infra.app_picker" }, function()
			local previous_chooser = hs.chooser
			local previous_absolute_time = hs.timer.absoluteTime
			local weak_choosers = setmetatable({}, { __mode = "v" })
			local sequence = 0
			hs.timer.absoluteTime = function() return 0 end
			hs.chooser = {
				new = function(callback)
					sequence = sequence + 1
					local chooser = { callback = callback, id = sequence }
					for _, method in ipairs({
						"placeholderText", "choices", "bgDark", "show", "delete",
					}) do
						chooser[method] = function(self) return self end
					end
					weak_choosers[sequence] = chooser
					return setmetatable(chooser, { __gc = function() end })
				end,
			}

			with_cleanup(function()
				with_package_stubs({
				["adapters.shell_runner"] = {},
				["infra.i18n"] = { get = function(key) return key end },
				["infra.logger"] = helpers.make_logger_stub(),
				["infra.text_utils"] = {
					escape_gsub_replacement = function(value) return value end,
				},
				}, function()
				local changed = 0
				local AppPicker = require("infra.app_picker")
				AppPicker.discover_apps = function(on_ready)
					on_ready({ { text = "Example", appPath = "/Applications/Example.app" } })
				end
				local menu = AppPicker.build_menu({}, function() changed = changed + 1 end)
				helpers.assert_type(menu[1] and menu[1].action, "function")
				menu[1].action()
				collect_twice()
				helpers.assert_not_nil(weak_choosers[1],
					"the chooser must outlive the discovery callback that created it")
				local completion = weak_choosers[1].callback
				completion({ text = "Example", appPath = "/Applications/Example.app" })
				helpers.assert_eq(changed, 1)
				completion = nil
				collect_twice()
				helpers.assert_eq(weak_choosers[1], nil,
					"the chooser owner must be released after its terminal callback")
				end)
			end, function()
				hs.chooser = previous_chooser
				hs.timer.absoluteTime = previous_absolute_time
			end)
		end)
	end)

	helpers.it("retains a clickable notification and releases it after activation", function()
		helpers.with_fresh_modules({
			"adapters.timer_scheduler",
			"infra.notifications",
		}, function()
			local weak_timers, restore_timers = install_weak_timers()
			local previous_notify = hs.notify
			local previous_focus = hs.focus
			local previous_get = hs.application.get
			local weak_notifications = setmetatable({}, { __mode = "v" })
			local sequence = 0
			hs.focus = function() return true end
			hs.application.get = function() return nil end
			hs.notify = {
				new = function(callback, options)
					sequence = sequence + 1
					local notification = {
						callback = callback,
						options = options,
					}
					function notification:send() return self end
					weak_notifications[sequence] = notification
					return setmetatable(notification, { __gc = function() end })
				end,
			}

			with_cleanup(function()
				with_package_stubs({
				["infra.logger"] = helpers.make_logger_stub(),
				}, function()
				local Notifications = require("infra.notifications")
				local dispatched, detail = Notifications.notify("Click me")
				helpers.assert_true(dispatched, tostring(detail))
				collect_twice()
				helpers.assert_not_nil(weak_notifications[1],
					"a clickable notification must retain its native callback owner")
				helpers.assert_not_nil(weak_timers[1],
					"notification retention must have a bounded cleanup owner")
				local activation = weak_notifications[1].callback
				activation()
				collect_twice()
				helpers.assert_eq(weak_notifications[1], nil,
					"activation must release the exact notification owner")
				end)
			end, function()
				hs.notify = previous_notify
				hs.focus = previous_focus
				hs.application.get = previous_get
				restore_timers()
			end)
		end)
	end)
end)
