--- tests/unit/ui/menu/test_runtime_uninitialized_clear_admission.lua

--- ==============================================================================
--- MODULE: Uninitialized Remap Clear Refusal
--- DESCRIPTION:
--- Retains the real malformed-settings owner, shared declaration and bulk scope
--- terminal while an uninitialized Clear All remains a refusal-only route.
--- Real owner identity and changing settings ports never grant runtime readiness.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")
local CORRUPT = "[karabiner\nenabled = true\n[tap_holds\nconfig = broken ]]\n"
local SHARED_OFF = '[karabiner]\nintegration_enabled = false\n'
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n'
local FUTURE = '[karabiner]\nruntime = "future-runtime"\nintegration_enabled = true\n'

--- Finds one independently named row in the actual native output.
--- @param row table|nil Rendered native row or provider parent.
--- @param title string Independently fixed caption key.
--- @return table|nil found Actual row.
local function find_row(row, title)
	if type(row) ~= "table" then return nil end
	if row.title == title or row.label == title then return row end
	for _, child in ipairs(row.menu or row.submenu or row.items or {}) do
		local found = find_row(child, title)
		if found then return found end
	end
end

--- Runs every observation inside the actual source owner's construction scope.
--- @param body function Receives actual owner, menu, controls and observations.
local function with_subject(body)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb")); assert(file:write(CORRUPT)); assert(file:close())
	local ok, detail = pcall(function()
		helpers.with_stub_scope({ "ui.menu.menu_tap_holds", "ui.menu.remap_switch", "infra.manifest_menu", "infra.paths" }, function()
			with_fixture(function(fixture)
				local remap, calls = fixture.load_enabled_remap({ real_user_config_path = path })
				helpers.assert_eq(calls.init_result, false)
				helpers.assert_eq(package.loaded["platform.remap"], remap)
				local observations = { errors = 0, successes = 0, starts = 0, scope_calls = 0, paths = 0, clocks = 0 }
				local originals = {}
				for _, name in ipairs({ "get_runtime", "shared_runtime_selected", "runtime_unavailable_reason", "apply_scope" }) do
					originals[name] = remap[name]
				end
				originals.parser_refusal_token = remap.parser_refusal_token
				local manager_hs = hs
				local manager_logger = package.loaded["infra.logger"]
				local manager_config = package.loaded["platform.remap.config"]
				local logger = {}
				for _, level in ipairs({ "debug", "done", "info", "trace", "warn" }) do logger[level] = function() end end
				logger.error = function() observations.errors = observations.errors + 1 end
				logger.success = function() observations.successes = observations.successes + 1 end
				logger.start = function()
					observations.starts = observations.starts + 1
					if observations.on_start then observations.on_start() end
				end
				package.loaded["infra.logger"] = logger
				local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds")
				local config_paths = require("infra.config_paths")
				local real_get, real_clock = config_paths.get, hs.timer.absoluteTime
				config_paths.get = function(...)
					observations.paths = observations.paths + 1
					if observations.on_path then observations.on_path() end
					return real_get(...)
				end
				hs.timer.absoluteTime = function(...)
					observations.clocks = observations.clocks + 1
					if observations.on_clock then observations.on_clock() end
					return real_clock(...)
				end
				local controls = {}
				function controls.build(owner)
					return menu.build({ karabiner = owner or remap, updateMenu = function() end })
				end
				function controls.clear()
					local row = find_row(controls.build(), "common.clear_to_system")
					helpers.assert_not_nil(row, "the actual uninitialized owner retains its declared Clear All refusal")
					local action = row.action or row.fn
					helpers.assert_type(action, "function")
					return action
				end
				function controls.read()
					local stream = assert(io.open(path, "rb")); local bytes = assert(stream:read("*a")); assert(stream:close()); return bytes
				end
				function controls.transition(bytes)
					local stream = assert(io.open(path, "wb")); assert(stream:write(bytes)); assert(stream:close())
					return remap.init({ expand_path = function(value) return value end })
				end
				function controls.foreign_init(boundary, during)
					local target, name
					if boundary == "logger" then target, name = manager_logger, "error"
					elseif boundary == "config" then target, name = require("adapters.file_system"), "read_with_status"
					else target, name = manager_hs.timer, "absoluteTime" end
					local original, armed = target[name], true
					target[name] = function(...)
						local result = table.pack(original(...))
						if armed then armed = false; during() end
						return table.unpack(result, 1, result.n)
					end
					local passed, result = pcall(function() return controls.transition(CORRUPT) end)
					target[name] = original
					helpers.assert_true(passed, tostring(result))
					helpers.assert_eq(armed, false, "the actual foreign callback was reached")
					return result
				end
				function controls.click(action)
					local hook, mask, count = debug.gethook()
					local operation = remap.apply_scope
					debug.sethook(function()
						if debug.getinfo(2, "f").func == operation then observations.scope_calls = observations.scope_calls + 1 end
					end, "c")
					local clicked, result = pcall(action)
					debug.sethook(hook, mask, count)
					helpers.assert_true(clicked, tostring(result))
					return result
				end
				local ran, error_detail = pcall(body, remap, controls, observations, calls)
				for name, value in pairs(originals) do remap[name] = value end
				package.loaded["platform.remap"] = remap
				config_paths.get, hs.timer.absoluteTime = real_get, real_clock
				if not ran then error(error_detail, 0) end
			end)
		end)
	end)
	os.remove(path); os.remove(path .. ".tmp")
	if not ok then error(detail, 0) end
end

--- Proves a retained clear reports refusal before entering a changed scope owner.
--- @param mutate function Changes the existing source or its current ports.
local function retained_refusal(mutate, expected_bytes)
	with_subject(function(remap, controls, observed, calls)
		local clear = controls.clear()
		mutate(remap, controls, observed)
		local before = controls.read()
		local saves, builds, starts = calls.save, calls.build, calls.start
		helpers.assert_eq(controls.click(clear), false)
		helpers.assert_eq(observed.scope_calls, 0, "changed owner must not receive a scope request")
		helpers.assert_true(observed.errors >= 1, "the refusal remains visible")
		helpers.assert_eq(observed.successes, 0)
		helpers.assert_eq(controls.read(), expected_bytes or before)
		helpers.assert_eq(calls.save, saves); helpers.assert_eq(calls.build, builds); helpers.assert_eq(calls.start, starts)
	end)
end

helpers.describe("actual uninitialized Clear All refusal admission", function()
	helpers.it("actual nil false nil owner reaches its real scope refusal without success or persistence", function()
		with_subject(function(remap, controls, observed, calls)
			helpers.assert_nil(remap.get_runtime()); helpers.assert_eq(remap.shared_runtime_selected(), false)
			helpers.assert_nil(remap.runtime_unavailable_reason())
			local clear = controls.clear()
			helpers.assert_eq(controls.click(clear), false)
			helpers.assert_eq(observed.scope_calls, 1, "the genuine published apply_scope was entered")
			helpers.assert_true(observed.errors >= 1); helpers.assert_eq(observed.successes, 0)
			helpers.assert_eq(controls.read(), CORRUPT)
			for _, name in ipairs({ "save", "build", "deploy", "execute", "lease_init", "start", "start_paused" }) do helpers.assert_eq(calls[name], 0, name) end
		end)
	end)
	helpers.it("a fake facade borrowing genuine nil tuple ports gains no command", function()
		with_subject(function(remap, controls)
			local facade = {}
			for _, name in ipairs({ "get_runtime", "shared_runtime_selected", "runtime_unavailable_reason", "apply_scope" }) do facade[name] = remap[name] end
			helpers.assert_nil(find_row(controls.build(facade), "common.clear_to_system"))
		end)
	end)
	for _, name in ipairs({ "get_runtime", "shared_runtime_selected", "runtime_unavailable_reason", "apply_scope" }) do
		helpers.it("missing " .. name .. " provides no uninitialized command", function()
			with_subject(function(remap, controls) remap[name] = nil; helpers.assert_nil(find_row(controls.build(), "common.clear_to_system")) end)
		end)
		helpers.it("retained clear refuses substituted " .. name, function()
			retained_refusal(function(remap)
				local original = remap[name]
				remap[name] = function(...) return original(...) end
			end)
		end)
	end
	helpers.it("retained clear refuses a replaced module publication", function()
		retained_refusal(function() package.loaded["platform.remap"] = {} end)
	end)
	for label, source in pairs({ shared = SHARED_OFF, owned = OWNED, future = FUTURE }) do
		helpers.it("retained clear refuses genuine " .. label .. " state publication", function()
			retained_refusal(function(_, controls) controls.transition(source) end)
		end)
	end
	helpers.it("a fresh menu after genuine future rejection has no Clear All callback", function()
		with_subject(function(_, controls)
			helpers.assert_eq(controls.transition(FUTURE), false)
			helpers.assert_nil(find_row(controls.build(), "common.clear_to_system"))
		end)
	end)
	for _, boundary in ipairs({ "on_path", "on_clock", "on_start" }) do
		helpers.it("foreign " .. boundary .. " cannot replace the operation before dispatch", function()
			retained_refusal(function(remap, _, observed)
				observed[boundary] = function() observed[boundary] = nil; remap.apply_scope = function() error("foreign operation must never run") end end
			end)
		end)
		helpers.it("foreign " .. boundary .. " cannot change real settings intent before dispatch", function()
			retained_refusal(function(_, controls, observed)
				observed[boundary] = function() observed[boundary] = nil; controls.transition(SHARED_OFF) end
			end, SHARED_OFF)
		end)
	end
	for _, name in ipairs({ "get_runtime", "shared_runtime_selected", "runtime_unavailable_reason" }) do
		helpers.it("throwing " .. name .. " creates no refusal command", function()
			with_subject(function(remap, controls) remap[name] = function() error("genuine fixed unreadable query") end; helpers.assert_nil(find_row(controls.build(), "common.clear_to_system")) end)
		end)
	end
	helpers.it("reader substitution during query creates no refusal command", function()
		with_subject(function(remap, controls)
			local original = remap.get_runtime
			local function unstable()
				remap.get_runtime = function() return unstable() end
				return original()
			end
			remap.get_runtime = unstable
			helpers.assert_nil(find_row(controls.build(), "common.clear_to_system"))
		end)
	end)
	for _, outcome in ipairs({ "accepted", "success-callback", "both", "late-success" }) do
		helpers.it("unexpected uninitialized " .. outcome .. " never publishes success", function()
			with_subject(function(remap, controls, observed)
				local callback
				remap.apply_scope = function(_, on_done)
					callback = on_done
					if outcome == "success-callback" or outcome == "both" then on_done(true, "unexpected", 1) end
					return outcome == "accepted" or outcome == "both"
				end
				local clear = controls.clear()
				helpers.assert_eq(controls.click(clear), false)
				if outcome == "late-success" then callback(true, "unexpected-late", 1) end
				helpers.assert_true(observed.errors >= 1); helpers.assert_eq(observed.successes, 0)
				helpers.assert_eq(controls.read(), CORRUPT)
			end)
		end)
	end
end)

helpers.describe("actual parser refusal token lifecycle", function()
	helpers.it("repeated malformed initialization replaces the receipt and invalidates its retained callback", function()
		with_subject(function(remap, controls, observed)
			local prior, clear = remap.parser_refusal_token(), controls.clear()
			helpers.assert_type(prior, "table")
			helpers.assert_eq(remap.parser_refusal_token(), prior)
			helpers.assert_eq(controls.transition(CORRUPT), false)
			local current = remap.parser_refusal_token()
			helpers.assert_type(current, "table"); helpers.assert_true(current ~= prior)
			helpers.assert_eq(controls.click(clear), false); helpers.assert_eq(observed.scope_calls, 0)
			helpers.assert_not_nil(find_row(controls.build(), "common.clear_to_system"))
			helpers.assert_eq(controls.read(), CORRUPT)
		end)
	end)
	for _, entry in ipairs({ "stop_lease", "teardown_local", "revoke", "shutdown", "stop" }) do
		helpers.it("actual " .. entry .. " invalidates the parser receipt before its result", function()
			retained_refusal(function(remap)
				helpers.assert_type(remap.parser_refusal_token(), "table")
				remap[entry]()
				helpers.assert_nil(remap.parser_refusal_token())
			end)
		end)
	end
	helpers.it("a genuinely refused local teardown still invalidates the parser receipt", function()
		with_subject(function(remap, controls, observed, calls)
			local clear = controls.clear()
			calls.lease_phase = "running"
			helpers.assert_eq(remap.teardown_local(), false)
			helpers.assert_nil(remap.parser_refusal_token())
			helpers.assert_eq(controls.click(clear), false); helpers.assert_eq(observed.scope_calls, 0)
			calls.lease_phase = "uninitialized"
		end)
	end)
	for _, boundary in ipairs({ "logger", "config", "clock" }) do
		for _, newer in ipairs({ "malformed", "future", "success", "stop" }) do
			helpers.it("foreign " .. boundary .. " newer " .. newer .. " cannot republish the older parser receipt", function()
				with_subject(function(remap, controls, observed)
					local prior, clear, inner = remap.parser_refusal_token(), controls.clear(), nil
					controls.foreign_init(boundary, function()
						if newer == "stop" then remap.stop()
						else controls.transition(newer == "malformed" and CORRUPT or newer == "future" and FUTURE or SHARED_OFF) end
						inner = remap.parser_refusal_token()
					end)
					if newer == "malformed" then helpers.assert_type(inner, "table"); helpers.assert_true(inner ~= prior)
					else helpers.assert_nil(inner) end
					helpers.assert_eq(remap.parser_refusal_token(), inner, "older callback must not replace the newer result")
					helpers.assert_eq(controls.click(clear), false); helpers.assert_eq(observed.scope_calls, 0)
					helpers.assert_eq(observed.successes, 0)
				end)
			end)
		end
	end
	for _, mode in ipairs({ "missing", "throwing", "substitution-during-query" }) do
		helpers.it("a " .. mode .. " parser query supplies no refusal command", function()
			with_subject(function(remap, controls)
				local original = remap.parser_refusal_token
				if mode == "missing" then remap.parser_refusal_token = nil
				elseif mode == "throwing" then remap.parser_refusal_token = function() error("fixed unreadable parser query") end
				else
					local function unstable() remap.parser_refusal_token = function() return unstable() end; return original() end
					remap.parser_refusal_token = unstable
				end
				helpers.assert_nil(find_row(controls.build(), "common.clear_to_system"))
			end)
		end)
	end
	helpers.it("a retained callback refuses a substituted parser query", function()
		retained_refusal(function(remap) local original = remap.parser_refusal_token; remap.parser_refusal_token = function() return original() end end)
	end)
	helpers.it("a fake publication borrowing every genuine query including the receipt gains no authority", function()
		with_subject(function(remap, controls)
			local facade = {}
			for _, name in ipairs({ "get_runtime", "shared_runtime_selected", "runtime_unavailable_reason", "apply_scope", "parser_refusal_token" }) do facade[name] = remap[name] end
			package.loaded["platform.remap"] = facade
			helpers.assert_nil(facade.parser_refusal_token(), "producer checks its own current published identity")
			helpers.assert_nil(find_row(controls.build(facade), "common.clear_to_system"))
			package.loaded["platform.remap"] = remap
			helpers.assert_type(remap.parser_refusal_token(), "table")
		end)
	end)
end)
return true
