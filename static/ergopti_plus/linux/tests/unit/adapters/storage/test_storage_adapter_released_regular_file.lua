--- tests/unit/adapters/storage/test_storage_adapter_released_regular_file.lua

--- ==============================================================================
--- MODULE: Storage Adapter JSON Round-Trip Regression Guard
--- DESCRIPTION:
--- Verifies that the Linux storage adapter persists and reloads structured
--- values without loss. The adapter serialises its key-value store to
--- storage.json; a value stored with nested tables, arrays, and non-ASCII text
--- must survive a full persist -> reload -> read cycle byte-for-byte.
---
--- ROOT CAUSE ENCODED:
--- storage.lua used a bespoke JSON encoder/decoder. The decoder matched
--- top-level "key":value pairs with a single flat pattern whose value stopped
--- at the first "," or "}", so it could not parse nested objects or arrays: the
--- nested value was dropped and its inner keys leaked to the top level. The
--- encoder also serialised Lua arrays as string-keyed objects. Any non-flat
--- stored value was therefore corrupted on reload. The fix routes encode/decode
--- through the shared _shared/lua/json.lua codec; this test fails (nested/array
--- fields come back nil) against the bespoke codec and passes against json.lua.
--- ==============================================================================

package.loaded["tests.support.adapters.storage.storage_adapter_fixture"] = nil
local Fixture = require("tests.support.adapters.storage.storage_adapter_fixture")
local helpers, storage_cohort_fixture =
	Fixture.helpers, Fixture.storage_cohort_fixture




helpers.describe("storage released regular-file link admission", function()
	local source = ' {"a":false,"foreign":[9007199254740993,{},[],null]} '
	local function linked(body, dangling)
		storage_cohort_fixture(nil, function(storage, files, path, target, write, read)
			local Shell = require("adapters.shell_runner")
			if not dangling then write(target, source) end
			helpers.assert_true(Shell.run("ln -s -- " .. Shell.quote(target) .. " " .. Shell.quote(path)))
			body(storage, files, path, target, write, read, Shell)
		end)
	end
	for _, vector in ipairs({
		{ name = "set", mutate = function(storage) return storage.set("a", true) end,
			expected = ' {"a":true,"foreign":[9007199254740993,{},[],null]} ' },
		{ name = "set_many", mutate = function(storage) return storage.set_many({ a = true }) end,
			expected = ' {"a":true,"foreign":[9007199254740993,{},[],null]} ' },
		{ name = "delete", mutate = function(storage) return storage.delete("a") end,
			expected = ' {"foreign":[9007199254740993,{},[],null]} ' },
		{ name = "clear", mutate = function(storage) return storage.clear() end, expected = ' {} ' },
	}) do
		helpers.it("released-link: " .. vector.name .. " replaces only the link and preserves foreign source tokens", function()
			linked(function(storage, _, path, target, _, read, Shell)
				helpers.assert_eq(storage.get("a"), false)
				helpers.assert_true(vector.mutate(storage))
				helpers.assert_eq(read(path), vector.expected); helpers.assert_eq(read(target), source)
				helpers.assert_eq(Shell.run("test -L " .. Shell.quote(path)), false)
				helpers.assert_nil(read(path .. ".tmp")); helpers.assert_nil(storage.recovery_status())
				local restarted = helpers.load_module("adapters.storage")
				helpers.assert_eq(restarted.get("a", "absent"), (vector.name == "delete" or vector.name == "clear") and "absent" or true)
			end)
		end)
	end
	helpers.it("released-link: owned capture and foreign cohort publication retain strict source-kind refusal", function()
		linked(function(storage, _, path, target, _, read, Shell)
			helpers.assert_eq(storage.get("a"), false)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_nil(storage.capture_owned(owner))
			helpers.assert_eq(storage.set("neighbor", true), false)
			helpers.assert_eq(read(path), source); helpers.assert_eq(read(target), source)
			helpers.assert_true(Shell.run("test -L " .. Shell.quote(path)))
			helpers.assert_nil(read(path .. ".tmp")); helpers.assert_nil(storage.recovery_status())
			helpers.assert_true(storage.release_owned(owner))
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(target), source)
		end)
	end)
	helpers.it("released-link: dangling source remains refused rather than treated as an absent regular file", function()
		linked(function(storage, _, path, target, _, read, Shell)
			helpers.assert_eq(storage.set("a", true), false)
			helpers.assert_true(Shell.run("test -L " .. Shell.quote(path)))
			helpers.assert_nil(read(target)); helpers.assert_nil(read(path .. ".tmp"))
		end, true)
	end)
	for _, failure in ipairs({ "read", "close" }) do
		helpers.it("released-link: actual descriptor " .. failure .. " refusal preserves the link and cache", function()
			linked(function(storage, _, path, target, _, read, Shell)
				helpers.assert_eq(storage.get("a"), false)
				local reader = require("infra.regular_file_reader"); local open, calls = reader.open, 0
				reader.open = function(name, ...)
					local handle, detail, errno = open(name, ...)
					if name ~= path or not handle then return handle, detail, errno end
					calls = calls + 1
					return {
						read = function(_, ...) if failure == "read" then return nil, "controlled native read refusal" end; return handle:read(...) end,
						close = function() local closed = handle:close(); if failure == "close" then return false end; return closed end,
					}
				end
				local called, accepted = pcall(storage.set, "a", true)
				reader.open = open
				helpers.assert_true(called); helpers.assert_eq(accepted, false); helpers.assert_true(calls > 0)
				helpers.assert_eq(storage.get("a"), false); helpers.assert_eq(read(target), source)
				helpers.assert_true(Shell.run("test -L " .. Shell.quote(path))); helpers.assert_nil(read(path .. ".tmp"))
				helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(target), source)
			end)
		end)
	end
	helpers.it("released-link: final source callback withdrawal refuses publication until exact capability repair", function()
		linked(function(storage, _, path, target, _, read, Shell)
			storage.get("a")
			local reader = require("infra.regular_file_reader"); local open, samples, set = reader.open, 0, storage.set
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path then samples = samples + 1; if samples == 2 then storage.set = function() return false end end end
				return handle, detail, errno
			end
			local called, accepted = pcall(set, "a", true)
			reader.open, storage.set = open, set
			helpers.assert_true(called); helpers.assert_eq(accepted, false); helpers.assert_true(samples >= 2)
			helpers.assert_eq(read(target), source); helpers.assert_eq(read(path), source)
			helpers.assert_true(Shell.run("test -L " .. Shell.quote(path))); helpers.assert_nil(read(path .. ".tmp"))
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(target), source)
		end)
	end)
	helpers.it("released-link: source-read and native-rename reentry cannot mutate or acquire another alias", function()
		linked(function(storage, _, path, target, _, read)
			storage.get("a")
			local reader = require("infra.regular_file_reader"); local open, rename, observed = reader.open, os.rename, {}
			reader.open = function(name, ...)
				if name == path and observed.read_set == nil then
					observed.read_set = storage.set("neighbor", true); observed.read_claim = storage.acquire_owned({}, { "neighbor" })
				end
				return open(name, ...)
			end
			os.rename = function(from, to)
				if to == path then observed.rename_set = storage.set("neighbor", true); observed.rename_claim = storage.acquire_owned({}, { "neighbor" }) end
				return rename(from, to)
			end
			local called, accepted = pcall(storage.set, "a", true)
			reader.open, os.rename = open, rename
			helpers.assert_true(called); helpers.assert_true(accepted)
			for _, name in ipairs({ "read_set", "read_claim", "rename_set", "rename_claim" }) do helpers.assert_eq(observed[name], false) end
			helpers.assert_eq(read(target), source); helpers.assert_eq(read(path), ' {"a":true,"foreign":[9007199254740993,{},[],null]} ')
		end)
	end)
	helpers.it("released-link: acknowledged rename retries only failed physical readback", function()
		linked(function(storage, _, path, target, _, read)
			storage.get("a")
			local reader = require("infra.regular_file_reader"); local open, rename, effect, calls = reader.open, os.rename, false, 0
			os.rename = function(from, to)
				local accepted, detail, errno = rename(from, to)
				if to == path and accepted == true then effect = true; calls = calls + 1 end
				return accepted, detail, errno
			end
			reader.open = function(name, ...)
				if name == path and effect then return nil, "controlled readback EACCES", 13 end
				return open(name, ...)
			end
			local called, accepted = pcall(storage.set, "a", true)
			reader.open = open
			local cached, target_bytes = storage.get("a"), read(target)
			local retry_called, retry = pcall(storage.set, "a", true)
			os.rename = rename
			helpers.assert_true(called); helpers.assert_eq(accepted, false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(target_bytes, source); helpers.assert_eq(cached, false)
			helpers.assert_true(retry_called); helpers.assert_true(retry); helpers.assert_eq(calls, 1)
			helpers.assert_eq(storage.get("a"), true); helpers.assert_nil(read(path .. ".tmp"))
		end)
	end)
	helpers.it("released-link: a refused native rename retires no effect without replacing the link", function()
		linked(function(storage, _, path, target, _, read, Shell)
			storage.get("a")
			local rename, calls = os.rename, 0
			os.rename = function(from, to)
				if to == path then calls = calls + 1; return false, "controlled refusal before native effect" end
				return rename(from, to)
			end
			local called, accepted = pcall(storage.set, "a", true)
			os.rename = rename
			helpers.assert_true(called); helpers.assert_eq(accepted, false); helpers.assert_eq(calls, 1)
			helpers.assert_true(Shell.run("test -L " .. Shell.quote(path)))
			helpers.assert_eq(read(path), source); helpers.assert_eq(read(target), source)
			helpers.assert_eq(storage.get("a"), false); helpers.assert_nil(read(path .. ".tmp"))
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(target), source)
			helpers.assert_eq(Shell.run("test -L " .. Shell.quote(path)), false)
		end)
	end)
end)




helpers.describe("script storage retired journal roots", function()
	helpers.it("script-storage-cohort successful forget releases a retained authentic journal owner", function()
		storage_cohort_fixture('{"a":1,"future":0.1}', function(storage, files, path, backup, _, read)
			local owner = { pending = function() return false end }
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner))
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, files))
			-- Retain the exact private journal that the native publication closure
			-- keeps as a JIT constant; no synthetic journal is substituted.
			-- The map is the receipts upvalue of the shared owned-alias protocol
			-- (storage_owned.lua), which forget_owned is.
			local records, slot = nil, 1
			while true do
				local name, value = debug.getupvalue(storage.forget_owned, slot)
				if name == nil then break end
				if name == "receipts" then records = value; break end
				slot = slot + 1
			end
			helpers.assert_type(records, "table", "the real native receipt map must be reachable")
			local retained_journal = records[receipt]
			helpers.assert_true(rawequal(retained_journal.owner, owner))
			local source, snapshot = read(path), read(backup)
			helpers.assert_eq(storage.forget_owned(owner, receipt), false)
			helpers.assert_true(rawequal(retained_journal.owner, owner), "held refusal preserves inverse ownership")
			helpers.assert_true(storage.release_owned(owner))
			for _, pending in ipairs({ function() return true end, function() error("native pending refusal") end }) do
				owner.pending = pending
				helpers.assert_eq(storage.forget_owned(owner, receipt), false)
				helpers.assert_true(rawequal(records[receipt], retained_journal))
				helpers.assert_true(rawequal(retained_journal.owner, owner), "refused finalization must not detach the owner")
			end
			owner.pending = function() return false end
			local native_setmetatable = setmetatable
			setmetatable = function() error("native tombstone allocation refused") end
			local completed = pcall(storage.forget_owned, owner, receipt)
			setmetatable = native_setmetatable
			helpers.assert_eq(completed, false, "tombstone construction must finish before retiring inverse ownership")
			helpers.assert_true(rawequal(records[receipt], retained_journal))
			helpers.assert_true(rawequal(retained_journal.owner, owner))
			helpers.assert_eq(storage.forget_owned({}, receipt), false)
			helpers.assert_true(rawequal(retained_journal.owner, owner))
			helpers.assert_true(storage.forget_owned(owner, receipt))
			helpers.assert_nil(retained_journal.owner, "successful finalization detaches even a rooted retired journal")
			helpers.assert_true(storage.forget_owned(owner, receipt), "the weak tombstone keeps exact idempotence")
			helpers.assert_eq(storage.forget_owned({}, receipt), false)
			helpers.assert_eq(read(path), source); helpers.assert_eq(read(backup), snapshot)
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.restore_owned(owner, receipt), false, "a retained old closure cannot revive its forgotten receipt")
			local fresh = assert(storage.capture_owned(owner))
			helpers.assert_true(fresh ~= receipt)
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, fresh))
			helpers.assert_eq(read(path), source); helpers.assert_eq(read(backup), snapshot)
		end)
	end)
end)




helpers.describe("storage-mixed-batch: atomic values and removals", function()
	for _, held in ipairs({ false, true }) do
		helpers.it("storage-mixed-batch: persists removal and value together with held=" .. tostring(held), function()
			storage_cohort_fixture('{"a":false,"future":0.1,"huge":9007199254740993}', function(storage, _, path, _, _, read)
				local owner = { pending = function() return false end }
				if held then helpers.assert_true(storage.acquire_owned(owner, { "unrelated" })) end
				helpers.assert_true(storage.set_many({ appended = "new" }, { "a" }))
				helpers.assert_nil(storage.get("a")); helpers.assert_eq(storage.get("appended"), "new")
				helpers.assert_eq(read(path), '{"future":0.1,"huge":9007199254740993,"appended":"new"}')
				if held then helpers.assert_true(storage.release_owned(owner)) end
				local reloaded = helpers.load_module("adapters.storage")
				helpers.assert_nil(reloaded.get("a")); helpers.assert_eq(reloaded.get("appended"), "new")
			end)
		end)
	end
	for _, held in ipairs({ false, true }) do
		helpers.it("storage-mixed-batch: refused native publication keeps every original cell with held=" .. tostring(held), function()
			storage_cohort_fixture('{"a":false,"peer":1}', function(storage, files, path, _, _, read)
				local owner = { pending = function() return false end }
				if held then helpers.assert_true(storage.acquire_owned(owner, { "unrelated" })) end
				local rename, publish = os.rename, files.write_if_unchanged
				local publications = 0
				os.rename = function(from, to)
					if to == path then publications = publications + 1; return nil, "native rename refused" end
					return rename(from, to)
				end
				files.write_if_unchanged = function(name, ...)
					if name == path then publications = publications + 1; return false, "native publisher refused" end
					return publish(name, ...)
				end
				local ok, detail = xpcall(function()
					helpers.assert_eq(storage.set_many({ peer = 2 }, { "a" }), false)
					helpers.assert_eq(publications, 1)
					helpers.assert_eq(read(path), '{"a":false,"peer":1}')
					helpers.assert_eq(storage.get("a"), false); helpers.assert_eq(storage.get("peer"), 1)
				end, debug.traceback)
				os.rename, files.write_if_unchanged = rename, publish
				if not ok then error(detail, 0) end
				if held then helpers.assert_true(storage.release_owned(owner)) end
			end)
		end)
	end
	for _, deletions in ipairs({ false, { "a", "a" }, { "" }, { [2] = "a" }, { "a" }, { "a\0b" } }) do
		helpers.it("storage-mixed-batch: refuses malformed or overlapping removals " .. helpers.inspect(deletions), function()
			storage_cohort_fixture('{"a":false,"peer":1}', function(storage, _, path, _, _, read)
				helpers.assert_eq(storage.set_many({ a = true }, deletions), false)
				helpers.assert_eq(read(path), '{"a":false,"peer":1}')
				helpers.assert_eq(storage.get("a"), false)
			end)
		end)
	end
	helpers.it("storage-mixed-batch: a held removed alias rejects the entire batch", function()
		storage_cohort_fixture('{"a":false,"peer":1}', function(storage, _, path, _, _, read)
			local owner = { pending = function() return false end }
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set_many({ peer = 2 }, { "a" }), false)
			helpers.assert_eq(read(path), '{"a":false,"peer":1}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)

