--- tests/unit/modules/dynamic_hotstrings/test_dynamic_dry_run_dispatch.lua

--- ==============================================================================
--- MODULE: Dynamic Dry-run Dispatch Regression
--- DESCRIPTION:
--- Exercises the original Main handler, matcher, dynamic owner and injector with
--- controlled input/output and accessibility responses, without native hardware.
--- ==============================================================================
local h = require("tests.helpers")
local root = assert(debug.getinfo(1, "S").source:match("^@(.*)/tests/unit/modules/dynamic_hotstrings/"))
local routes = {
	personal = { trigger = "@p★", output = "ok" },
	date = { trigger = "td★", output = os.date("%Y_%m_%d") },
	fields = { trigger = "@pn★", output = "ok\tyo" },
	user = { trigger = "@u★", output = "ok" },
}

local jit_suspended = false

--- Runs only the interpreter, dropping every trace, so the call hook sees each call.
local function suspend_jit()
	if not jit or not jit.status() then return end
	jit.off(); jit.flush()
	jit_suspended = true
end

--- Restores the compiler that suspend_jit turned off, once.
local function resume_jit()
	if jit_suspended then jit.on(); jit_suspended = false end
end

--- Drains the real deferred programmable callback without changing its policy.
local function drain()
	local timer, uv = require("adapters.timer_scheduler"), require("luv")
	for _ = 1, 16 do
		uv.run("nowait")
		if timer.activeCount() == 0 then return end
	end
	error("programmable callback did not retire")
end

--- Runs one actual Main route and restores all acquired fixture ownership.
--- @param kind string Dynamic route under test.
--- @param dry_run boolean Main command-line posture.
local function exercise(kind, dry_run)
	local previous = {}
	for name, value in pairs(package.loaded) do previous[name] = value end
	for name in pairs(previous) do
		if name:match("^modules%.") or name:match("^adapters%.") or name:match("^infra%.")
			or name:match("^platform%.") or name == "logger.shim"
			or name == "dynamic_hotstrings" or name:match("^dynamic_hotstrings%.") then package.loaded[name] = nil end
	end
	local directory = os.tmpname()
	assert(os.remove(directory))
	local made = os.execute("mkdir -m 700 " .. require("text_utils").shell_quote(directory))
	assert(made == true or made == 0)
	local info_path, source_path, marker = directory .. "/personal_info.toml",
		directory .. "/personal_dynamic_hotstrings.lua", directory .. "/called"
	local function write(path, text)
		local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
	end
	write(info_path, '[info]\nfirst_name = "ok"\nlast_name = "yo"\n[letters]\np = "first_name"\nn = "last_name"\n')
	write(source_path, string.format([[return function()
		return {{ id = "custom", suffix = "@u", preview = "User", callback = function()
			local file = assert(io.open(%q, "wb")); assert(file:write("called")); assert(file:close())
			return "ok"
		end }}
	end]], marker))
	local restore_preferences, injector, capture, user, atspi
	local ok, reason = pcall(function()
		require("tests.support.text_owner_fixture").with(function(guard, state, detector, policy)
			local preference_path
			restore_preferences, preference_path = require("tests.support.dynamic_hotstrings_fixture").route()
			local paths = require("infra.config_paths")
			local original_config = paths.config
			paths.config = function(name)
				if name == "config.toml" then return preference_path end
				return original_config(name)
			end
			paths.get_config_dir = function() return directory end
			local dynamic = require("modules.dynamic_hotstrings.manager")
			assert(dynamic.init({ trigger_char = "★", personal_info_path = info_path }))
			assert(dynamic.set_enabled(true))
			require("tests.support.dynamic_hotstrings_fixture").prefer_families(dynamic)
			local repeat_key = require("modules.hotstrings.repeat_key")
			assert(repeat_key.set_enabled(false))
			local glyphs = { [30] = "@", [25] = "p", [49] = "n", [20] = "t", [32] = "d", [22] = "u",
				[43] = "★", [24] = "o", [37] = "k", [21] = "y", [12] = "_" }
			for number = 0, 9 do glyphs[number == 0 and 11 or number + 1] = tostring(number) end
			local chars, inverse = {}, {}
			for code, char in pairs(glyphs) do
				chars[code + 8] = char
				inverse[char] = { keycode = code, level = 1, mods = {} }
			end
			capture = require("adapters.xkb_capture")
			capture._set_backend({ create = function() return {} end, destroy = function() end,
				capture_group = function() return 0 end,
				key_sym = function(_, code) local char = chars[code]; return char == "★" and 0x1002605 or char and char:byte() or 0 end,
				key_utf8 = function(_, code) return chars[code] or "" end,
				sym_utf8 = function(_, sym) return sym == 0x1002605 and "★" or sym > 0 and string.char(sym) or "" end,
				update_key = function() end, compose_feed = function() end,
				compose_status = function() return "nothing" end, compose_utf8 = function() end,
				compose_reset = function() end, inverse = function() return inverse end,
			})
			assert(capture.load("controlled actual XKB adapter", "C"))
			local document, commits, handler = "", 0
			local calls = { manager = 0, inject = 0, fields = 0, user = 0, source = 0 }
			require("tests.support.input_owner_fixture").with_session({ capture = capture, keys = {}, position_bits = true,
				on_char = function(...) return handler(...) end,
				after_sync = function(_, code, value)
					if value ~= 1 then return end
					if code == 14 then
						local last = 0
						for position in document:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do last = position end
						document = last > 0 and document:sub(1, last - 1) or document
					elseif code == 15 then document = document .. "\t"
					else document = document .. (glyphs[code] or "") end
				end,
			}, function(session)
				assert(session.hook.set_remapper(nil))
				require("adapters.keyboard_layout")._set_table_for_test(inverse)
				injector = require("modules.hotstrings.injector")
				injector._set_uinput(session.writer)
				injector._set_nanosleep_for_test(function() end)
				local engine_mod = require("modules.hotstrings.engine")
				local engine = engine_mod.new()
				engine:load_mappings(dynamic.prefix_mappings())
				local scripts = require("modules.shortcuts.script_actions").new({ reset = function() engine:reset() end,
					reload = function() error("unexpected reload") end, quit = function() error("unexpected quit") end })
				local gate = require("infra.input_capture_gate").new()
				local native = require("infra.user_hotstring_runtime").new({ engine = engine, injector = injector,
					magic = require("modules.hotstrings.magic_key"), detector = detector, focus_guard = guard,
					capture_gate = gate, dynamic = dynamic, paused = scripts.is_paused,
					window_info = { getFocused = function() return { appId = "owned-editor", windowTitle = "Document" } end },
					keystats = policy, replay_input = function(queued) h.assert_eq(#queued, 0); return true end,
				})
				atspi = require("adapters.atspi_focus")
				atspi._publish_resident_snapshot({ bus = state.bus, path = state.path, role = state.role })
				atspi._set_command_runner_for_test(function()
					return true, "FOCUS:" .. require("json").encode({ role = state.role, name = "Document", attributes = {},
						native_bus_name = state.bus, native_object_path = state.path, active_scope = true })
				end)
				user = require("modules.dynamic_hotstrings.user_code")
				assert(dynamic.start_user_code(native))
				assert(dynamic.set_user_code_time_activation(0.5))
				assert(dynamic.set_user_code_enabled(true))
				h.assert_eq(user.count(), 1, "the original source loader admits the actual private callback")
				local metrics = setmetatable({ on_keydown = function() end,
					record_hotstring = function() commits = commits + 1 end }, { __index = policy })
				local environment = setmetatable({ secure_focus_guard = guard, script_actions = scripts,
					-- Bare keys: the shared expansion delay reads the held modifiers per key.
					keyboard_hook = { held_modifiers = function() return {} end },
					Monotonic = require("infra.monotonic"), WordReset = require("modules.hotstrings.word_reset"),
					terminators_mod = require("keymap.terminators"), RepeatKey = repeat_key,
					MagicKey = require("modules.hotstrings.magic_key"), opts = { dry_run = dry_run },
					_cached_app_id = "owned-editor", keystats = metrics, engine_mod = engine_mod, engine = engine,
					dyn_hotstrings = dynamic, injector = injector, Logger = require("logger.shim"), user_hotstring_native = native,
				}, { __index = _G })
				local main = assert(io.open(root .. "/ergopti_hotstrings.lua", "rb"))
				local source = main:read("*a"); assert(main:close())
				local first = assert(source:find("\tlocal function handle_char(", 1, true))
				local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
				local body = "local _undoable; local _last_offered; local on_char; " .. source:sub(first, last - 1)
					.. "\non_char=handle_char; return handle_char"
				local compiled
				if loadstring then compiled = assert(loadstring(body)); setfenv(compiled, environment)
				else compiled = assert(load(body, "original Main handle_char", "t", environment)) end
				handler = gate.guard(compiled())
				local read = require("adapters.file_system").read_with_status
				-- LuaJIT calls no hook from a compiled trace, so a hot read or request
				-- loop went uncounted on one Arch run (dyn-dry-run-hook-jit). The
				-- interpreter alone runs while the calls are counted.
				suspend_jit()
				if jit then h.assert_eq(jit.status(), false, "the call hook counts only interpreted calls") end
				debug.sethook(function()
					local info = debug.getinfo(2, "f")
					if not info then return end
					if info.func == dynamic.on_trigger then calls.manager = calls.manager + 1
					elseif info.func == injector.inject then calls.inject = calls.inject + 1
					elseif info.func == injector.inject_fields then calls.fields = calls.fields + 1
					elseif info.func == user.request then calls.user = calls.user + 1
					elseif info.func == read then
						local _, path = debug.getlocal(2, 1)
						if path == source_path then calls.source = calls.source + 1 end
					end
				end, "c")
				local position = 0
				for char in routes[kind].trigger:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
					position = position + 1
					local code = assert(inverse[char]).keycode
					session.edge("a", code, 1, 1000 + position * 10)
					session.edge("a", code, 0, 1001 + position * 10)
				end
				drain()
				debug.sethook()
				resume_jit()
				h.assert_eq(calls.manager, dry_run and 0 or #routes[kind].trigger:gsub("[\128-\191]", ""), "Main gates before dynamic dispatch")
				if dry_run then
					h.assert_eq(calls, { manager = 0, inject = 0, fields = 0, user = 0, source = 0 }, "no output or programmable source I/O is dispatched")
				else
					h.assert_true(calls.inject + calls.fields > 0, "the normal route reaches the real injector")
					if kind == "fields" then h.assert_eq(calls.fields, 1) end
					if kind == "user" then h.assert_true(calls.user > 0); h.assert_true(calls.source > 0) end
				end
				h.assert_eq(document, dry_run and routes[kind].trigger or routes[kind].output)
				h.assert_eq(commits, not dry_run and kind ~= "user" and 1 or 0, "only a synchronous committed expansion is recorded by Main")
				local called = io.open(marker, "rb")
				h.assert_eq(called ~= nil, not dry_run and kind == "user", "the real deferred callback only writes in normal mode")
				if called then assert(called:close()) end
				h.assert_eq(guard.blocks_text(), false, "the original focus guard remains active on the same field")
				local held = {}
				for _, row in ipairs(session.rows) do
					if row[2] == 1 then held[row[1]] = true elseif row[2] == 0 then held[row[1]] = nil end
				end
				h.assert_eq(held, {}, "every forwarded or authored key is released")
				assert(user.stop()); drain()
			end)
		end)
	end)
	debug.sethook()
	resume_jit()
	local cleanup_errors = {}
	local function cleanup(action)
		local cleaned, detail = pcall(action)
		if not cleaned then cleanup_errors[#cleanup_errors + 1] = tostring(detail) end
	end
	cleanup(function() if user then assert(user.stop()); drain() end end)
	cleanup(function() if atspi then atspi._set_command_runner_for_test(nil); atspi._publish_resident_snapshot(nil) end end)
	cleanup(function() if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end end)
	cleanup(function() if capture then capture._reset_backend() end end)
	cleanup(function() if restore_preferences then restore_preferences() end end)
	for _, path in ipairs({ info_path, source_path, marker }) do os.remove(path) end
	cleanup(function() assert(os.remove(directory)) end)
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	if #cleanup_errors > 0 then error(tostring(reason) .. " cleanup: " .. table.concat(cleanup_errors, "; "), 0) end
	if not ok then error(reason, 0) end
end

h.describe("dynamic dry-run Main dispatch", function()
	for _, kind in ipairs({ "personal", "date", "fields", "user" }) do
		for _, dry_run in ipairs({ false, true }) do
			h.it("dynamic dry-run " .. kind .. " posture " .. tostring(dry_run), function() exercise(kind, dry_run) end)
		end
	end
end)

return true
