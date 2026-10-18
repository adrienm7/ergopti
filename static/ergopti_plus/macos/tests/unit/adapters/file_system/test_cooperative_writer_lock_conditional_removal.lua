--- tests/unit/adapters/file_system/test_cooperative_writer_lock_conditional_removal.lua

--- ==============================================================================
--- MODULE: FileSystem Cooperative Writer Lock Regression
--- DESCRIPTION:
--- Preserves the filesystem transaction contract at its owning boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.adapters.file_system.cooperative_writer_lock_fixture"] = nil
local Fixture = require("tests.support.adapters.file_system.cooperative_writer_lock_fixture")
local with_fixture = Fixture.with_fixture





helpers.describe("adapters.file_system: conditional removal ownership", function()
	local function with_owned_file(callback)
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local original_remove = os.remove
			local original_open = io.open
			local seed = assert(original_open(path, "w"))
			assert(seed:write("owned preset")); assert(seed:close())
			local call_ok, detail = xpcall(function() callback(fixture, path) end, debug.traceback)
			os.remove = original_remove
			io.open = original_open
			original_remove(path)
			original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			if not call_ok then error(detail, 0) end
		end)
	end

	local function writer()
		return require("toml_codec.writer")
	end

	local function expected()
		return { status = "ok", content = "owned preset" }
	end

	helpers.it("holds the canonical writer mutex around exact unlink and releases it", function()
		with_owned_file(function(fixture, path)
			local held, locks, unlocks, unlinks = false, 0, 0, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				held, locks = true, locks + 1; return true
			end, function() held, unlocks = false, unlocks + 1; return true end)
			local original_remove = os.remove
			os.remove = function(target)
				if target == path then
					helpers.assert_eq(held, true, "the source check and unlink must share publication ownership")
					unlinks = unlinks + 1
				end
				return original_remove(target)
			end
			helpers.assert_eq(writer().remove_if_unchanged(path, adapter, expected()), true)
			helpers.assert_eq(locks, 1); helpers.assert_eq(unlocks, 1)
			helpers.assert_eq(unlinks, 1); helpers.assert_eq(held, false)
			helpers.assert_eq(adapter.read_with_status(path), nil)
			local lock_file = assert(io.open(path .. fixture.WRITE_LOCK_SUFFIX, "r"))
			assert(lock_file:close())
		end)
	end)

	helpers.it("rejects a cooperating replacement inside the final read/unlink gap", function()
		with_owned_file(function(fixture, path)
			local owner, contender_calls, contender_written = nil, 0, nil
			local function lock_api(name)
				return function()
					if name == "writer" then contender_calls = contender_calls + 1 end
					if owner ~= nil then return false, "native lease already held" end
					owner = name; return true
				end, function() helpers.assert_eq(owner, name); owner = nil; return true end
			end
			local lock_remove, unlock_remove = lock_api("remover")
			local lock_write, unlock_write = lock_api("writer")
			local remover = fixture.make_adapter(nil, nil, nil, nil, lock_remove, unlock_remove)
			local competitor = fixture.make_adapter(nil, nil, nil, nil, lock_write, unlock_write)
			local original_remove = os.remove
			os.remove = function(target)
				if target == path then contender_written = competitor.write(path, "replacement") end
				return original_remove(target)
			end
			helpers.assert_eq(writer().remove_if_unchanged(path, remover, expected()), true)
			helpers.assert_eq(contender_calls, 1, "the second native owner must actually contest the lease")
			helpers.assert_eq(contender_written, false, "replacement must not enter the protected unlink gap")
			helpers.assert_eq(owner, nil)
		end)
	end)

	helpers.it("rejects removal through an alias while a canonical writer owns its mutex", function()
		with_owned_file(function(fixture, path)
			local adapter = fixture.make_adapter()
			local group, acquired = adapter.acquire_write_locks({ path })
			helpers.assert_eq(acquired, true)
			local parent, basename = fixture.split_parent(path)
			local removed = writer().remove_if_unchanged(parent .. "/./" .. basename, adapter, expected())
			local released = adapter.release_write_locks(group)
			helpers.assert_eq(removed, false)
			helpers.assert_eq(released, true)
			helpers.assert_eq(adapter.read_with_status(path), "owned preset")
		end)
	end)

	helpers.it("rechecks changed bytes after acquiring its canonical native mutex", function()
		with_owned_file(function(fixture, path)
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				local file = assert(io.open(path, "w")); assert(file:write("new cooperator bytes")); assert(file:close())
				return true
			end)
			helpers.assert_eq(writer().remove_if_unchanged(path, adapter, expected()), false)
			helpers.assert_eq(adapter.read_with_status(path), "new cooperator bytes")
		end)
	end)

	helpers.it("refuses a route retargeted while acquiring its old target mutex", function()
		with_owned_file(function(fixture, path)
			local alias = path .. "-link"
			local routes = { [alias] = path }
			local adapter = fixture.make_adapter(routes, nil, nil, nil, function()
				routes[alias] = path .. "-foreign"; return true
			end)
			helpers.assert_eq(writer().remove_if_unchanged(alias, adapter, expected()), false)
			helpers.assert_eq(adapter.read_with_status(path), "owned preset")
		end)
	end)

	for _, refusal in ipairs({ "false", "nil", "truthy", "throw" }) do
		helpers.it("retains original bytes on native unlink " .. refusal .. " refusal", function()
			with_owned_file(function(fixture, path)
				local unlocks = 0
				local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function()
					unlocks = unlocks + 1; return true
				end)
				local original_remove = os.remove
				os.remove = function(target)
					if target ~= path then return original_remove(target) end
					if refusal == "throw" then error("native unlink exception") end
					if refusal == "nil" then return nil, "native refusal" end
					if refusal == "truthy" then return "true" end
					return false, "native refusal"
				end
				local removed, detail = writer().remove_if_unchanged(path, adapter, expected())
				helpers.assert_eq(removed, false)
				helpers.assert_true(type(detail) == "string" and detail ~= "")
				helpers.assert_eq(unlocks, 1)
				helpers.assert_eq(adapter.read_with_status(path), "owned preset")
			end)
		end)
	end

	for _, after_unlink in ipairs({ "absent", "foreign" }) do
		helpers.it("retains release debt before the " .. after_unlink .. " layer shortcut", function()
			with_owned_file(function(fixture, path)
				local blocked, lock_calls, unlinks = true, 0, 0
				local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
					lock_calls = lock_calls + 1; return true
				end, function()
					if blocked then return false, "unlock refused" end
					return true
				end)
				local original_open, original_remove = io.open, os.remove
				io.open = function(target, mode)
					if target == path .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
						return { close = function() return not blocked end }
					end
					return original_open(target, mode)
				end
				os.remove = function(target)
					if target == path then unlinks = unlinks + 1 end
					return original_remove(target)
				end
				local preset = require("keymap.layer_preset")
				local record = { status = preset.IMPORTED, path = path, content = "owned preset" }
				helpers.assert_eq(preset.undo(record, adapter), false)
				helpers.assert_eq(type(record.removal_cleanup), "function")
				if after_unlink == "foreign" then
					local file = assert(original_open(path, "w")); assert(file:write("foreign bytes")); assert(file:close())
				end
				helpers.assert_eq(preset.undo(record, adapter), false,
					"absence or changed bytes cannot acknowledge a retained native lease")
				helpers.assert_eq(adapter.write(path, "new request"), false,
					"the authoritative process registry must continue fencing same-path writers")
				helpers.assert_eq(lock_calls, 1)
				blocked = false
				helpers.assert_eq(preset.undo(record, adapter), true)
				helpers.assert_eq(record.removal_cleanup, nil)
				helpers.assert_eq(unlinks, 1, "release retry must never unlink a successor")
				if after_unlink == "foreign" then helpers.assert_eq(adapter.read_with_status(path), "foreign bytes") end
			end)
		end)
	end

	helpers.it("keeps a refused removal retryable once the native owner releases", function()
		with_owned_file(function(fixture, path)
			local blocked, attempts = true, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function() return not blocked end)
			local original_open, original_remove = io.open, os.remove
			io.open = function(target, mode)
				if target == path .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
					return { close = function() return not blocked end }
				end
				return original_open(target, mode)
			end
			os.remove = function(target)
				if target == path then
					attempts = attempts + 1
					if attempts == 1 then return false, "unlink refused" end
				end
				return original_remove(target)
			end
			local preset = require("keymap.layer_preset")
			local record = { status = preset.IMPORTED, path = path, content = "owned preset" }
			helpers.assert_eq(preset.undo(record, adapter), false)
			blocked = false
			helpers.assert_eq(preset.undo(record, adapter), true)
			helpers.assert_eq(attempts, 2)
		end)
	end)
end)

helpers.describe("conditional removal composed scope", function()
	helpers.it("retains the real native cleanup owner in the actual configuration inverse", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local backup = path .. "-backup"
			os.remove(path); os.remove(backup)
			local blocked, restores, unlinks = false, 0, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function() return not blocked end)
			local original_open, original_remove = io.open, os.remove
			io.open = function(target, mode)
				if target == path .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
					return { close = function() return not blocked end }
				end
				return original_open(target, mode)
			end
			os.remove = function(target)
				if target == path then unlinks = unlinks + 1 end
				return original_remove(target)
			end
			local call_ok, detail = xpcall(function()
				local owner = require("config_scope_transaction").new({
					path = path, backup_path = backup, files = adapter,
					manifest = { scope_plan = function() return {
						presets = {}, operations = { { section = "scope", key = "enabled", value = true } },
					} end },
					capture = function() return {} end,
					apply = function() return true end,
					restore = function() restores = restores + 1; return true end,
				})
				helpers.assert_eq(owner.apply("scope", "recommended"), true)
				blocked = true
				helpers.assert_eq(owner.revert(), false)
				helpers.assert_eq(owner.pending(), true)
				helpers.assert_eq(owner.retry_restore(), false)
				helpers.assert_eq(owner.apply("scope", "clear"), false)
				local successor = assert(original_open(path, "w"))
				assert(successor:write("successor bytes")); assert(successor:close())
				blocked = false
				helpers.assert_eq(owner.retry_restore(), true)
				helpers.assert_eq(owner.pending(), false)
				helpers.assert_eq(unlinks, 1, "the exact retained cleanup cannot unlink a successor")
				helpers.assert_eq(restores, 1)
				helpers.assert_eq(adapter.read_with_status(path), "successor bytes")
			end, debug.traceback)
			io.open, os.remove = original_open, original_remove
			original_remove(path); original_remove(backup)
			original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			original_remove(backup .. fixture.WRITE_LOCK_SUFFIX)
			if not call_ok then error(detail, 0) end
		end)
	end)
end)

helpers.describe("navigation-layer cohort native release debt", function()
	for _, phase in ipairs({ "prepare", "restore", "no_effect_restore" }) do
		helpers.it("settles the exact release before cohort " .. phase .. " acknowledgement", function()
			with_fixture(function(fixture)
				helpers.with_stub_scope({ "platform.remap.nav_layer", "platform.remap.scope_layer" }, function()
					local path = os.tmpname():gsub("\\", "/")
					local file = assert(io.open(path, "w")); assert(file:write("owned preset")); assert(file:close())
					local blocked, unlinks = true, 0
					local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function() return not blocked end)
					local original_open, original_remove = io.open, os.remove
					io.open = function(target, mode)
						if target == path .. fixture.WRITE_LOCK_SUFFIX and mode == "a+" then
							return { close = function() return not blocked end }
						end
						return original_open(target, mode)
					end
					os.remove = function(target)
						if target == path then
							unlinks = unlinks + 1
							if phase == "no_effect_restore" then return false, "unlink refused without effect" end
						end
						return original_remove(target)
					end
					local call_ok, detail = xpcall(function()
						local preset = require("keymap.layer_preset")
						package.loaded["platform.remap.nav_layer"] = {
							import_recommended = function() return {
								status = preset.IMPORTED, path = path, content = "owned preset",
							} end,
							undo_import = preset.undo, reconcile_wheel = function() end,
						}
						package.loaded["platform.remap.scope_layer"] = nil
						local cohort = require("platform.remap.scope_layer")
						local imported = cohort.import()
						helpers.assert_eq(imported.prepare(), true); imported.settled(true)
						local inverse = assert(cohort.inverse(imported.receipt()))
						helpers.assert_eq(inverse.prepare(), false)
						if phase == "prepare" then
							helpers.assert_eq(inverse.prepare(), false, "absence cannot discard a retained release")
							blocked = false
							helpers.assert_eq(inverse.prepare(), true)
							helpers.assert_eq(inverse.restore(), true,
								"a later refusal still owes the removal effect retained across prepare retries")
							helpers.assert_eq(adapter.read_with_status(path), "owned preset")
						else
							helpers.assert_eq(inverse.restore(), false, "compensation must settle the old unlink lease first")
							blocked = false
							helpers.assert_eq(inverse.restore(), true)
							helpers.assert_eq(adapter.read_with_status(path), "owned preset")
						end
						helpers.assert_eq(unlinks, 1)
					end, debug.traceback)
					io.open, os.remove = original_open, original_remove
					original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
					if not call_ok then error(detail, 0) end
				end)
			end)
		end)
	end
end)

helpers.describe("conditional removal classified read refusal", function()
	helpers.it("keeps unreadable bytes and releases the lease without unlinking", function()
		with_fixture(function(fixture)
			local path = os.tmpname():gsub("\\", "/")
			local file = assert(io.open(path, "w")); assert(file:write("owned preset")); assert(file:close())
			local locks, unlocks, unlinks = 0, 0, 0
			local adapter = fixture.make_adapter(nil, nil, nil, nil, function()
				locks = locks + 1; return true
			end, function() unlocks = unlocks + 1; return true end)
			local original_open, original_remove = io.open, os.remove
			io.open = function(target, mode)
				if target == path and mode == "r" then return nil, "controlled read refusal" end
				return original_open(target, mode)
			end
			os.remove = function(target)
				if target == path then unlinks = unlinks + 1 end
				return original_remove(target)
			end
			local call_ok, removed, detail = pcall(require("toml_codec.writer").remove_if_unchanged,
				path, adapter, { status = "ok", content = "owned preset" })
			io.open, os.remove = original_open, original_remove
			local observed = assert(original_open(path, "r")); local source = observed:read("*a"); assert(observed:close())
			original_remove(path); original_remove(path .. fixture.WRITE_LOCK_SUFFIX)
			helpers.assert_eq(call_ok, true)
			helpers.assert_eq(removed, false)
			helpers.assert_contains(detail, "controlled read refusal")
			helpers.assert_eq(source, "owned preset")
			helpers.assert_eq(locks, 1); helpers.assert_eq(unlocks, 1); helpers.assert_eq(unlinks, 0)
		end)
	end)
end)
