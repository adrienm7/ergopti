--- tests/unit/adapters/file_system/test_cooperative_writer_lock_retained_admission.lua

--- ==============================================================================
--- MODULE: FileSystem Cooperative Writer Lock Regression
--- DESCRIPTION:
--- Preserves the filesystem transaction contract at its owning boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.adapters.file_system.cooperative_writer_lock_fixture"] = nil
local Fixture = require("tests.support.adapters.file_system.cooperative_writer_lock_fixture")
local with_fixture = Fixture.with_fixture





helpers.describe("conditional publication retained admission", function()
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

	for _, prepublication in ipairs({ false, true }) do
		helpers.it("retains a failed real layer import after publication=" .. tostring(not prepublication), function()
			with_owned_publication(function(path, fs, control, seed)
				control.refuse_rename = prepublication
				local nav = require("platform.remap.nav_layer")
				package.loaded["platform.remap.nav_layer"] = {
					import_recommended = function() return nav.import_recommended({
						shared_root = helpers.shared(), config_dir = path:match("^(.*)/[^/]+$"), file_adapter = fs,
					}) end,
					undo_import = nav.undo_import, reconcile_wheel = function() end,
				}
				local sibling = require("platform.remap.scope_layer").import()
				helpers.assert_eq(sibling.prepare(), false, "no success before native release")
				helpers.assert_eq(sibling.receipt(), nil, "failed preparation issues no successful public capability")
				helpers.assert_eq(sibling.restore(), false, "no-record and absence shortcuts cannot settle debt")
				helpers.assert_eq(sibling.prepare(), false, "a retained private import cannot be replaced")
				local bytes, status = fs.read_with_status(path)
				helpers.assert_eq(status, prepublication and "absent" or "ok")
				if not prepublication then helpers.assert_true(#bytes > 0) end
				if prepublication then seed(path, "foreign successor") end
				control.blocked = false
				helpers.assert_eq(sibling.restore(), true, "the exact native cleanup remains retryable")
				local current, restored = fs.read_with_status(path)
				helpers.assert_eq(restored, prepublication and "ok" or "absent")
				if prepublication then helpers.assert_eq(current, "foreign successor") end
				local group, acquired = fs.acquire_write_locks({ path })
				helpers.assert_eq(acquired, true, "release frees the original canonical owner")
				helpers.assert_eq(fs.release_write_locks(group), true)
				helpers.assert_eq(control.writes, 1, "cleanup never retries publication")
			end)
		end)
	end

	for _, source_present in ipairs({ false, true }) do
		helpers.it("retains actual generic scope publication with source_present=" .. tostring(source_present), function()
			with_owned_publication(function(path, fs, control, seed)
				local source = "[custom]\nvalue = 0\n"
				if source_present then seed(path, source) end
				local runtime = 0
				local owner = require("config_scope_transaction").new({ path = path, backup_path = path .. ".backup",
					files = fs, manifest = { scope_plan = function() return { presets = {},
						operations = { { section = "custom", key = "value", value = 1 } } } end },
					capture = function() return { value = runtime } end,
					apply = function() runtime = 1; return true end,
					restore = function(snapshot) runtime = snapshot.value; return true end,
				})
				helpers.assert_eq(owner.apply("custom", "recommended"), false)
				helpers.assert_eq(owner.pending(), true, "false publication cannot settle a changed file")
				helpers.assert_eq(runtime, 1, "native release precedes runtime compensation")
				helpers.assert_eq(owner.retry_restore(), false)
				control.blocked = false
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(owner.pending(), false)
				helpers.assert_eq(runtime, 0)
				local bytes, status = fs.read_with_status(path)
				helpers.assert_eq(status, source_present and "ok" or "absent")
				if source_present then helpers.assert_eq(bytes, source) end
			end)
		end)
	end

	helpers.it("keeps a refused backup's data while retaining its exact native release", function()
		with_owned_publication(function(path, fs, control, seed)
			local source = "[custom]\nvalue = 0\n"
			seed(path, source)
			control.target = path .. ".backup"
			local runtime = 0
			local owner = require("config_scope_transaction").new({ path = path, backup_path = path .. ".backup",
				files = fs, manifest = { scope_plan = function() return { presets = {},
					operations = { { section = "custom", key = "value", value = 1 } } } end },
				capture = function() return {} end, apply = function() runtime = 1; return true end,
				restore = function() runtime = 0; return true end,
			})
			helpers.assert_eq(owner.apply("custom", "recommended"), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(runtime, 0, "backup refusal precedes runtime mutation")
			control.blocked = false
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(fs.read_with_status(path), source)
			helpers.assert_eq(fs.read_with_status(path .. ".backup"), source, "recovery never deletes backup data")
		end)
	end)

	helpers.it("retains an inverse publication and verifies it without replacing an external successor", function()
		with_owned_publication(function(path, fs, control, seed)
			local source = "[custom]\nvalue = 0\n"
			seed(path, source); control.blocked = false
			local owner = require("config_scope_transaction").new({ path = path, backup_path = path .. ".backup",
				files = fs, manifest = { scope_plan = function() return { presets = {},
					operations = { { section = "custom", key = "value", value = 1 } } } end },
				capture = function() return {} end, apply = function() return true end, restore = function() return true end,
			})
			helpers.assert_eq(owner.apply("custom", "recommended"), true)
			control.blocked = true
			helpers.assert_eq(owner.revert(), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(fs.read_with_status(path), source)
			seed(path, "external successor")
			control.blocked = false
			local writes = control.writes
			helpers.assert_eq(owner.retry_restore(), false, "native release alone does not verify the inverse target")
			helpers.assert_eq(owner.retry_restore(), false)
			helpers.assert_eq(fs.read_with_status(path), "external successor")
			helpers.assert_eq(control.writes, writes, "a published inverse is never republished on retry")
			seed(path, source)
			helpers.assert_eq(owner.retry_restore(), true)
		end)
	end)

	helpers.it("makes a settled native publication capability harmless to a later lock owner", function()
		with_owned_publication(function(path, fs, control)
			local written, _, cleanup = fs.write_if_unchanged(path, "owned bytes", { status = "absent" })
			helpers.assert_eq(written, false); helpers.assert_eq(type(cleanup), "function")
			control.blocked = false
			local settled, _, published = cleanup()
			helpers.assert_eq(settled, true); helpers.assert_eq(published, true)
			local group, acquired = fs.acquire_write_locks({ path })
			helpers.assert_eq(acquired, true)
			local unlocks, closes = control.unlocks, control.closes
			helpers.assert_eq(cleanup(), true)
			helpers.assert_eq(control.unlocks, unlocks)
			helpers.assert_eq(control.closes, closes, "duplicate cleanup cannot release a successor")
			helpers.assert_eq(fs.release_write_locks(group), true)
		end)
	end)
	for _, phase in ipairs({ "backup", "publication", "inverse" }) do
		helpers.it("retains actual secondary-file " .. phase .. " publication cleanup", function()
			with_owned_publication(function(path, fs, control, seed)
				local source = "[custom]\nvalue = 0\n"
				seed(path, source)
				local secondary = require("config_scope_file").new({ path = path, backup_path = path .. ".backup",
					files = fs, remove = fs.remove_exact })
				helpers.assert_eq(secondary.prepare({ { section = "custom", key = "value", value = 1 } }), true)
				if phase == "backup" then
					control.target = path .. ".backup"
					helpers.assert_eq(secondary.backup(), false)
				else
					if phase == "inverse" then control.blocked = false end
					helpers.assert_eq(secondary.publish(), phase == "inverse")
					control.blocked = true
				end
				helpers.assert_eq(secondary.restore(), false, "native debt precedes no-effect shortcuts")
				helpers.assert_eq(secondary.pending(), true)
				control.blocked = false
				helpers.assert_eq(secondary.restore(), true)
				helpers.assert_eq(secondary.pending(), false)
				helpers.assert_eq(fs.read_with_status(path), source)
				if phase == "backup" then helpers.assert_eq(fs.read_with_status(path .. ".backup"), source) end
			end)
		end)
	end

	helpers.it("retains only its pre-publication staging and writer cleanup identities", function()
		with_owned_publication(function(path, fs, control)
			control.refuse_rename = true
			local original_remove, stage_blocked = os.remove, true
			os.remove = function(name)
				if name:sub(-#"/payload") == "/payload" and stage_blocked then return nil, "private stage removal refused" end
				return original_remove(name)
			end
			local called, detail = xpcall(function()
				local written, _, cleanup = fs.write_if_unchanged(path, "candidate", { status = "absent" })
				helpers.assert_eq(written, false); helpers.assert_eq(type(cleanup), "function")
				helpers.assert_eq(cleanup(), false)
				control.blocked = false
				helpers.assert_eq(cleanup(), false, "freeing the writer does not discard private staging debt")
				stage_blocked = false
				local settled, _, published = cleanup()
				helpers.assert_eq(settled, true); helpers.assert_eq(published, false)
				local _, status = fs.read_with_status(path)
				helpers.assert_eq(status, "absent", "cleanup never retries refused publication")
			end, debug.traceback)
			os.remove = original_remove
			if not called then error(detail, 0) end
		end)
	end)

	helpers.it("retains the cohort inverse's restoration publication before acknowledging its target", function()
		with_owned_publication(function(path, fs, control, seed)
			control.blocked = false
			local nav = require("platform.remap.nav_layer")
			package.loaded["platform.remap.nav_layer"] = {
				import_recommended = function() return nav.import_recommended({
					shared_root = helpers.shared(), config_dir = path:match("^(.*)/[^/]+$"), file_adapter = fs,
				}) end,
				undo_import = nav.undo_import, reconcile_wheel = function() end,
			}
			local cohort = require("platform.remap.scope_layer")
			local sibling = cohort.import()
			helpers.assert_eq(sibling.prepare(), true); sibling.settled(true)
			local bytes = fs.read_with_status(path)
			local inverse = assert(cohort.inverse(sibling.receipt()))
			helpers.assert_eq(inverse.prepare(), true)
			control.blocked = true
			helpers.assert_eq(inverse.restore(), false)
			helpers.assert_eq(inverse.restore(), false, "published restoration still owes the same native cleanup")
			seed(path, "external successor"); control.blocked = false
			helpers.assert_eq(inverse.restore(), false, "release does not verify a changed restoration target")
			helpers.assert_eq(inverse.restore(), false)
			helpers.assert_eq(fs.read_with_status(path), "external successor")
			seed(path, bytes)
			helpers.assert_eq(inverse.restore(), true)
			helpers.assert_eq(control.writes, 2, "inverse restoration is published only once")
		end)
	end)

	--- Runs the actual Config and bulk facade against this native file owner.
	--- Lifecycle and fcntl receipts remain controlled; the source and staging I/O
	--- are real, and no dummy writer supplies the publication/effect capability.
	local function with_native_remap(path, fs, control, seed, body)
		require("tests.support.remap_transaction_fixture")(function(fixture)
			local remap, calls = fixture.load_enabled_remap()
			local configured = package.loaded["platform.remap.config"]
			configured.build_default_state = function()
				return { tap_holds_enabled = false, tap_hold_config = { left_shift = { tap = "none", hold = "none" } },
					mod_combos_config = {}, tap_hold_timeout_ms = 200, sticky_timeout_ms = 1000,
					simultaneous_threshold_ms = 50, combo_symmetric = false }
			end
			package.loaded["infra.config_paths"].get = function() return path end
			local captured_files = require("adapters.file_system")
			for _, method in ipairs({ "read_with_status", "write_if_unchanged", "write", "remove_if_unchanged", "remove_exact" }) do
				captured_files[method] = fs[method]
			end
			package.loaded["adapters.file_system"] = fs
			package.loaded["platform.remap.config"] = nil
			local actual = helpers.load_with_stubs("platform.remap.config")
			configured.save_user_config = actual.save_user_config
			package.loaded["platform.remap.config"] = configured
			seed(path, "[custom]\nkeep = 17\n")
			control.blocked = false
			helpers.assert_eq(remap.set_tap_action("left_shift", "escape"), true)
			local source = assert(fs.read_with_status(path))
			control.blocked, control.writes = true, 0
			local driver = { regenerations = 0, terminals = {} }
			remap.regenerate = function(callback)
				driver.regenerations = driver.regenerations + 1
				driver.terminals[#driver.terminals + 1] = callback
				return true
			end
			body(remap, source, driver, calls)
		end)
	end

	for _, source_present in ipairs({ false, true }) do
		helpers.it("retains actual remap publication debt with source_present=" .. tostring(source_present), function()
			with_owned_publication(function(path, fs, control, seed)
				with_native_remap(path, fs, control, seed, function(remap, source, driver)
					if not source_present then assert(os.remove(path)) end
					local completed = 0
					local accepted = remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" },
						function(ok) helpers.assert_eq(ok, false); completed = completed + 1 end)
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(remap.settings_pending(), true, "published native refusal retains the final bulk owner")
					helpers.assert_eq(remap.get_tap_action("left_shift"), "escape", "false publication never adopts live settings")
					helpers.assert_eq(driver.regenerations, 0)
					helpers.assert_eq(control.writes, 1)
					helpers.assert_eq(remap.retry_settings_recovery(), false)
					helpers.assert_eq(remap.set_tap_action("left_shift", "paste"), false, "a sibling cannot replace release debt")
					helpers.assert_eq(control.writes, 1)
					control.blocked = false
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(remap.settings_pending(), false)
					local bytes, status = fs.read_with_status(path)
					helpers.assert_eq(status, source_present and "ok" or "absent")
					if source_present then helpers.assert_eq(bytes, source); helpers.assert_eq(fs.read_with_status(path .. ".backup"), source) end
					helpers.assert_eq(completed, 1, "the original failure callback is never repeated")
					local writes, unlocks = control.writes, control.unlocks
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(control.writes, writes); helpers.assert_eq(control.unlocks, unlocks)
				end)
			end)
		end)
	end

	helpers.it("keeps a foreign successor after a proven no-effect remap refusal", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				control.refuse_rename = true
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				helpers.assert_eq(remap.settings_pending(), true, "unchanged-source shortcuts still owe native release")
				seed(path, "foreign successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), true)
				helpers.assert_eq(fs.read_with_status(path), "foreign successor")
				helpers.assert_eq(control.writes, 1, "no-effect acknowledgement never republishes an inverse")
			end)
		end)
	end)

	helpers.it("retains a refused remap backup's native cleanup without deleting its data", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap, source, driver)
				control.target = path .. ".backup"
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_eq(fs.read_with_status(path), source)
				helpers.assert_eq(fs.read_with_status(path .. ".backup"), source)
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), true)
				helpers.assert_eq(remap.settings_pending(), false)
				helpers.assert_eq(fs.read_with_status(path .. ".backup"), source, "verified backup data is retained")
				helpers.assert_eq(control.writes, 0); helpers.assert_eq(driver.regenerations, 0)
			end)
		end)
	end)

	helpers.it("keeps a changed forward source pending after native remap cleanup settles", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				local candidate = assert(fs.read_with_status(path))
				seed(path, "foreign successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(fs.read_with_status(path), "foreign successor")
				helpers.assert_eq(control.writes, 1, "a later writer's bytes are never replaced")
				seed(path, candidate)
				helpers.assert_eq(remap.retry_settings_recovery(), true)
			end)
		end)
	end)

	helpers.it("verifies the actual remap inverse after its retained native release without republishing", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap, source, driver)
				control.blocked = false
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), true)
				helpers.assert_eq(remap.get_tap_action("left_shift"), "none")
				control.blocked = true
				driver.terminals[1](false, "controlled-deploy-failure")
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_eq(fs.read_with_status(path), source, "the refused inverse really published its source")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "none", "runtime compensation waits for native release")
				seed(path, "foreign successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(fs.read_with_status(path), "foreign successor")
				helpers.assert_eq(control.writes, 2, "an already published inverse is never repeated")
				seed(path, source)
				helpers.assert_eq(remap.retry_settings_recovery(), false, "exact inverse regeneration still owns its terminal")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
				helpers.assert_eq(driver.regenerations, 2)
				driver.terminals[2](true, "ready")
				helpers.assert_eq(remap.settings_pending(), false)
			end)
		end)
	end)

	helpers.it("retains a created remap inverse after unlink and verifies absence after native release", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				assert(os.remove(path))
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				control.blocked = false
				control.after_close = function() control.blocked = true; control.after_close = nil end
				helpers.assert_eq(remap.retry_settings_recovery(), false, "the created source was removed but inverse native release remains owed")
				local _, status = fs.read_with_status(path)
				helpers.assert_eq(status, "absent")
				seed(path, "foreign successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), false, "an exact unlink receipt does not prove current absence")
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(fs.read_with_status(path), "foreign successor")
				assert(os.remove(path))
				helpers.assert_eq(remap.retry_settings_recovery(), true)
				helpers.assert_eq(remap.settings_pending(), false)
				helpers.assert_eq(control.writes, 1)
			end)
		end)
	end)

	helpers.it("retains explicit remap repair publication and restores its exact corrupt source", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				local corrupt = "[tap_holds\nrecoverable = true\n"
				seed(path, corrupt)
				helpers.assert_eq(remap.reset_to_defaults(), false)
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_true(fs.read_with_status(path) ~= corrupt, "explicit repair really published before native release refused")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), true)
				helpers.assert_eq(fs.read_with_status(path), corrupt, "raw corrupt bytes are restored without requiring a decode")
				helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
			end)
		end)
	end)

	helpers.it("retains immediate remap unlink identity when its released source has an exact-byte successor", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap)
				assert(os.remove(path))
				helpers.assert_eq(remap.apply_scope({ scope = "tap_holds", mode = "clear", backup_path = path .. ".backup" }), false)
				local candidate = assert(fs.read_with_status(path))
				local original_remove, inverse_phase, unlinks, closes = os.remove, false, 0, 0
				os.remove = function(name)
					if inverse_phase and name == path then unlinks = unlinks + 1 end
					return original_remove(name)
				end
				local called, detail = xpcall(function()
					control.blocked = false
					control.after_close = function()
						closes = closes + 1
						if closes == 1 then inverse_phase = true end
						if closes == 2 then seed(path, candidate); control.after_close = nil end
					end
					helpers.assert_eq(remap.retry_settings_recovery(), false, "immediate unlink acknowledgement must verify the Config inverse target")
					helpers.assert_eq(remap.settings_pending(), true)
					helpers.assert_eq(fs.read_with_status(path), candidate)
					helpers.assert_eq(unlinks, 1, "the original inverse really unlinked its exact source")
					helpers.assert_eq(remap.retry_settings_recovery(), false)
					helpers.assert_eq(unlinks, 1, "an acknowledged inverse cannot unlink a same-byte successor")
					helpers.assert_eq(fs.read_with_status(path), candidate)
					assert(original_remove(path))
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(remap.settings_pending(), false)
				end, debug.traceback)
				os.remove = original_remove
				if not called then error(detail, 0) end
			end)
		end)
	end)

	for _, source_present in ipairs({ false, true }) do
		helpers.it("retains refused scalar setter publication with source_present=" .. tostring(source_present), function()
			with_owned_publication(function(path, fs, control, seed)
				with_native_remap(path, fs, control, seed, function(remap, source, driver)
					if not source_present then assert(os.remove(path)) end
					helpers.assert_eq(remap.set_tap_action("left_shift", "paste"), false)
					helpers.assert_eq(remap.settings_pending(), true, "the failed scalar setter retains its actual file effect")
					helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
					helpers.assert_eq(remap.retry_settings_recovery(), false)
					helpers.assert_eq(remap.set_hold_action("left_shift", "shift"), false)
					helpers.assert_eq(control.writes, 1)
					control.blocked = false
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					local bytes, status = fs.read_with_status(path)
					helpers.assert_eq(status, source_present and "ok" or "absent")
					if source_present then helpers.assert_eq(bytes, source) end
					helpers.assert_eq(remap.get_tap_action("left_shift"), "escape")
					helpers.assert_eq(driver.regenerations, 0, "a refused setter never adopted or deployed its candidate")
				end)
			end)
		end)
	end

	helpers.it("does not replace a successor when a scalar setter's inverse release settles", function()
		with_owned_publication(function(path, fs, control, seed)
			with_native_remap(path, fs, control, seed, function(remap, source)
				helpers.assert_eq(remap.set_tap_action("left_shift", "paste"), false)
				control.blocked = false
				control.after_close = function() control.blocked = true; control.after_close = nil end
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(fs.read_with_status(path), source)
				seed(path, "foreign setter successor")
				control.blocked = false
				helpers.assert_eq(remap.retry_settings_recovery(), false)
				helpers.assert_eq(remap.settings_pending(), true)
				helpers.assert_eq(remap.set_tap_action("left_shift", "copy"), false)
				helpers.assert_eq(fs.read_with_status(path), "foreign setter successor")
				helpers.assert_eq(control.writes, 2, "inverse cleanup cannot republish an already restored source")
				seed(path, source)
				helpers.assert_eq(remap.retry_settings_recovery(), true)
			end)
		end)
	end)

	--- Uses the actual serializer and classified file port before the remap
	--- facade has any runtime state. Only its lifecycle/data/fcntl ports are controlled.
	local function with_native_detached(path, fs, control, seed, body)
		require("tests.support.remap_transaction_fixture")(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ skip_init = true })
			local configured = package.loaded["platform.remap.config"]
			configured.build_default_state = function()
				return { tap_holds_enabled = false, tap_hold_config = { left_shift = { tap = "none", hold = "none" } },
					mod_combos_config = {}, tap_hold_timeout_ms = 200, sticky_timeout_ms = 1000,
					simultaneous_threshold_ms = 50, combo_symmetric = false }
			end
			package.loaded["platform.remap.defaults"].tap_hold = { left_shift = { "escape", "none" } }
			package.loaded["infra.config_paths"].get = function() return path end
			local captured_files = require("adapters.file_system")
			for _, method in ipairs({ "read_with_status", "write_if_unchanged", "write", "remove_if_unchanged", "remove_exact" }) do
				captured_files[method] = fs[method]
			end
			package.loaded["adapters.file_system"] = fs
			package.loaded["platform.remap.config"] = nil
			local actual = helpers.load_with_stubs("platform.remap.config")
			configured.save_user_config, configured.load_user_config = actual.save_user_config, actual.load_user_config
			package.loaded["platform.remap.config"] = configured
			body(remap, calls)
		end)
	end

	for _, phase in ipairs({ "created", "replaced", "backup", "no-effect" }) do
		helpers.it("retains detached wizard " .. phase .. " native publication debt before init", function()
			with_owned_publication(function(path, fs, control, seed)
				with_native_detached(path, fs, control, seed, function(remap, calls)
					local source = "[custom]\nkeep = 19\n[karabiner]\nintegration_enabled = false\n"
					if phase ~= "created" then seed(path, source) end
					if phase == "backup" then control.target = path .. ".backup" end
					if phase == "no-effect" then control.refuse_rename = true end
					local request = { keys = { "left_shift" }, path = path, backup_path = path .. ".backup" }
					helpers.assert_eq(remap.save_recommended_keys(request), false)
					helpers.assert_eq(remap.has_pending_settings_save(), true, "a detached refusal retains its private owner")
					helpers.assert_eq(remap.is_running(), false)
					helpers.assert_eq(remap.retry_settings_recovery(), false)
					helpers.assert_eq(remap.save_recommended_keys(request), false)
					helpers.assert_eq(remap.init({ expand_path = function(value) return value end }), false, "init cannot adopt unacknowledged file bytes")
					helpers.assert_eq(calls.lease_init, 0)
					if phase == "no-effect" then seed(path, "foreign detached successor") end
					control.blocked = false
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(remap.settings_pending(), false)
					local bytes, status = fs.read_with_status(path)
					helpers.assert_eq(status, phase == "created" and "absent" or "ok")
					if phase ~= "created" then
						helpers.assert_eq(bytes, phase == "no-effect" and "foreign detached successor" or source)
						helpers.assert_eq(fs.read_with_status(path .. ".backup"), source, "verified wizard backup data survives cleanup")
					end
					local writes, unlocks = control.writes, control.unlocks
					helpers.assert_eq(remap.retry_settings_recovery(), true)
					helpers.assert_eq(control.writes, writes); helpers.assert_eq(control.unlocks, unlocks)
				end)
			end)
		end)
	end

end)
