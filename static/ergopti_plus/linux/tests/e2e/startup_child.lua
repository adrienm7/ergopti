--- tests/e2e/startup_child.lua

--- ==============================================================================
--- MODULE: One Daemon Start Of The Installed Driver
--- DESCRIPTION:
--- Runs the REAL ergopti_hotstrings.lua main() with every module loaded (the
--- tray included, rows recorded without GTK), from the folder the installer
--- publishes (tests/e2e/startup_scenarios.lua stages lib/ergopti/{linux,_shared}),
--- with only the operating-system edges replaced: the keyboard hook hands its
--- callbacks to nobody, uinput writes nowhere, the output layout is an identity
--- table and the event loop plays thirty virtual seconds on the whole-second
--- clock the daemon falls back to without luv.
---
--- Usage (from the installed driver folder):
---   luajit tests/e2e/startup_child.lua <device-file> <action> <driver-folder>
---     [<config.toml to seed>]
--- Actions: boot (start and idle), restore_recommended (start, then the menu's
--- « Restore recommended values », committed through the same composition the
--- row calls), delimiters_add (persist a custom delimiter through its owner),
--- and delimiters_verify (check its state after a cold start).
--- Output: the daemon's log lines, E2E_* observation lines and a
--- final E2E_DONE line.
--- ==============================================================================

local DEVICE, ACTION, DRIVER, SEED = arg[1], arg[2], arg[3], arg[4]
assert(DEVICE and ACTION and DRIVER, "usage: startup_child.lua <device> <action> <driver folder>")
arg = { "--device", DEVICE, "--tray" }
package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path

require("tests.win_compat").install()

--- Prints one observation line for the parent.
--- @param kind string
--- @param detail any
local function record(kind, detail)
	print("E2E_" .. kind .. " " .. (tostring(detail):gsub("[\r\n]+", " | ")))
end

-- The whole-second clock the daemon uses without luv, advanced only by the
-- soak below, so delayed start-up work (the updater's boot delay, the tray's
-- periodic refresh) runs within a bounded, deterministic time.
package.preload["luv"] = function() error("the start-up scenarios run the daemon without luv") end
local system_time = os.time
local clock_seconds = system_time()
os.time = function(date)
	if date ~= nil then return system_time(date) end
	return clock_seconds
end





-- =============================================
-- =============================================
-- ======= 1/ The installed-driver guard =======
-- =============================================
-- =============================================

-- The installed driver folder is the package: a write there is user data kept
-- in a folder every update replaces, and a read of a file the package does not
-- ship is user data looked up there (hardening-b-installed-layout). Only calls
-- made from the package's own Lua are judged.
-- The daemon runs from the installed driver folder, so a relative path is
-- inside the package, and so is an absolute one under lib/ergopti/.
local install_prefix = DRIVER:gsub("/+$", ""):gsub("/[^/]+$", "") .. "/"
local function inside(path)
	if type(path) ~= "string" or path == "" then return false end
	if path:sub(1, 1) ~= "/" then return true end
	return path:sub(1, #install_prefix) == install_prefix
end
local function production_caller()
	for level = 3, 7 do
		local info = debug.getinfo(level, "Sl")
		if not info then return nil end
		local source = (info.source or ""):gsub("^@", "")
		if source:find("tests/", 1, true) or source:find("=", 1, true) then return nil end
		if source ~= "" and source:sub(1, 1) ~= "[" then return source .. ":" .. tostring(info.currentline) end
	end
	return nil
end
local real_open = io.open
io.open = function(path, mode)
	if inside(path) then
		local caller = production_caller()
		if caller then
			if type(mode) == "string" and mode:find("[wa+]") then
				record("DRIVER_WRITE", caller .. " opens " .. path .. " (" .. mode .. ")")
			else
				local fh = real_open(path, "r")
				if fh then fh:close()
				elseif not path:find("build_stamp%.txt$") then
					record("DRIVER_READ_MISSING", caller .. " reads " .. path)
				end
			end
		end
	end
	return real_open(path, mode)
end

-- User-visible error dialogs: zenity/kdialog errors, and notifications raised
-- at the error level.
local function watch_command(command)
	if type(command) == "string" and (command:find("zenity%s+%-%-error") or command:find("kdialog%s+%-%-error")
		or command:find("kdialog%s+%-%-sorry")) then
		record("DIALOG", command:sub(1, 200))
	end
end
local real_execute, real_popen = os.execute, io.popen
os.execute = function(command, ...) watch_command(command); return real_execute(command, ...) end
io.popen = function(command, ...) watch_command(command); return real_popen(command, ...) end
package.preload["adapters.notifier"] = function()
	local notifier = dofile("adapters/notifier.lua")
	local send = notifier.send
	notifier.send = function(message, opts)
		if type(opts) == "table" and opts.level == "error" then record("DIALOG", "notification: " .. tostring(message)) end
		return send(message, opts)
	end
	return notifier
end





-- ================================
-- ================================
-- ======= 2/ OS edges ============
-- ================================
-- ================================

package.preload["adapters.keyboard_layout"] = function()
	return {
		refresh = function() return true end,
		is_ready = function() return true end,
		source = function() return "scripted" end,
		resolve = function() return { keycode = 30, level = 1, mods = {} } end,
		plan = function() return {} end,
		shortcut_keycode = function(_, us_code) return us_code end,
		_set_table_for_test = function() end,
	}
end
package.preload["adapters.uinput_writer"] = function()
	-- Capability/reservation lifecycle is real Writer logic; syscalls are controlled.
	return require("tests.fakes").uinput_writer()
end
package.preload["adapters.secure_field_detector"] = function()
	return {
		invalidateFocus = function() return 1 end,
		refresh = function() return true, "insecure" end,
		isSecureField = function() return false end,
		getVerdict = function() return "insecure" end,
		currentEpoch = function() return 1 end,
		isSecureApp = function() return false end,
		isUrlBar = function() return false end,
	}
end
-- A user state: the config.toml the wizard, or an older release, left in the
-- configuration folder the daemon resolves for this HOME.
if SEED and SEED ~= "" then
	local target = require("infra.config_paths").config("config.toml")
	assert(os.execute("mkdir -p '" .. target:match("^(.*)/[^/]+$") .. "'"), "cannot create the configuration folder")
	local source = assert(real_open(SEED, "rb"))
	local content = source:read("*a")
	source:close()
	local fh = assert(real_open(target, "wb"))
	fh:write(content)
	fh:close()
end

local hook = require("adapters.keyboard_hook")
hook.start = function() end
hook.isRunning = function() return true end
hook.get_mode = function() return "scripted" end
hook.held_text_modifier_codes = function() return {} end
hook.emergency_stop = function(why) record("EMERGENCY_STOP", why) end
hook.pump = function() return 0 end

-- The tray: rows kept, not drawn.
package.preload["platform.tray.appindicator"] = function()
	local live = false
	return {
		is_available = function() return true end,
		create = function() live = true; return true end,
		set_icon = function() return true end,
		set_menu = function() return true end,
		pump = function() return 0 end,
		destroy = function() live = false end,
		is_live = function() return live end,
	}
end

-- WebKit windows open through the manager's native seam: the page is built and
-- routed as in production, the GTK window is not drawn. The error window is a
-- user-visible error like a dialog.
package.preload["ui.webview_manager"] = function()
	local manager = dofile("ui/webview_manager.lua")
	manager._create_gtk_window = function(app_name)
		if app_name == "error_dialog" then record("DIALOG", "the error window opened") end
		record("WINDOW", app_name)
		return true
	end
	manager._destroy_gtk_window = function() return true end
	return manager
end

-- The menu context the tray builds, kept for the recommended restore.
local menu_ctx = nil
package.preload["ui.menu.menu_builder"] = function()
	local builder = dofile("ui/menu/menu_builder.lua")
	local build = builder.build
	builder.build = function(ctx)
		menu_ctx = ctx
		return build(ctx)
	end
	return builder
end

-- Long enough for every deferred start-up step (the longest, the AI warm-up,
-- waits 2 s; the error window 0.25 s), short enough to keep the suite fast.
local SOAK_SECONDS = 30

package.preload["adapters.event_loop"] = function()
	-- The real deferred queue: start-up schedules work on it.
	local adapter = dofile("adapters/event_loop.lua")
	local function soak(loop)
		for _ = 1, SOAK_SECONDS do
			clock_seconds = clock_seconds + 1
			if type(loop.onIdle) == "function" then loop.onIdle() end
			if type(loop.onPeriodic) == "function" then loop.onPeriodic() end
			adapter._run_idle_tick()
		end
	end
	adapter.run = function(loop)
		adapter._run_idle_tick()
		soak(loop)
		if ACTION == "restore_recommended" then
			if type(menu_ctx) ~= "table" then
				record("SCENARIO_FAILED", "the tray never built its menu context")
			else
				local GlobalScope = require("infra.global_scope")
				local committed, report = GlobalScope.apply("recommended", GlobalScope.participants(menu_ctx))
				record("FACT", "restore_committed=" .. tostring(committed))
				if committed ~= true then
					record("SCENARIO_FAILED", "the recommended restore did not commit: " .. tostring(report and report.detail))
				end
				soak(loop)
			end
		elseif ACTION == "delimiters_add" or ACTION == "delimiters_verify" then
			local Terminators = require("keymap.terminators")
			local Settings = require("modules.hotstrings.terminator_settings")
			if ACTION == "delimiters_add" then
				record("FACT", "delimiter_added=" .. tostring(Terminators.add_custom_terminator("custom_µ", "µ", "µ", false)))
				record("FACT", "delimiter_committed=" .. tostring(Settings.persist()))
			end
			local path = require("infra.config_paths").config("config.toml")
			local source = io.open(path, "rb")
			local bytes = source and source:read("*a") or ""
			if source then source:close() end
			local document = require("toml_codec").decode(bytes)
			local hotstrings = type(document) == "table" and document.hotstrings or nil
			local list = type(hotstrings) == "table" and hotstrings.terminators or nil
			local first = type(list) == "table" and list[1] or nil
			local second = type(list) == "table" and list[2] or nil
			local verified = type(first) == "table" and first.key == "custom_¤" and first.future == "kept"
				and type(second) == "table" and second.key == "custom_µ" and second.char == "µ" and second.consume == false
				and #list == 2 and hotstrings.unknown == "kept"
				and type(document.other) == "table" and document.other.value == 42
				and bytes:find("# Keep this user comment.", 1, true) ~= nil
				and Terminators.is_terminator("¤") and Terminators.is_terminator("µ")
				and Terminators.terminator_is_consumed("¤") and not Terminators.terminator_is_consumed("µ")
			record("FACT", "custom_list_verified=" .. tostring(verified == true))
		elseif ACTION ~= "boot" then
			record("SCENARIO_FAILED", "unknown action " .. tostring(ACTION))
		end
		-- hardening-e-presets: the navigation layer the tap-holds can enter.
		local layer_keys = 0
		local ok_tap, TapHold = pcall(require, "platform.remap.tap_hold_manager")
		if ok_tap then
			local ok_keys, keys = pcall(TapHold.keys)
			for _, key in pairs(ok_keys and keys or {}) do
				if type(key) == "table" and key.enabled ~= false and key.hold_layer == "nav" then
					layer_keys = layer_keys + 1
				end
			end
		end
		local bindings = 0
		local ok_nav, layer = pcall(function()
			return require("platform.remap.nav_layer").load({
				shared_root = require("infra.paths").shared_root(),
				config_dir = TapHold.user_path():match("^(.*)[/\\][^/\\]+$"),
			})
		end)
		if not ok_nav then record("FACT", "nav_layer_error=" .. tostring(layer)) end
		if ok_nav then for _ in pairs(layer) do bindings = bindings + 1 end end
		record("FACT", "nav_layer_bindings=" .. bindings)
		record("FACT", "nav_layer_keys=" .. layer_keys)
		record("DONE", ACTION)
	end
	return adapter
end

dofile("ergopti_hotstrings.lua")
