--- tests/unit/ui/menu/test_runtime_unavailable_menu_admission.lua

--- ==============================================================================
--- MODULE: Unsupported Native Runtime Admission
--- DESCRIPTION:
--- Fixed real configuration files preserve consent while unavailable runtime
--- intent refuses shared effects. Portable native ports prove admission only.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'
local OWNED_OFF = '[karabiner]\nruntime = "owned"\nintegration_enabled = false\n[future]\nrevision = 29\n'
local SHARED = '[karabiner]\nintegration_enabled = true\n[future]\nrevision = 29\n'
local SHARED_OFF = '[karabiner]\nintegration_enabled = false\n[future]\nrevision = 29\n'

--- Loads the real A3 reader before an observable native owner is constructed.
--- @param source string Fixed original configuration bytes.
--- @param body function Receives facade, effects, lease port and source reader.
local function with_source(source, body, declaration)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
	local declaration_path
	if declaration then
		declaration_path = os.tmpname()
		local stream = assert(io.open(declaration_path, "wb")); assert(stream:write(declaration)); assert(stream:close())
	end
	local ok, err = pcall(function()
		helpers.with_stub_scope({ "infra.paths", "platform.remap.scope_layer" }, function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ skip_init = true, real_user_config_path = path })
			local declaration_paths, original_shared
			calls.declaration_resolves = 0
			if declaration_path then
				-- The fixture captured the real reader before replacing its public
				-- facade. Bind that reader's actual path port, not a later stub.
				local function captured(fn, expected)
					for index = 1, 20 do
						local name, value = debug.getupvalue(fn, index)
						if name == expected then return value end
					end
					error("the genuine reader port was not found: " .. expected, 0)
				end
				local reader = captured(require("platform.remap.config").load_user_config, "RealConfig")
				declaration_paths = captured(captured(reader.load_user_config, "runtime_setting"), "Paths")
				original_shared = declaration_paths.shared
				declaration_paths.shared = function(relative)
					if relative == "platform/remap/runtime_setting.json" then
						calls.declaration_resolves = calls.declaration_resolves + 1
						return declaration_path
					end
					return original_shared(relative)
				end
			end
			local lease = require("platform.remap.lease_controller")
			local status = lease.status
			lease.is_initialized = function() return calls.lease_init > 0 end
			lease.status = function()
				if calls.lease_init == 0 then return "uninitialized", { phase = "uninitialized" } end
				return status()
			end
			calls.expand, calls.scope_imports = 0, 0
			package.loaded["platform.remap.scope_layer"] = { import = function()
				calls.scope_imports = calls.scope_imports + 1
				return nil
			end }
			local initialized = remap.init({ expand_path = function(value)
				calls.expand = calls.expand + 1
				return value
			end })
			local function read()
				local stream = assert(io.open(path, "rb"))
				local bytes = assert(stream:read("*a")); assert(stream:close()); return bytes
			end
			local body_ok, body_err = pcall(body, remap, calls, lease, read, initialized, path)
			if declaration_paths then declaration_paths.shared = original_shared end
			if not body_ok then error(body_err, 0) end
		end)
		end)
	end)
	if declaration_path then os.remove(declaration_path) end
	os.remove(path)
	if not ok then error(err, 0) end
end

--- Checks every observable acquisition and persistent shared effect stays absent.
--- @param calls table Recorded actual facade effects under native ports.
local function no_shared_effects(calls)
	for _, name in ipairs({ "lease_init", "expand", "start", "start_paused", "build", "deploy",
		"execute", "save", "lease_bound_starts", "input_source_watchers", "wizard_runs", "scope_imports" }) do
		helpers.assert_eq(calls[name], 0, name .. " must remain unacquired")
	end
	helpers.assert_eq(#calls.rule_removals, 0)
	helpers.assert_eq(#calls.legacy_removals, 0)
	helpers.assert_eq(#calls.first_run_timers, 0)
end

--- Retains an existing settings owner with a genuinely nonterminal phase.
--- @param remap table Actual manager with its existing debt introspector.
local function hold_settings(remap)
	for index = 1, 20 do
		local name = debug.getupvalue(remap.settings_pending, index)
		if name == "_bulk_settings_transaction" then
			debug.setupvalue(remap.settings_pending, index, { label = "Fixed held candidate", phase = "candidate-persistence" })
			helpers.assert_true(remap.settings_pending())
			return
		end
	end
	error("the genuine existing settings owner was not found", 0)
end

--- Searches actual tray row output without deriving expected captions from it.
--- @param rows table Rendered native rows.
--- @param title string Fixed expected locale key.
local function find_row(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local nested = find_row(row.menu or row.submenu, title)
		if nested then return nested end
	end
end

--- Verifies unavailable provider output has no native edit callback at any depth.
--- @param rows table Actual rendered native rows.
local function inert_rows(rows)
	for _, row in ipairs(rows or {}) do
		helpers.assert_nil(row.fn, "unavailable intent exposes no executing row")
		helpers.assert_nil(row.action, "unavailable intent exposes no provider action")
		if row.menu or row.submenu then inert_rows(row.menu or row.submenu) end
	end
end

--- Runs menu callbacks inside their genuine configuration/native-owner lifetime.
--- @param body function Receives the real owner and scoped effects.
local function menu_source(bytes, body)
	return with_source(bytes, function(remap, calls, lease, read)
		helpers.with_stub_scope({ "ui.menu.remap_switch", "ui.menu.builder", "ui.menu.menu_tap_holds" }, function()
			body(remap, calls, lease, read)
		end)
	end)
end

helpers.describe("read-only unavailable runtime menu admission", function()
	for _, bytes in ipairs({ OWNED, OWNED_OFF }) do
		for _, section in ipairs({ "tap", "combinations" }) do
			helpers.it("owned consent " .. tostring(bytes == OWNED) .. " has inert " .. section .. " runtime explanation", function()
				menu_source(bytes, function(remap, calls, _, read)
					local foreign = 0
					for _, name in ipairs({ "guardian_state", "legacy_rule_conflicts", "open_login_items", "open_guardian_settings" }) do
						local original = remap[name]
						remap[name] = function(...) foreign = foreign + 1; return original(...) end
					end
					local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds")
					local ctx = { karabiner = remap, updateMenu = function() end }
					local built = section == "tap" and menu.build(ctx) or menu.build_key_combinations(ctx)
					local rows = section == "tap" and built.submenu or built
					helpers.assert_true(find_row(rows, "menu.global.karabiner_runtime.owned") ~= nil)
					helpers.assert_true(find_row(rows, "menu.global.karabiner_runtime_unavailable") ~= nil)
					inert_rows(rows)
					helpers.assert_eq(foreign, 0, "runtime refusal precedes guardian and legacy callbacks")
					helpers.assert_eq(read(), bytes)
					no_shared_effects(calls)
				end)
			end)
		end
	end
	for _, bytes in ipairs({ OWNED, SHARED }) do
		helpers.it("Configuration displays genuine " .. (bytes == OWNED and "owned" or "shared") .. " intent", function()
			menu_source(bytes, function(remap, calls, _, read)
				local builder = helpers.load_with_stubs("ui.menu.builder")
				local actions = setmetatable({}, { __index = function() return function() return false end end })
				local menu = builder.generate({ config = { log_level = 2 }, karabiner = remap }, {}, actions)
				local cfg = assert(find_row(menu, "menu.configuration.title"), "Configuration must reach actual tray")
				local key = bytes == OWNED and "menu.global.karabiner_runtime.owned" or "menu.global.karabiner_runtime.shared"
				helpers.assert_true(find_row(cfg.menu, key) ~= nil, "genuine intent reaches Configuration")
				if bytes == OWNED then
					helpers.assert_true(find_row(cfg.menu, "menu.global.karabiner_runtime_unavailable") ~= nil)
					for _, row in ipairs(cfg.menu) do
						if row.title:find("menu.global.karabiner_integration", 1, true)
							or row.title:find("menu.global.remove_from_karabiner", 1, true) then
							helpers.assert_true(row.disabled == true)
							helpers.assert_nil(row.fn)
						end
					end
				end
				helpers.assert_eq(read(), bytes)
			end)
		end)
	end
	for _, command in ipairs({ "toggle", "remove" }) do
		helpers.it("owned direct " .. command .. " refuses before the actual remap callback", function()
			menu_source(OWNED, function(remap)
				local method = command == "toggle" and "set_enabled" or "remove_from_karabiner"
				local original, invoked = remap[method], 0
				remap[method] = function(...) invoked = invoked + 1; return original(...) end
				local switch = helpers.load_with_stubs("ui.menu.remap_switch")
				helpers.assert_eq(switch[command](remap), false)
				helpers.assert_eq(invoked, 0)
			end)
		end)
	end
	for _, invalid in ipairs({ "missing", "throws", "wrong-type" }) do
		helpers.it("refuses a " .. invalid .. " native runtime predicate instead of inferring shared", function()
			menu_source(SHARED, function(remap)
				local invoked = 0
				remap.remove_from_karabiner = function() invoked = invoked + 1; return true end
				if invalid == "missing" then remap.shared_runtime_selected = nil
				elseif invalid == "throws" then remap.shared_runtime_selected = function() error("fixed unreadable selector") end
				else remap.shared_runtime_selected = function() return "shared" end end
				local switch = helpers.load_with_stubs("ui.menu.remap_switch")
				helpers.assert_eq(switch.remove(remap), false)
				helpers.assert_eq(invoked, 0)
			end)
		end)
	end
	helpers.it("captured Configuration remove callback rechecks actual runtime intent", function()
		menu_source(SHARED, function(remap)
			local invoked = 0
			remap.remove_from_karabiner = function() invoked = invoked + 1; return true end
			local switch = helpers.load_with_stubs("ui.menu.remap_switch")
			local commands = switch.rows(remap)
			remap.get_runtime = function() return "owned" end
			remap.shared_runtime_selected = function() return false end
			remap.runtime_unavailable_reason = function() return "runtime-unavailable" end
			helpers.assert_eq(commands.remove_from_karabiner(), false)
			helpers.assert_eq(invoked, 0)
		end)
	end)
end)
return true
