--- tests/unit/platform/remap/test_startup_publication_owner.lua

--- ==============================================================================
--- MODULE: Startup Configuration Publication Ownership
--- DESCRIPTION:
--- Holds startup writer cleanup before runtime admission, without undoing or
--- repeating already published defaults or migration bytes.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

helpers.describe("startup configuration conditional publication ownership", function()
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
				body(remap, calls, fs, control, seed, path, source, receipts)
			end)
		end)
	end

	for _, migration in ipairs({ false, true }) do
		for _, published in ipairs({ false, true }) do
			helpers.it("retains startup cleanup before init migration=" .. tostring(migration) .. " published=" .. tostring(published), function()
				with_startup_file(function(remap, calls, fs, control, seed, path, source, receipts)
					if migration then seed(path, source) end
					control.refuse_rename = not published
					local port = { expand_path = function(value) return value end }
					helpers.assert_eq(remap.init(port), false, "unacknowledged startup publication is not an initialized bridge")
					helpers.assert_eq(calls.lease_init, 0, "no native lease/runtime is constructed before startup file acknowledgement")
					helpers.assert_eq(calls.input_source_watchers, 0)
					helpers.assert_eq(remap.is_running(), false)
					helpers.assert_eq(remap.has_pending_settings_save(), true)
					local cleanup = assert(receipts[1].record.publication_cleanup)
					local candidate = receipts[1].record.candidate
					local bytes, status = fs.read_with_status(path)
					helpers.assert_eq(status, (migration or published) and "ok" or "absent")
					if published then helpers.assert_eq(bytes, candidate) elseif migration then helpers.assert_eq(bytes, source) end
					helpers.assert_eq(remap.init(port), false, "same facade cannot replace a retained startup writer")
					helpers.assert_eq(remap.set_tap_action("left_shift", "escape"), false)
					helpers.assert_eq(remap.retry_settings_recovery(), false)
					helpers.assert_eq(control.writes, 1)
					control.blocked = false
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(remap.has_pending_settings_save(), false)
					local after, after_status = fs.read_with_status(path)
					helpers.assert_eq(after_status, status); helpers.assert_eq(after, bytes, "cleanup never resets or republishes startup data")
					helpers.assert_eq(control.writes, 1)
					local group, acquired = fs.acquire_write_locks({ path })
					helpers.assert_eq(acquired, true)
					local unlocks, closes = control.unlocks, control.closes
					helpers.assert_eq(cleanup(), true)
					helpers.assert_eq(control.unlocks, unlocks); helpers.assert_eq(control.closes, closes, "old cleanup cannot release its successor")
					helpers.assert_eq(fs.release_write_locks(group), true)
					control.refuse_rename = false
					helpers.assert_eq(remap.init(port), true, "fresh admission reads the acknowledged source rather than reusing a partial runtime")
					helpers.assert_eq(calls.lease_init, 1)
					helpers.assert_eq(control.writes, published and 1 or 2)
				end)
			end)
		end

		helpers.it("preserves a foreign successor while settling startup cleanup migration=" .. tostring(migration), function()
			with_startup_file(function(remap, calls, fs, control, seed, path, source)
				if migration then seed(path, source) end
				helpers.assert_eq(remap.init({ expand_path = function(value) return value end }), false)
				seed(path, '[karabiner]\nintegration_enabled = \"foreign invalid consent\"\n')
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), true)
				helpers.assert_eq(fs.read_with_status(path), '[karabiner]\nintegration_enabled = \"foreign invalid consent\"\n')
				helpers.assert_eq(control.writes, 1)
				helpers.assert_eq(remap.init({ expand_path = function(value) return value end }), false, "a later unsafe source is refused on fresh admission")
				helpers.assert_eq(calls.lease_init, 0)
			end)
		end)
	end

	helpers.it("keeps startup cleanup owned through real facade lifecycle refusal and retry", function()
		with_startup_file(function(remap, calls, fs, control, _, path, _, receipts)
			helpers.assert_eq(remap.init({ expand_path = function(value) return value end }), false)
			local candidate = receipts[1].record.candidate
			helpers.assert_eq(remap.teardown_local(), false)
			local refused = 0
			helpers.assert_eq(remap.revoke("startup-failure", function(ok) helpers.assert_eq(ok, false); refused = refused + 1 end), false)
			helpers.assert_eq(refused, 1)
			helpers.assert_eq(calls.stop, 0, "no uninitialized native lease is falsely stopped to forget file debt")
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			control.blocked = false
			helpers.assert_eq(remap.teardown_local(), true)
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(fs.read_with_status(path), candidate)
			helpers.assert_eq(control.writes, 1)
			helpers.assert_eq(calls.lease_init, 0)
		end)
	end)
end)
