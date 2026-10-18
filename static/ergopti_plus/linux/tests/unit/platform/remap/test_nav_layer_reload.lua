--- tests/unit/platform/remap/test_nav_layer_reload.lua

--- ==============================================================================
--- MODULE: Native Navigation Reload Transactions
--- DESCRIPTION:
--- A rejected layer must preserve both the installed engine and its admission
--- state, even when the tap-hold file changed in the same reload.
--- ==============================================================================

local helpers = require("tests.helpers")

local function write(path, text)
	local file = assert(io.open(path, "wb"))
	file:write(text)
	file:close()
end

helpers.describe("native navigation reload transactions", function()
	helpers.it("retains the installed engine and admission after a malformed layer", function()
		local dir = os.tmpname()
		os.remove(dir)
		local made = os.execute('mkdir "' .. dir .. '"')
		assert(made == true or made == 0)
		local Manager = helpers.load_module("platform.remap.tap_hold_manager")
		local hook = { key_text = function() return nil end,
			held_modifiers = function() return {} end,
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end }
		function hook.set_remapper(engine) hook.engine = engine end
		local ok, err = pcall(function()
			write(dir .. "/tap_hold.toml", '[tap_hold]\nenabled = true\n')
			Manager.init({ keyboard_hook = hook, execute_action = function() end,
				action_names = function() return {} end, on_text_injected = function() end,
				defaults_path = helpers.driver_root() .. "/../_shared/tap_hold/defaults.toml",
				user_path = dir .. "/tap_hold.toml" })
			local original = assert(hook.engine)
			write(dir .. "/tap_hold.toml", '[tap_hold]\nenabled = false\n')
			write(dir .. "/layers.toml", '[broken')
			helpers.assert_eq(Manager.reload(), false, "invalid layer refuses the entire reload")
			helpers.assert_true(hook.engine == original, "no partial engine publication")
			Manager.set_enabled(true)
			helpers.assert_true(hook.engine == original, "the previous file admission remains in force")
		end)
		Manager._reset_for_test()
		os.remove(dir .. "/layers.toml")
		os.remove(dir .. "/tap_hold.toml")
		os.execute('rmdir "' .. dir .. '"')
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("outdated layers.toml entries (config-outdated-layers)", function()
	helpers.it("starts with the valid bindings and warns once per outdated entry, naming the file", function()
		local dir = os.tmpname()
		os.remove(dir)
		local made = os.execute('mkdir "' .. dir .. '"')
		assert(made == true or made == 0)
		local warnings = {}
		local recorder = helpers.make_logger_stub()
		recorder.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		local previous_logger = package.loaded["logger.shim"]
		package.loaded["logger.shim"] = recorder
		require("config_outdated").reset_for_tests()
		local ok, err = pcall(function()
			write(dir .. "/layers.toml", table.concat({
				"[_meta]", "schema_version = 1", "retired_field = 1",
				"[layers.nav.all]", '"KeyD" = "retired_nav_action"', '"KeyZZ" = "none"', '"KeyJ" = "keystroke:Home"',
				"[layers.symbols.all]", '"KeyK" = "none"', "",
			}, "\n"))
			local NavLayer = helpers.load_module("platform.remap.nav_layer")
			local shared_root = helpers.driver_root() .. "/../_shared"
			local layer = NavLayer.load({ shared_root = shared_root, config_dir = dir })
			local ctx = require("keymap.layers").load_context({ shared_root = shared_root,
				json_decode = require("json").decode, toml_decode = require("toml_codec").decode,
				read_file = require("keymap.layer_editor").read_shipped })
			local key_j, home = ctx.registry.keys.KeyJ.evdev, ctx.registry.keys.Home.evdev
			helpers.assert_eq(layer[key_j], { chords = { { mods = {}, keys = { home } } } },
				"the valid binding of the same file still loads")
			local bound = 0
			for _ in pairs(layer) do bound = bound + 1 end
			helpers.assert_eq(bound, 1, "no outdated entry reaches the engine")
			local text = table.concat(warnings, "\n")
			for _, entry in ipairs({ "layers.nav.all.KeyD", "layers.nav.all.KeyZZ", "_meta.retired_field", "layers.symbols" }) do
				helpers.assert_true(text:find("'" .. entry .. "' in '" .. dir .. "/layers.toml'", 1, true) ~= nil,
					entry .. " is named with its file: " .. text)
			end
			helpers.assert_eq(#warnings, 4, "one WARNING per outdated entry: " .. text)
			NavLayer.load({ shared_root = shared_root, config_dir = dir })
			helpers.assert_eq(#warnings, 4, "a reload does not repeat them")
			write(dir .. "/layers.toml", "[_meta]\nschema_version = 99\n")
			helpers.assert_throws(function() NavLayer.load({ shared_root = shared_root, config_dir = dir }) end,
				"a file of another layers schema is still refused as a whole")
		end)
		package.loaded["logger.shim"] = previous_logger
		os.remove(dir .. "/layers.toml")
		os.execute('rmdir "' .. dir .. '"')
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("boot navigation file isolation (nav-layer-boot-refusal)", function()
	local valid = '[_meta]\nschema_version = 1\n[layers.nav.all]\nKeyJ = "keystroke:Home"\n'
	local tap_text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
		.. '[tap_hold.keys.caps_lock]\ntap_action = "enter"\nhold_modifier = "ctrl"\ntime_activation_seconds = 0.35\n'

	-- Inject only the original native read/close boundary; never supply a
	-- successful classified receipt or replace the shared source validator.
	local function with_read_fault(target, failure, callback)
		local original_open = io.open
		local owned = {}
		local facts = { opens = 0, reads = 0, closes = 0, native_closes = 0,
			cleanup_closes = 0, open_refusals = 0 }
		local function close_owned(record)
			if record.attempted then return record.closed end
			record.attempted = true
			local called, closed = pcall(record.close, record.handle)
			record.closed = called and closed == true
			if record.closed then facts.native_closes = facts.native_closes + 1 end
			return record.closed
		end
		io.open = function(path, mode)
			if path ~= target or mode ~= "r" and mode ~= "rb" then return original_open(path, mode) end
			if failure == "open" then
				facts.open_refusals = facts.open_refusals + 1
				return nil, "owned navigation read refused", 13
			end
			local handle, detail, code = original_open(path, mode)
			if not handle then return nil, detail, code end
			local record = { handle = handle, close = handle.close, attempted = false, closed = false }
			owned[#owned + 1] = record
			facts.opens = facts.opens + 1
			return {
				read = function(_, ...)
					facts.reads = facts.reads + 1
					return handle:read(...)
				end,
				close = function()
					facts.closes = facts.closes + 1
					assert(not record.attempted, "fixture stream must be closed only once")
					if not close_owned(record) then return nil, "real fixture close was not acknowledged" end
					if failure == "false" then return false, "controlled close ACK refusal" end
					assert(failure == "nil", "unknown native close fault")
					return nil, "controlled close ACK refusal"
				end,
			}
		end
		local called, result = pcall(callback)
		io.open = original_open
		local closed = true
		for _, record in ipairs(owned) do
			if not record.attempted then
				facts.cleanup_closes = facts.cleanup_closes + 1
				close_owned(record)
			end
			if not record.closed then closed = false end
		end
		if not closed then
			error((called and "" or tostring(result) .. "; ") .. "fixture native close remains unacknowledged", 0)
		end
		if not called then error(result, 0) end
		return facts, result
	end

	local function session(layer_text, fault, fn)
		local dir = os.tmpname()
		os.remove(dir)
		local made = os.execute('mkdir "' .. dir .. '"')
		assert(made == true or made == 0)
		local names = { "logger.shim", "platform.remap.nav_layer", "platform.remap.tap_hold_manager" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["logger.shim"] = logger
		local Manager, NavLayer, compile
		local hook = { key_text = function() return nil end,
			held_modifiers = function() return {} end,
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end }
		function hook.set_remapper(engine) hook.engine = engine end
		local ok, err = pcall(function()
			Manager = require("platform.remap.tap_hold_manager")
			NavLayer = require("platform.remap.nav_layer")
			compile = NavLayer.compile
			write(dir .. "/tap_hold.toml", tap_text)
			if layer_text then write(dir .. "/layers.toml", layer_text) end
			local function initialize()
				local initialized, detail = pcall(Manager.init, {
					keyboard_hook = hook, execute_action = function() end,
					action_names = function() return {} end, on_text_injected = function() end,
					defaults_path = helpers.driver_root() .. "/../_shared/tap_hold/defaults.toml",
					user_path = dir .. "/tap_hold.toml",
				})
				return { initialized = initialized, detail = detail }
			end
			local state, facts
			if fault == "user_read" then
				facts, state = with_read_fault(dir .. "/layers.toml", "open", initialize)
			elseif fault == "shipped_read" then
				facts, state = with_read_fault(helpers.driver_root() .. "/../_shared/data/keycodes/physical_keys.json", "open", initialize)
			elseif fault == "user_close_false" or fault == "user_close_nil" then
				facts, state = with_read_fault(dir .. "/layers.toml", fault == "user_close_false" and "false" or "nil", initialize)
			elseif fault == "shipped_close_false" then
				facts, state = with_read_fault(helpers.driver_root() .. "/../_shared/data/keycodes/physical_keys.json", "false", initialize)
			else
				if fault == "compile" then NavLayer.compile = function() error("owned native compilation refused") end end
				state = initialize()
			end
			NavLayer.compile = compile
			fn({ dir = dir, manager = Manager, nav = NavLayer, hook = hook, errors = errors,
				initialized = state.initialized, init_error = state.detail, fault_facts = facts })
		end)
		if NavLayer and compile then NavLayer.compile = compile end
		local reset_ok, reset_result = true, true
		if Manager then reset_ok, reset_result = pcall(Manager._reset_for_test) end
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		os.remove(dir .. "/layers.toml")
		os.remove(dir .. "/tap_hold.toml")
		os.execute('rmdir "' .. dir .. '"')
		if not ok then error(err, 0) end
		if not reset_ok or reset_result == false then error("fixture Manager cleanup refused: " .. tostring(reset_result), 0) end
	end

	for _, case in ipairs({
		{ name = "malformed TOML", text = "[broken" },
		{ name = "missing schema", text = '[layers.nav.all]\nKeyJ = "keystroke:Home"\n' },
		{ name = "unsupported schema", text = "[_meta]\nschema_version = 99\n" },
		{ name = "invalid layers root", text = "layers = 1\n[_meta]\nschema_version = 1\n" },
		{ name = "unreadable user file", text = valid, fault = "user_read" },
	}) do
		helpers.it("(nav-layer-boot-refusal) isolates " .. case.name .. " without retiring tap-holds", function()
			session(case.text, case.fault, function(s)
				helpers.assert_true(s.initialized, "the actual boot manager admits the independent tap-hold file")
				helpers.assert_true(s.manager.is_active())
				local original = assert(s.hook.engine)
				helpers.assert_eq(original.nav_layer, {}, "no navigation binding from a refused file")
				helpers.assert_true(original:handles(58), "the configured CapsLock tap remains installed")
				local pressed = original:process(58, 1, 1000)
				helpers.assert_eq(pressed, { { code = 29, value = 1 } }, "the independent configured Ctrl hold remains active")
				local events = original:process(58, 0, 1100)
				helpers.assert_eq(events, { { code = 29, value = 0 }, { code = 28, value = 1 }, { code = 28, value = 0 } },
					"the real engine releases Ctrl and emits Enter without leaving a held key")
				helpers.assert_eq(#s.errors, 1, "the refused navigation file is reported as an ERROR")
				helpers.assert_true(s.errors[1]:find(s.dir .. "/layers.toml", 1, true) ~= nil)
				local file = assert(io.open(s.dir .. "/layers.toml", "rb"))
				helpers.assert_eq(file:read("*a"), case.text, "boot never rewrites user data")
				file:close()
				write(s.dir .. "/layers.toml", valid)
				helpers.assert_true(s.manager.reload(), "a repaired file is admitted by the actual reload owner")
				local repaired = assert(s.hook.engine)
				helpers.assert_true(repaired ~= original)
				helpers.assert_eq(repaired.nav_layer[36], { chords = { { mods = {}, keys = { 102 } } } }, "KeyJ now emits Home")
				write(s.dir .. "/layers.toml", "[broken")
				helpers.assert_eq(s.manager.reload(), false, "later malformed loads remain strict")
				helpers.assert_true(s.hook.engine == repaired, "the last acknowledged engine remains installed")
				helpers.assert_eq(s.manager.apply_configuration(require("toml_codec").decode(tap_text)), false,
					"a scope candidate cannot reuse boot isolation")
				helpers.assert_true(s.hook.engine == repaired)
				for name, expected in pairs({ ["layers.toml"] = "[broken", ["tap_hold.toml"] = tap_text }) do
					local saved = assert(io.open(s.dir .. "/" .. name, "rb"))
					local content = saved:read("*a")
					saved:close()
					helpers.assert_eq(content, expected, "reload and candidate refusal preserve " .. name)
				end
			end)
		end)
	end

	for _, case in ipairs({ { name = "shipped registry", fault = "shipped_read" }, { name = "native compiler", fault = "compile" } }) do
		helpers.it("(nav-layer-boot-refusal) still refuses a broken " .. case.name, function()
			session(valid, case.fault, function(s)
				helpers.assert_eq(s.initialized, false, "non-user-file failures must remain fatal")
				helpers.assert_nil(s.hook.engine, "no partial native engine is installed")
				helpers.assert_eq(#s.errors, 0, "no classified user-file fallback is claimed")
			end)
		end)
	end

	helpers.it("(nav-layer-boot-refusal) retains entry-wise filtering and valid bindings", function()
		local text = valid .. 'KeyZZ = "none"\n'
		session(text, nil, function(s)
			helpers.assert_true(s.initialized)
			helpers.assert_eq(s.hook.engine.nav_layer[36], { chords = { { mods = {}, keys = { 102 } } } })
			helpers.assert_eq(#s.errors, 0, "an outdated entry is not a whole-file refusal")
		end)
	end)

	local function assert_closed_fault(facts)
		helpers.assert_eq(facts.opens, 1, "the exact real source was opened once")
		helpers.assert_eq(facts.reads, 1, "the decoded source came from one real complete read")
		helpers.assert_eq(facts.closes, 1, "the reader attempted the source close exactly once")
		helpers.assert_eq(facts.native_closes, 1, "the fixture physically closed its original stream")
		helpers.assert_eq(facts.cleanup_closes, 0, "the source reader performed its own close")
		helpers.assert_eq(facts.open_refusals, 0, "this fault is a close ACK, not a missing source")
	end

	local function boot_close_refusal(failure)
		session(valid, "user_close_" .. failure, function(s)
			assert_closed_fault(s.fault_facts)
			helpers.assert_true(s.initialized, "a user source refusal preserves independent tap-hold initialization")
			helpers.assert_eq(s.hook.engine.nav_layer, {}, "unacknowledged source bytes cannot publish navigation")
			helpers.assert_true(s.manager.is_active())
			helpers.assert_true(s.hook.engine:handles(58), "the original CapsLock hold remains installed")
			helpers.assert_eq(#s.errors, 1, "boot retains the existing whole-user-file refusal")
			helpers.assert_true(s.manager.reload(), "the restored real reader accepts the same unchanged file")
			helpers.assert_eq(s.hook.engine.nav_layer[36], { chords = { { mods = {}, keys = { 102 } } } })
		end)
	end

	helpers.it("(nav-source-close-ack) boot isolates a false user close ACK without retiring tap-holds", function()
		boot_close_refusal("false")
	end)

	helpers.it("(nav-source-close-ack) boot isolates a nil user close ACK without retiring tap-holds", function()
		boot_close_refusal("nil")
	end)

	local function reload_close_refusal(failure)
		session(valid, nil, function(s)
			helpers.assert_true(s.initialized)
			local installed = s.hook.engine
			local previous = s.manager.configuration_snapshot()
			helpers.assert_eq(installed.nav_layer[36], { chords = { { mods = {}, keys = { 102 } } } })
			local accepted
			local facts = with_read_fault(s.dir .. "/layers.toml", failure, function()
				accepted = s.manager.reload()
			end)
			assert_closed_fault(facts)
			helpers.assert_eq(accepted, false, "a failed original source close cannot acknowledge a reload")
			helpers.assert_true(s.hook.engine == installed, "the exact previous engine stays installed")
			local retained = s.manager.configuration_snapshot()
			for _, name in ipairs({ "loaded", "one_shot", "engine", "combinations" }) do
				helpers.assert_true(retained[name] == previous[name], "reload retains the original " .. name)
			end
			helpers.assert_eq(#s.errors, 1, "the failed reload is reported once")
			helpers.assert_true(s.manager.reload(), "a later separate healthy load remains possible")
		end)
	end

	helpers.it("(nav-source-close-ack) reload refuses a false user close ACK and retains the exact installed tuple", function()
		reload_close_refusal("false")
	end)

	helpers.it("(nav-source-close-ack) reload refuses a nil user close ACK and retains the exact installed tuple", function()
		reload_close_refusal("nil")
	end)

	helpers.it("(nav-source-close-ack) a refused shipped registry close is fatal before engine installation", function()
		session(valid, "shipped_close_false", function(s)
			assert_closed_fault(s.fault_facts)
			helpers.assert_eq(s.initialized, false, "shipped-source failure cannot borrow user-file boot isolation")
			helpers.assert_nil(s.hook.engine, "no partial engine is installed")
			helpers.assert_eq(#s.errors, 0, "no isolated user-file fallback is claimed")
			helpers.assert_contains(tostring(s.init_error), "source close failed")
		end)
	end)
end)


helpers.describe("original configured Navigation source reservations", function()
	local NAV_NONE = '[_meta]\nschema_version = 1\n[layers.nav.all]\nKeyJ = "none"\n'
	local NAV_HOME = '[_meta]\nschema_version = 1\n[layers.nav.all]\nKeyJ = "keystroke:Home"\n'
	local TAP_NAV = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.left_alt]\n'
		.. 'tap_action = "enter"\nhold_modifier = ""\nhold_layer = "nav"\ntime_activation_seconds = 0.2\n'
	local TAP_EMPTY = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
	local function write_source(path, bytes_expected)
		local handle = assert(io.open(path, "wb"))
		local wrote, result = pcall(handle.write, handle, bytes_expected)
		local closed, acknowledged = pcall(handle.close, handle)
		assert(wrote and result ~= nil and result ~= false, "real source write must complete")
		assert(closed and acknowledged == true, "real source close must be acknowledged")
		local verification = assert(io.open(path, "rb"))
		local read_ok, bytes = pcall(verification.read, verification, "*a")
		local close_ok, verified_closed = pcall(verification.close, verification)
		assert(read_ok and bytes == bytes_expected, "real written bytes must match exactly")
		assert(close_ok and verified_closed == true, "real verification handle must close")
	end

	local function owned(nav_text, tap_text, body, config_text)
		local previous, original_open = {}, io.open
		for name, value in pairs(package.loaded) do previous[name] = value end
		local dir, quote, made_directory
		local Manager, outcome
		local hook = { calls = 0, actions = 0, typed = 0 }
		function hook.set_remapper(engine) hook.calls = hook.calls + 1; hook.engine = engine; return true end
		function hook.key_text() return nil end
		function hook.held_modifiers() return {} end
		function hook.held_text_modifier_codes() return {} end
		function hook.held_shortcut_modifier_codes() return {} end
		local ok, err = pcall(function()
			dir = os.tmpname()
			assert(os.remove(dir))
			quote = require("text_utils").shell_quote
			local made = os.execute("mkdir " .. quote(dir))
			assert(made == true or made == 0)
			made_directory = true
			write_source(dir .. "/config.toml", config_text or "")
			package.loaded["infra.config_paths"] = { config = function(name) return dir .. "/" .. name end }
			package.loaded["platform.remap.nav_layer"] = nil
			package.loaded["platform.remap.tap_hold_manager"] = nil
			package.loaded["modules.shortcuts.key_combinations"] = nil
			local Nav = require("platform.remap.nav_layer")
			Manager = require("platform.remap.tap_hold_manager")
			write_source(dir .. "/layers.toml", nav_text)
			write_source(dir .. "/tap_hold.toml", tap_text or TAP_NAV)
			local opts = { shared_root = require("infra.paths").shared_root(), config_dir = dir }
			local function start()
				return Manager.init({ keyboard_hook = hook,
					execute_action = function() hook.actions = hook.actions + 1 end,
					action_names = require("modules.gestures.manager").get_executable_action_names,
					on_text_injected = function() hook.typed = hook.typed + 1 end,
					defaults_path = opts.shared_root .. "/tap_hold/defaults.toml", user_path = dir .. "/tap_hold.toml" })
			end
			outcome = body({ nav = Nav, manager = Manager, dir = dir, opts = opts, hook = hook, start = start })
		end)
		io.open = original_open
		local cleanup = {}
		if Manager then
			local called, closed = pcall(Manager._reset_for_test)
			if not called or closed ~= true then cleanup[#cleanup + 1] = "Manager retirement refused: " .. tostring(closed) end
		end
		for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(previous) do package.loaded[name] = value end
		if made_directory then
			for _, name in ipairs({ "layers.toml", "tap_hold.toml", "config.toml" }) do
				local called, removed, detail, code = pcall(os.remove, dir .. "/" .. name)
				if not called or removed ~= true and code ~= 2 then
					cleanup[#cleanup + 1] = "fixture removal refused: " .. tostring(called and detail or removed)
				end
			end
			local called, removed = pcall(os.execute, "rmdir " .. quote(dir))
			if not called or removed ~= true and removed ~= 0 then cleanup[#cleanup + 1] = "fixture directory removal refused" end
		end
		if not ok or #cleanup > 0 then error((ok and "" or tostring(err) .. "; ") .. table.concat(cleanup, "; "), 0) end
		return outcome
	end

	local function has_nav(frame)
		for _, claim in ipairs(frame.claims) do
			if claim.binding == "nav_layer__36" then return claim.kind == "prefix" and claim.codes[1] == 36 and claim.unmodified_only == true end
		end
		return false
	end

	helpers.it("(nav-configured-reservation) original None bytes issue a source-bound map, never a clone or copied issuance", function()
		owned(NAV_NONE, nil, function(s)
			local map, issuance = s.nav.load(s.opts)
			helpers.assert_eq(map[36], { mods = {}, keys = {} }, "the original first return remains the compiled None map")
			local frame = assert(s.nav.capture_source_observation(map, issuance, s.opts.shared_root, s.opts.config_dir))
			helpers.assert_true(frame.current()); helpers.assert_true(frame.sealed())
			helpers.assert_nil(s.nav.capture_source_observation({ [36] = map[36] }, issuance, s.opts.shared_root, s.opts.config_dir))
			helpers.assert_nil(s.nav.capture_source_observation(map, {}, s.opts.shared_root, s.opts.config_dir))
			map[36].keys[1] = 1
			helpers.assert_eq(frame.sealed(), false, "mutable compiled fields cannot borrow the source observation")
		end)
	end)

	helpers.it("(nav-configured-reservation) original read bytes stay the baseline when the file changes at its genuine close", function()
		owned(NAV_NONE, nil, function(s)
			local open, closes = io.open, 0
			io.open = function(path, mode)
				local handle, detail, code = open(path, mode)
				if path ~= s.dir .. "/layers.toml" or mode ~= "r" or not handle then return handle, detail, code end
				return { read = function(_, ...) return handle:read(...) end, close = function()
					closes = closes + 1
					local closed, close_detail = handle:close()
					if closed ~= true then return closed, close_detail end
					write_source(path, NAV_HOME)
					return true
				end }
			end
			local loaded, map, issuance = pcall(s.nav.load, s.opts)
			io.open = open
			if not loaded then error(map, 0) end
			helpers.assert_eq(closes, 1); helpers.assert_eq(map[36], { mods = {}, keys = {} })
			local frame = assert(s.nav.capture_source_observation(map, issuance, s.opts.shared_root, s.opts.config_dir))
			helpers.assert_eq(frame.current(), false, "a later read may compare, never replace the original baseline")
		end)
	end)

	helpers.it("(nav-configured-reservation) source export replacement revokes observation without rewriting its source", function()
		owned(NAV_NONE, nil, function(s)
			local map, issuance = s.nav.load(s.opts)
			local frame = assert(s.nav.capture_source_observation(map, issuance, s.opts.shared_root, s.opts.config_dir))
			local decode = require("json").decode
			local ok, err = pcall(function()
				require("json").decode = function(...) return decode(...) end
				helpers.assert_eq(frame.current(), false); helpers.assert_eq(frame.sealed(), false)
			end)
			require("json").decode = decode
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("(nav-configured-reservation) retired original map and issuance collect without a weak-value backreference", function()
		owned(NAV_NONE, nil, function(s)
			local weak = setmetatable({}, { __mode = "v" })
			do
				local map, issuance = s.nav.load(s.opts)
				helpers.assert_eq(type(issuance), "table"); weak[1], weak[2] = map, issuance
				map, issuance = nil, nil
			end
			collectgarbage("collect"); collectgarbage("collect")
			helpers.assert_nil(weak[1]); helpers.assert_nil(weak[2])
		end)
	end)

	helpers.it("(nav-configured-reservation) a self-restoring replaced compiler cannot issue original-load provenance", function()
		owned(NAV_NONE, nil, function(s)
			local healthy, issued = s.nav.load(s.opts)
			helpers.assert_not_nil(s.nav.capture_source_observation(healthy, issued, s.opts.shared_root, s.opts.config_dir))
			local compile, calls = s.nav.compile, 0
			s.nav.compile = function()
				calls = calls + 1; s.nav.compile = compile
				return { [1] = { mods = {}, keys = {} } }
			end
			local loaded, map, observation = pcall(s.nav.load, s.opts)
			s.nav.compile = compile
			if not loaded then error(map, 0) end
			helpers.assert_eq(calls, 1, "a deliberately replaced legacy compile port retains its old call semantics")
			helpers.assert_eq(map, { [1] = { mods = {}, keys = {} } })
			helpers.assert_nil(observation, "restoring the export after the call does not authenticate its map")
			helpers.assert_nil(s.nav.capture_source_observation(map, observation, s.opts.shared_root, s.opts.config_dir))
		end)
	end)

	helpers.it("(nav-configured-reservation) a self-restoring replaced reader cannot issue original-load provenance", function()
		owned(NAV_NONE, nil, function(s)
			local healthy, issued = s.nav.load(s.opts)
			helpers.assert_not_nil(s.nav.capture_source_observation(healthy, issued, s.opts.shared_root, s.opts.config_dir))
			local Writer = require("toml_codec.writer")
			local read, calls = Writer.read_classified, 0
			Writer.read_classified = function(path, ...)
				if path == s.dir .. "/layers.toml" then
					calls = calls + 1; Writer.read_classified = read
					return NAV_HOME, "ok"
				end
				return read(path, ...)
			end
			local loaded, map, observation = pcall(s.nav.load, s.opts)
			Writer.read_classified = read
			if not loaded then error(map, 0) end
			helpers.assert_eq(calls, 1); helpers.assert_not_nil(map[36].chords)
			helpers.assert_nil(observation, "forged bytes do not become an original source baseline after self-restoration")
			helpers.assert_nil(s.nav.capture_source_observation(map, observation, s.opts.shared_root, s.opts.config_dir))
		end)
	end)

	helpers.it("(nav-configured-reservation) real bare Manager publishes detached reachable None reservations without operations", function()
		owned(NAV_NONE, nil, function(s)
			helpers.assert_true(s.start())
			local before = s.hook.calls
			local frame = assert(s.manager.capture_collision_inventory())
			helpers.assert_true(has_nav(frame)); helpers.assert_true(frame.current()); helpers.assert_true(frame.sealed())
			helpers.assert_eq(s.hook.calls, before); helpers.assert_eq(s.hook.actions, 0); helpers.assert_eq(s.hook.typed, 0)
			local free = require("shortcuts.physical_conflicts").conflicts({ slot = "physical_none_KeyK", action = "copy",
				code = 37, mods = {}, aliases = { k = true } }, frame.claims)
			helpers.assert_eq(free, false, "a distinct native input remains free in the actual shared policy")
			for _, claim in ipairs(frame.claims) do if claim.binding == "nav_layer__36" then claim.codes[1] = -1 end end
			helpers.assert_true(has_nav(assert(s.manager.capture_collision_inventory())), "detached claims cannot mutate the original map")
		end)
	end)

	helpers.it("(nav-configured-reservation) no reachable activator is proven empty, while held and private armed state refuse", function()
		owned(NAV_NONE, TAP_EMPTY, function(s)
			helpers.assert_true(s.start()); helpers.assert_eq(has_nav(assert(s.manager.capture_collision_inventory())), false)
		end)
		owned(NAV_NONE, nil, function(s)
			helpers.assert_true(s.start())
			local frame = assert(s.manager.capture_collision_inventory())
			s.hook.engine:process(56, 1, 0)
			helpers.assert_eq(frame.current(), false); helpers.assert_nil(s.manager.capture_collision_inventory())
			s.hook.engine:release_all()
			helpers.assert_true(s.hook.engine:arm_caps_word(function() return true end))
			helpers.assert_nil(s.manager.capture_collision_inventory(), "original private input_arm_state observes CapsWord")
			helpers.assert_true(s.hook.engine:clear_input_arm())
			helpers.assert_true(has_nav(assert(s.manager.capture_collision_inventory())))
		end)
	end)

	helpers.it("(nav-configured-reservation) genuine empty map never authenticates a replaced base map", function()
		owned('[_meta]\nschema_version = 1\n', nil, function(s)
			helpers.assert_true(s.start())
			local engine, frame = s.hook.engine, assert(s.manager.capture_collision_inventory())
			helpers.assert_eq(engine.nav_layer, {})
			helpers.assert_eq(has_nav(frame), false)
			local original = engine.nav_layer
			engine.nav_layer = {}
			helpers.assert_eq(frame.sealed(), false, "empty contents do not replace the original base/map identity")
			helpers.assert_nil(s.manager.capture_collision_inventory())
			engine.nav_layer = original
			helpers.assert_not_nil(s.manager.capture_collision_inventory(), "restoring the genuine original association is reversible")
		end)
	end)

	helpers.it("(nav-configured-reservation) rejected reload retains the old engine but refuses changed original Nav source", function()
		owned(NAV_NONE, nil, function(s)
			helpers.assert_true(s.start())
			local engine, frame = s.hook.engine, assert(s.manager.capture_collision_inventory())
			write_source(s.dir .. "/layers.toml", "[broken")
			helpers.assert_eq(s.manager.reload(), false); helpers.assert_true(rawequal(s.hook.engine, engine))
			helpers.assert_eq(frame.current(), false); helpers.assert_nil(s.manager.capture_collision_inventory())
		end)
	end)

	helpers.it("(nav-configured-reservation) successful successor and exact inverse retain their own Nav source association", function()
		owned(NAV_NONE, nil, function(s)
			helpers.assert_true(s.start())
			local saved, first = s.manager.configuration_snapshot(), assert(s.manager.capture_collision_inventory())
			write_source(s.dir .. "/layers.toml", NAV_HOME)
			helpers.assert_true(s.manager.reload()); helpers.assert_eq(first.current(), false)
			local successor = assert(s.manager.capture_collision_inventory()); helpers.assert_true(has_nav(successor))
			write_source(s.dir .. "/layers.toml", NAV_NONE)
			helpers.assert_true(s.manager.restore_configuration(saved))
			helpers.assert_true(rawequal(s.hook.engine, saved.engine)); helpers.assert_eq(successor.current(), false)
			helpers.assert_true(has_nav(assert(s.manager.capture_collision_inventory())))
			helpers.assert_eq(first.current(), false, "inverse publication does not revive an old Manager generation")
		end)
	end)

	helpers.it("(nav-configured-reservation) disable and pause revoke the old frame without public delivery authority", function()
		owned(NAV_NONE, nil, function(s)
			helpers.assert_true(s.start())
			local frame = assert(s.manager.capture_collision_inventory())
			helpers.assert_true(s.manager.set_enabled(false)); helpers.assert_eq(frame.current(), false)
			helpers.assert_eq(has_nav(assert(s.manager.capture_collision_inventory())), false)
			helpers.assert_true(s.manager.set_enabled(true)); s.manager.set_paused(true)
			helpers.assert_nil(s.manager.capture_collision_inventory())
		end)
	end)

	helpers.it("(nav-configured-reservation) nonempty real pair wrapper stays unavailable even when tap-holds are switched off", function()
		owned(NAV_NONE, nil, function(s)
			helpers.assert_true(s.start()); helpers.assert_true(type(rawget(s.hook.engine, "has_combinations")) == "function" and s.hook.engine.has_combinations() == true)
			helpers.assert_nil(s.manager.capture_collision_inventory())
			helpers.assert_true(s.manager.set_enabled(false))
			helpers.assert_true(type(rawget(s.hook.engine, "has_combinations")) == "function" and s.hook.engine.has_combinations() == true)
			helpers.assert_nil(s.manager.capture_collision_inventory(), "the retained wrapper is not a proven empty Nav domain")
		end, '[shortcuts]\nenabled = true\n[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n')
	end)
end)
