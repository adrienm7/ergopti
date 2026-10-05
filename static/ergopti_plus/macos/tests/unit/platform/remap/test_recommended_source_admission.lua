--- tests/unit/platform/remap/test_recommended_source_admission.lua

--- ==============================================================================
--- MODULE: Recommendation Source Admission Ownership
--- DESCRIPTION:
--- Binds recommendation admission, backup and conditional publication to the
--- exact same native read, preserving personalized successor sources.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

helpers.describe("detached recommendation source admission", function()
	local function with_owned_publication(body)
		with_fixture(function(fixture)
			helpers.with_stub_scope({ "platform.remap.nav_layer", "platform.remap.scope_layer" }, function()
				local dir = os.tmpname():gsub("\\", "/")
				os.remove(dir)
				assert(fixture.HOST_MKDIR(dir))
				local path = dir .. "/layers.toml"
				local control = { blocked = true, target = path, unlocks = 0, closes = 0, writes = 0 }
				local original_open, original_rename = io.open, os.rename
				local held = {}
				io.open = function(name, mode)
					if name == control.target .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
						local handle = { close = function()
							control.closes = control.closes + 1
							local closed = not control.blocked
							if closed and type(control.after_close) == "function" then control.after_close() end
							return closed
						end }
						held[handle] = true
						return handle
					end
					return original_open(name, mode)
				end
				os.rename = function(old, new)
					if new == path then
						control.writes = control.writes + 1
						if control.refuse_rename then return nil, "controlled pre-publication refusal" end
						os.remove(new) -- POSIX replacement in stock Windows Lua fixtures.
					end
					return original_rename(old, new)
				end
				local fs = fixture.make_adapter(nil, nil, nil, nil, function() return true end, function(handle)
					if held[handle] then control.unlocks = control.unlocks + 1; return not control.blocked end
					return true
				end)
				local function seed(name, bytes)
					local file = assert(original_open(name, "w")); assert(file:write(bytes)); assert(file:close())
				end
				local called, detail = xpcall(function() body(path, fs, control, seed, fixture) end, debug.traceback)
				io.open, os.rename = original_open, original_rename
				for _, name in ipairs({ path, path .. ".backup", path .. fixture.WRITE_LOCK_SUFFIX,
					path .. ".backup" .. fixture.WRITE_LOCK_SUFFIX }) do os.remove(name) end
				fixture.HOST_RMDIR(dir)
				if not called then error(detail, 0) end
			end)
		end)
	end

	--- Constructs the actual native Config/FileSystem owners before remap init.
	--- @param body function Receives the uninitialized facade and real-file controls.
	local function with_startup_file(body)
		with_owned_publication(function(path, fs, control, seed)
			require("tests.support.remap_transaction_fixture")(function(fixture)
				local remap, calls = fixture.load_enabled_remap({ skip_init = true })
				calls.lease_phase = "uninitialized"
				local configured = package.loaded["platform.remap.config"]
				configured.load_tap_hold_keys = function() return { { id = "left_shift" }, { id = "tab" } } end
				package.loaded["infra.config_paths"].get = function() return path end
				local captured = require("adapters.file_system")
				for _, method in ipairs({ "read_with_status", "write_if_unchanged", "write", "remove_if_unchanged", "remove_exact" }) do
					captured[method] = fs[method]
				end
				package.loaded["adapters.file_system"] = fs
				package.loaded["platform.remap.config"] = nil
				local actual = helpers.load_with_stubs("platform.remap.config")
				local receipts = {}
				configured.load_user_config = actual.load_user_config
				configured.save_user_config = function(...)
					local saved, detail, record = actual.save_user_config(...)
					receipts[#receipts + 1] = { saved = saved, record = record }
					return saved, detail, record
				end
				package.loaded["platform.remap.config"] = configured
				local source = '# exact migration source\n[karabiner]\nintegration_enabled = false\n[tap_holds.config.tab]\ntap = "cmd_tab"\nhold = "none"\n'
				body(remap, calls, fs, control, seed, path, source, receipts, captured)
			end)
		end)
	end

	local neutral = "# exact admitted neutral source\n[custom]\nkeep = 19\n[karabiner]\nintegration_enabled = false\n"
	local personalized = neutral .. '[tap_holds.config.left_shift]\ntap = "paste"\nhold = "none"\n'

	--- Intercepts the actual loader's completed single read, forwarding its exact
	--- optional receipt unchanged while injecting the next source generation.
	--- @param change function|nil Called after the real admission returns.
	--- @param run function Receives actual facade, files, controls and request.
	local function with_recommendation(change, run)
		with_startup_file(function(remap, calls, fs, control, seed, path, _, receipts, captured)
			package.loaded["platform.remap.defaults"].tap_hold = { left_shift = { "escape", "none" } }
			control.blocked = false
			local configured = package.loaded["platform.remap.config"]
			local real_load = configured.load_user_config
			configured.load_user_config = function(...)
				local state, status, source = real_load(...)
				if change then change(path, seed, source, state, status) end
				return state, status, source
			end
			run(remap, calls, fs, control, seed, path, receipts,
				{ keys = { "left_shift" }, path = path, backup_path = path .. ".backup" }, configured, captured)
		end)
	end

	for _, absent in ipairs({ false, true }) do
		helpers.it("refuses personalized source after exact recommendation admission absent=" .. tostring(absent), function()
			with_recommendation(function(path, seed) seed(path, personalized) end,
				function(remap, calls, fs, control, seed, path, _, request)
					if not absent then seed(path, neutral) end
					helpers.assert_eq(remap.save_recommended_keys(request), false, "neutral source A cannot authorize overwriting personalized source B")
					helpers.assert_eq(fs.read_with_status(path), personalized)
					helpers.assert_eq(require("toml_codec").decode(fs.read_with_status(path)).tap_holds.config.left_shift.tap, "paste")
					local _, backup_status = fs.read_with_status(request.backup_path)
					helpers.assert_eq(backup_status, "absent", "a personalized successor is never backed up as recommendation authority")
					helpers.assert_eq(control.writes, 0)
					helpers.assert_eq(remap.has_pending_settings_save(), false)
					helpers.assert_eq(calls.lease_init, 0)
				end)
		end)
	end

	helpers.it("refuses deletion after an existing recommendation source was admitted", function()
		with_recommendation(function(path) assert(os.remove(path)) end,
			function(remap, _, fs, control, seed, path, _, request)
				seed(path, neutral)
				helpers.assert_eq(remap.save_recommended_keys(request), false)
				local _, status = fs.read_with_status(path)
				helpers.assert_eq(status, "absent", "a deleted source is not authority for an old parsed candidate")
				helpers.assert_eq(control.writes, 0)
			end)
	end)

	helpers.it("refuses an optional admission receipt for a different route", function()
		with_recommendation(function(_, _, source) if source then source.path = "another-route.toml" end end,
			function(remap, _, fs, control, seed, path, _, request)
				seed(path, neutral)
				helpers.assert_eq(remap.save_recommended_keys(request), false)
				helpers.assert_eq(fs.read_with_status(path), neutral)
				helpers.assert_eq(control.writes, 0)
			end)
	end)

	helpers.it("keeps the native publication fence when a personalized source arrives after backup", function()
		with_recommendation(nil, function(remap, _, fs, control, seed, path, _, request, _, captured)
			seed(path, neutral)
			local publish = fs.write_if_unchanged
			fs.write_if_unchanged = function(name, ...)
				local saved, detail, cleanup = publish(name, ...)
				if name == request.backup_path and saved == true then seed(path, personalized) end
				return saved, detail, cleanup
			end
			captured.write_if_unchanged = fs.write_if_unchanged
			helpers.assert_eq(remap.save_recommended_keys(request), false)
			helpers.assert_eq(fs.read_with_status(path), personalized)
			helpers.assert_eq(fs.read_with_status(request.backup_path), neutral)
			helpers.assert_eq(control.writes, 0)
			helpers.assert_eq(remap.has_pending_settings_save(), false)
		end)
	end)

	for _, absent in ipairs({ false, true }) do
		helpers.it("saves an unchanged actual same-read recommendation source absent=" .. tostring(absent), function()
			with_recommendation(nil, function(remap, _, fs, control, seed, path, _, request)
				if not absent then seed(path, neutral) end
				helpers.assert_eq(remap.save_recommended_keys(request), true)
				local model = require("toml_codec").decode(fs.read_with_status(path))
				helpers.assert_eq(model.tap_holds.config.left_shift.tap, "escape")
				helpers.assert_eq(model.tap_holds.enabled, true)
				if not absent then
					helpers.assert_eq(model.custom.keep, 19); helpers.assert_eq(model.karabiner.integration_enabled, false)
					helpers.assert_eq(fs.read_with_status(request.backup_path), neutral)
				end
				helpers.assert_eq(control.writes, 1)
			end)
		end)
	end

	helpers.it("retains matched-source native publication cleanup through existing detached recovery", function()
		with_recommendation(nil, function(remap, _, fs, control, seed, path, _, request)
			seed(path, neutral); control.blocked = true
			helpers.assert_eq(remap.save_recommended_keys(request), false)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			helpers.assert_eq(remap.retry_settings_recovery(), false)
			control.blocked = false
			helpers.assert_eq(remap.retry_settings_recovery(), true)
			helpers.assert_eq(fs.read_with_status(path), neutral)
			helpers.assert_eq(fs.read_with_status(request.backup_path), neutral)
		end)
	end)

	helpers.it("preserves the legacy two-return loader contract for an unchanged source", function()
		with_recommendation(nil, function(remap, _, fs, _, seed, path, _, request, configured)
			seed(path, neutral)
			local actual_load = configured.load_user_config
			configured.load_user_config = function(...)
				local state, status = actual_load(...)
				return state, status
			end
			helpers.assert_eq(remap.save_recommended_keys(request), true)
			helpers.assert_eq(require("toml_codec").decode(fs.read_with_status(path)).tap_holds.config.left_shift.tap, "escape")
		end)
	end)
end)
