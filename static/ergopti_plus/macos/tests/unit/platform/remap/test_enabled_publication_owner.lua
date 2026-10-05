--- tests/unit/platform/remap/test_enabled_publication_owner.lua

--- ==============================================================================
--- MODULE: Enabled Preference Publication Ownership
--- DESCRIPTION:
--- Keeps exact enabled preference bytes and conditional native cleanup owned
--- through failed activation, disable recovery and lifecycle supersession.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

helpers.describe("enabled preference conditional publication ownership", function()
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

	--- Runs actual Config and FileSystem publication over private real files.
	--- Native lock, release and lifecycle ports remain controlled fixtures.
	--- @param initially_enabled boolean Initial runtime consent.
	--- @param source_present boolean Whether the private source exists.
	--- @param body function Receives owner, effects, native controls and exact source.
	local function with_enabled_file(initially_enabled, source_present, body)
		with_owned_publication(function(path, fs, control, seed)
			require("tests.support.remap_transaction_fixture")(function(fixture)
				local remap, calls = fixture.load_enabled_remap({ initially_enabled = initially_enabled })
				local configured = package.loaded["platform.remap.config"]
				package.loaded["infra.config_paths"].get = function() return path end
				local captured = require("adapters.file_system")
				for _, method in ipairs({ "read_with_status", "write_if_unchanged", "write", "remove_if_unchanged", "remove_exact" }) do
					captured[method] = fs[method]
				end
				package.loaded["adapters.file_system"] = fs
				package.loaded["platform.remap.config"] = nil
				local actual = helpers.load_with_stubs("platform.remap.config")
				local receipts = {}
				configured.save_user_config = function(...)
					local saved, detail, receipt = actual.save_user_config(...)
					receipts[#receipts + 1] = { saved = saved, receipt = receipt }
					return saved, detail, receipt
				end
				package.loaded["platform.remap.config"] = configured
				local source = "# exact original comment\n[karabiner]\nintegration_enabled = "
					.. tostring(initially_enabled) .. "\n\n[custom]\nkeep = 17\n"
				if source_present then seed(path, source) end
				body(remap, calls, fs, control, seed, path, source, receipts, configured, actual)
			end)
		end)
	end

	for _, source_present in ipairs({ false, true }) do
		helpers.it("owns failed enable publication with original source present=" .. tostring(source_present), function()
			with_enabled_file(false, source_present, function(remap, calls, fs, control, _, path, source, receipts)
				local callbacks = 0
				helpers.assert_eq(remap.set_enabled(true, function(ok) helpers.assert_eq(ok, false); callbacks = callbacks + 1 end), true)
				calls.deliver_ready()
				helpers.assert_eq(remap.get_enabled(), false)
				helpers.assert_eq(calls.resume_prepared or 0, 0)
				helpers.assert_eq(type(receipts[1].receipt.publication_cleanup), "function")
				helpers.assert_eq(remap.has_pending_settings_save(), true)
				calls.finish_stop(true)
				helpers.assert_eq(remap.has_pending_settings_save(), true, "STOPPED cannot erase native publication debt")
				helpers.assert_eq(callbacks, 0)
				helpers.assert_eq(fs.read_with_status(path), receipts[1].receipt.candidate)
				helpers.assert_eq(remap.set_enabled(false), false, "the original enable owner refuses the opposite request")
				helpers.assert_eq(remap.set_enabled(true), true)
				helpers.assert_eq(control.writes, 1)
				control.blocked = false
				helpers.assert_eq(remap.set_enabled(true), true, "same-target retry joins the original failure")
				local bytes, status = fs.read_with_status(path)
				helpers.assert_eq(status, source_present and "ok" or "absent")
				if source_present then helpers.assert_eq(bytes, source) end
				helpers.assert_eq(callbacks, 1)
				helpers.assert_eq(remap.has_pending_settings_save(), false)
				helpers.assert_eq(remap.get_enabled(), false)
			end)
		end)
	end

	helpers.it("settles no-effect enable cleanup while preserving a foreign successor", function()
		with_enabled_file(false, true, function(remap, calls, fs, control, seed, path)
			control.refuse_rename = true
			local result
			remap.set_enabled(true, function(ok) result = ok end)
			calls.deliver_ready(); calls.finish_stop(true)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			seed(path, "foreign successor")
			control.blocked = false
			remap.set_enabled(true)
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(result, false)
			helpers.assert_eq(fs.read_with_status(path), "foreign successor")
			helpers.assert_eq(control.writes, 1, "no-effect cleanup never writes an inverse")
		end)
	end)

	helpers.it("keeps a changed failed enable candidate owned without overwriting its successor", function()
		with_enabled_file(false, true, function(remap, calls, fs, control, seed, path, source, receipts)
			remap.set_enabled(true)
			calls.deliver_ready(); calls.finish_stop(true)
			local candidate = receipts[1].receipt.candidate
			seed(path, "foreign successor")
			control.blocked = false
			remap.set_enabled(true)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			helpers.assert_eq(fs.read_with_status(path), "foreign successor")
			helpers.assert_eq(control.writes, 1)
			seed(path, candidate)
			remap.set_enabled(true)
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(fs.read_with_status(path), source)
			helpers.assert_eq(control.writes, 2)
		end)
	end)

	helpers.it("inverts the original ON receipt after RESUME fails and retains inverse release", function()
		with_enabled_file(false, true, function(remap, calls, fs, control, seed, path, source, receipts)
			control.blocked = false
			local callbacks = 0
			remap.set_enabled(true, function(ok) helpers.assert_eq(ok, false); callbacks = callbacks + 1 end)
			calls.deliver_ready()
			helpers.assert_eq(remap.get_enabled(), true)
			control.blocked = true
			calls.deliver_resumed(false)
			helpers.assert_eq(remap.get_enabled(), false)
			helpers.assert_eq(#receipts, 1, "the owned forward receipt replaces a newly serialized OFF compensation")
			helpers.assert_eq(control.writes, 1, "the exact inverse waits for STOPPED")
			calls.finish_stop(true)
			helpers.assert_eq(control.writes, 2)
			helpers.assert_eq(fs.read_with_status(path), source)
			helpers.assert_eq(callbacks, 0)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			remap.set_enabled(true)
			helpers.assert_eq(control.writes, 2)
			seed(path, "foreign successor")
			control.blocked = false
			remap.set_enabled(true)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			helpers.assert_eq(fs.read_with_status(path), "foreign successor")
			helpers.assert_eq(control.writes, 2, "an already published inverse is never repeated")
			seed(path, source)
			remap.set_enabled(true)
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(callbacks, 1)
			helpers.assert_eq(fs.read_with_status(path), source)
		end)
	end)

	helpers.it("restores failed disable publication before requesting its fresh READY lease", function()
		with_enabled_file(true, true, function(remap, calls, fs, control, _, path, source)
			local callbacks = 0
			remap.set_enabled(false, function(ok) helpers.assert_eq(ok, false); callbacks = callbacks + 1 end)
			calls.finish_stop(true)
			helpers.assert_eq(calls.start_paused, 0, "held config publication cannot start recovery")
			helpers.assert_eq(remap.get_enabled(), true)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			helpers.assert_eq(callbacks, 0)
			remap.set_enabled(false)
			helpers.assert_eq(control.writes, 1)
			control.blocked = false
			remap.set_enabled(false)
			helpers.assert_eq(fs.read_with_status(path), source)
			helpers.assert_eq(calls.start_paused, 1)
			helpers.assert_eq(remap.has_pending_settings_save(), true, "the original disable still owns READY")
			calls.deliver_ready(); calls.deliver_resumed()
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(callbacks, 1)
			helpers.assert_eq(remap.get_enabled(), true)
			helpers.assert_eq(fs.read_with_status(path), source)
		end)
	end)

	helpers.it("retains original disable ownership after inverse publication and READY refusals", function()
		with_enabled_file(true, true, function(remap, calls, fs, control, _, path, source)
			local result
			remap.set_enabled(false, function(ok) result = ok end)
			calls.finish_stop(true)
			control.blocked = false
			control.after_close = function() control.blocked = true; control.after_close = nil end
			remap.set_enabled(false)
			helpers.assert_eq(fs.read_with_status(path), source)
			helpers.assert_eq(calls.start_paused, 0, "refused inverse release precedes READY")
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			control.blocked = false
			remap.set_enabled(false)
			helpers.assert_eq(calls.start_paused, 1)
			calls.deliver_ready(false)
			helpers.assert_eq(remap.has_pending_settings_save(), true, "failed READY cannot release the file-owned original transition")
			helpers.assert_nil(result)
			remap.set_enabled(false)
			helpers.assert_eq(calls.start_paused, 1, "failed READY requires its exact STOPPED before replacement")
			calls.finish_stop(true)
			helpers.assert_eq(calls.start_paused, 2)
			calls.deliver_ready(); calls.deliver_resumed()
			helpers.assert_eq(result, false)
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(control.writes, 2)
		end)
	end)

	helpers.it("joins lifecycle fencing before restoring committed enable consent", function()
		with_enabled_file(false, true, function(remap, calls, fs, control, _, path, source)
			control.blocked = false
			local callbacks = 0
			remap.set_enabled(true, function(ok) helpers.assert_eq(ok, false); callbacks = callbacks + 1 end)
			calls.deliver_ready()
			control.blocked = true
			local revoke_result
			helpers.assert_eq(remap.revoke("owned-test", function(ok) revoke_result = ok end), false)
			helpers.assert_eq(revoke_result, false)
			helpers.assert_eq(callbacks, 0)
			helpers.assert_eq(control.writes, 1)
			calls.finish_stop(true)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			helpers.assert_eq(fs.read_with_status(path), source)
			helpers.assert_eq(remap.teardown_local(), false, "local lifecycle cannot retire unresolved inverse cleanup")
			control.blocked = false
			helpers.assert_eq(remap.revoke("owned-test", function(ok) revoke_result = ok end), true)
			helpers.assert_eq(callbacks, 1)
			calls.finish_stop(true)
			helpers.assert_eq(revoke_result, true)
			helpers.assert_eq(remap.teardown_local(), true)
			helpers.assert_eq(fs.read_with_status(path), source)
			helpers.assert_eq(control.writes, 2)
		end)
	end)

	helpers.it("fences failed-disable recovery on lifecycle supersession and ignores stale READY", function()
		with_enabled_file(true, true, function(remap, calls, fs, control, _, path, source)
			local callbacks = 0
			remap.set_enabled(false, function(ok) helpers.assert_eq(ok, false); callbacks = callbacks + 1 end)
			calls.finish_stop(true)
			control.blocked = false
			remap.set_enabled(false)
			local stale_ready = calls.start_paused_callback
			helpers.assert_eq(type(stale_ready), "function")
			helpers.assert_eq(remap.revoke("owned-test"), false)
			helpers.assert_eq(callbacks, 0)
			calls.finish_stop(true)
			helpers.assert_eq(callbacks, 1)
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(fs.read_with_status(path), source)
			local resumes = calls.resume_prepared or 0
			stale_ready(true, "old-ready")
			helpers.assert_eq(calls.resume_prepared or 0, resumes, "a cancelled old context cannot resume after STOPPED")
			helpers.assert_eq(callbacks, 1)
			helpers.assert_eq(remap.revoke("owned-test"), true)
			calls.finish_stop(true)
			helpers.assert_eq(remap.teardown_local(), true)
			helpers.assert_eq(remap.get_enabled(), true, "lifecycle teardown preserves original enabled consent")
		end)
	end)

	for _, published in ipairs({ false, true }) do
		helpers.it("keeps mixed-port OFF compensation as target publication with effect=" .. tostring(published), function()
			with_enabled_file(false, true, function(remap, calls, fs, control, _, path, _, _, configured, actual)
				control.blocked = false
				local first = true
				configured.save_user_config = function(...)
					local saved, detail, receipt = actual.save_user_config(...)
					if first then first = false; return saved, detail end
					return saved, detail, receipt
				end
				local result
				remap.set_enabled(true, function(ok) result = ok end)
				calls.deliver_ready()
				control.blocked = true
				control.refuse_rename = not published
				calls.deliver_resumed(false)
				calls.finish_stop(true)
				helpers.assert_eq(remap.has_pending_settings_save(), true)
				helpers.assert_nil(result)
				control.blocked, control.refuse_rename = false, false
				remap.set_enabled(true)
				helpers.assert_eq(remap.has_pending_settings_save(), false)
				helpers.assert_eq(result, false)
				local codec = require("toml_codec")
				local document = assert(codec.decode(assert(fs.read_with_status(path))))
				helpers.assert_eq(document.karabiner.integration_enabled, false,
					"the compensating receipt's ON source is never restored")
				helpers.assert_eq(remap.get_enabled(), false)
			end)
		end)
	end

	helpers.it("exposes cap recovery without changing legacy bulk pending meaning", function()
		with_enabled_file(false, true, function(remap, calls, fs, control, _, path, source)
			local callbacks = 0
			remap.set_enabled(true, function(ok) helpers.assert_eq(ok, false); callbacks = callbacks + 1 end)
			calls.deliver_ready(); calls.finish_stop(true)
			helpers.assert_eq(remap.settings_pending(), false, "enabled ownership does not redefine the bulk predicate")
			helpers.assert_eq(remap.retry_settings_recovery(), false)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			control.blocked = false
			helpers.assert_eq(remap.retry_settings_recovery(), true)
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(fs.read_with_status(path), source)
			helpers.assert_eq(callbacks, 1)
		end)
	end)

	helpers.it("retains file-owned STOPPED refusal and ignores old stop callbacks across retries", function()
		with_enabled_file(false, true, function(remap, calls, fs, control, _, path, source)
			local callbacks = 0
			remap.set_enabled(true, function(ok) helpers.assert_eq(ok, false); callbacks = callbacks + 1 end)
			calls.deliver_ready()
			local stale_stop = calls.stop_callbacks[#calls.stop_callbacks]
			helpers.assert_eq(type(stale_stop), "function")
			calls.finish_stop(false)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			helpers.assert_eq(callbacks, 0)
			control.blocked = false
			helpers.assert_eq(remap.retry_settings_recovery(), false)
			helpers.assert_eq(control.writes, 1, "a refused exact fence precedes the file inverse")
			stale_stop(true, "late-old-stop")
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			calls.finish_stop(true)
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(callbacks, 1)
			helpers.assert_eq(fs.read_with_status(path), source)
			remap.set_enabled(true)
			helpers.assert_eq(remap.has_pending_settings_save(), true)
			stale_stop(true, "late-retired-stop")
			helpers.assert_eq(remap.has_pending_settings_save(), true, "an old descriptor cannot retire its successor")
			helpers.assert_eq(callbacks, 1)
			calls.deliver_ready(); calls.deliver_resumed()
			helpers.assert_eq(remap.has_pending_settings_save(), false)
			helpers.assert_eq(remap.get_enabled(), true)
		end)
	end)
end)
