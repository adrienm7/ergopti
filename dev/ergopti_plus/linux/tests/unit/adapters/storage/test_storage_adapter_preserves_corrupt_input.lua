--- tests/unit/adapters/storage/test_storage_adapter_preserves_corrupt_input.lua

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
local helpers, make_temp_config_root, storage_cohort_fixture =
	Fixture.helpers, Fixture.make_temp_config_root, Fixture.storage_cohort_fixture




-- ===================================================
-- ===================================================
-- ======= 3/ Corrupt-store recovery =================
-- ===================================================
-- ===================================================

helpers.describe("storage adapter preserves corrupt input for recovery", function()
	helpers.it("moves invalid JSON aside before creating a new durable store", function()
		local temp_root = make_temp_config_root()
		local store_path = temp_root .. "/ergopti_plus/storage.json"
		local raw = assert(io.open(store_path, "w"))
		raw:write("{ definitely not JSON")
		raw:close()
		local real_getenv = os.getenv
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return temp_root end
			return real_getenv(name)
		end

		local recovery_path = nil
		local ok, err = pcall(function()
			local storage = helpers.load_module("adapters.storage")
			helpers.assert_eq(storage.get("missing", "fallback"), "fallback")
			local status = storage.recovery_status()
			helpers.assert_true(type(status) == "table" and status.preserved == true)
			helpers.assert_eq(status.reason, "invalid_json")
			recovery_path = status.path
			local preserved = assert(io.open(recovery_path, "r"))
			helpers.assert_eq(preserved:read("*a"), "{ definitely not JSON")
			preserved:close()

			helpers.assert_true(storage.set("after_recovery", true))
			storage = helpers.load_module("adapters.storage")
			helpers.assert_eq(storage.get("after_recovery"), true)
		end)

		os.getenv = real_getenv
		package.loaded["adapters.storage"] = nil
		os.remove(store_path)
		os.remove(store_path .. ".tmp")
		if recovery_path then os.remove(recovery_path) end
		if not ok then error(err, 0) end
	end)
end)




helpers.describe("native script storage cohorts", function()
	helpers.it("script-storage-cohort exact alias gates and primary pending admission", function()
		storage_cohort_fixture('{"a":false,"foreign":4}', function(storage, _, path, _, _, read)
			local owner, other = { pending = function() return false end }, {}
			for _, keys in ipairs({ {}, { "a", "a" }, { [2] = "a" }, { "" }, { "a\0b" } }) do helpers.assert_eq(storage.acquire_owned(owner, keys), false) end
			helpers.assert_true(storage.acquire_owned(owner, { "a", "missing" }))
			helpers.assert_eq(storage.acquire_owned(owner, { "a" }), false)
			helpers.assert_eq(storage.acquire_owned(other, { "a", "foreign" }), false)
			helpers.assert_true(storage.acquire_owned(other, { "foreign" }))
			local receipt = assert(storage.capture_owned(owner)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_eq(storage.set("a", true), false); helpers.assert_eq(storage.delete("missing"), false)
			helpers.assert_eq(storage.set_many({ a = true, untouched = 1 }), false); helpers.assert_eq(storage.clear(), false)
			helpers.assert_eq(read(path), '{"a":false,"foreign":4}')
			owner.pending = function() return true end; helpers.assert_eq(storage.release_owned(owner), false)
			owner.pending = function() return nil end; helpers.assert_eq(storage.release_owned(owner), false)
			owner.pending = function() return false end; helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.release_owned(other))
		end)
	end)

	helpers.it("script-storage-cohort detached private capture refuses forged and unowned updates", function()
		storage_cohort_fixture('{"a":{"list":[1,2]},"b":false}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "b", "absent" }))
			local receipt, cells = storage.capture_owned(owner)
			helpers.assert_true(cells.a.present); helpers.assert_eq(cells.b.value, false); helpers.assert_eq(cells.absent.present, false)
			cells.a.value.list[1], cells.b.present = 99, false
			helpers.assert_eq(storage.publish_owned(owner, {}, { b = { present = true, value = true } }, backup, files), false)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { foreign = { present = true, value = 1 } }, backup, files), false); helpers.assert_nil(read(backup))
			helpers.assert_true(storage.publish_owned(owner, receipt, { b = { present = true, value = 0 } }, backup, files))
			helpers.assert_eq(storage.get("a").list[1], 1); helpers.assert_eq(storage.get("b"), 0)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":{"list":[1,2]},"b":false}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort actual backup order and retained inverse preserve foreign JSON kinds", function()
		storage_cohort_fixture('{"a":false,"future":null,"empty":[],"foreign":1}', function(storage, files, path, backup, write, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "new" })); local receipt = assert(storage.capture_owned(owner))
			write(path, '{"a":false,"future":null,"empty":[],"foreign":2}')
			local calls = {}
			local observed = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				calls[#calls + 1] = name
				if name == path then
					local snapshot = assert(require("json").decode_lossless(read(backup)))
					helpers.assert_eq(snapshot.source.content, '{"a":false,"future":null,"empty":[],"foreign":2}')
					helpers.assert_eq(storage.set("foreign", 88), false, "actual same-file publication reentry refuses")
				end
				return files.write_if_unchanged(name, bytes, expected)
			end }
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true }, new = { present = true, value = { 3, 4 } } }, backup, observed))
			helpers.assert_eq(calls, { backup, path }); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.set("foreign", 3)); helpers.assert_true(storage.release_owned(owner))
			helpers.assert_true(storage.acquire_owned(owner, { "new", "a" })); helpers.assert_true(storage.restore_owned(owner, receipt))
			local actual = assert(require("json").decode_lossless(read(path)))
			helpers.assert_eq(actual.a, false); helpers.assert_nil(actual.new); helpers.assert_eq(actual.foreign, 3)
			helpers.assert_true(require("json").is_null(actual.future)); helpers.assert_true(require("json").is_array(actual.empty))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort backup-time foreign source edit refuses before actual effect", function()
		storage_cohort_fixture('{"a":1,"foreign":2}', function(storage, files, path, backup, write, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			local racing = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				local result = files.write_if_unchanged(name, bytes, expected)
				if name == backup then write(path, '{"a":1,"foreign":99}') end
				return result
			end }
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, backup, racing), false)
			helpers.assert_eq(read(path), '{"a":1,"foreign":99}'); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":1,"foreign":99}'); helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort source change and same-value cooperating successor refuse stale inverse", function()
		storage_cohort_fixture('{"a":1}', function(storage, files, path, backup, write, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			write(path, '{"a":2}'); helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, backup, files), false)
			helpers.assert_nil(read(backup)); helpers.assert_eq(read(path), '{"a":2}')
			write(path, '{"a":1}'); local current = assert(storage.capture_owned(owner))
			helpers.assert_true(storage.publish_owned(owner, current, { a = { present = true, value = 3 } }, backup, files))
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.set("a", 3)); helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.restore_owned(owner, current), false); helpers.assert_eq(storage.get("a"), 3)
			helpers.assert_true(storage.pending_owned(owner, current)); helpers.assert_eq(storage.release_owned(owner), false)
		end)
	end)

	helpers.it("script-storage-cohort exact present bytes and real absence restore", function()
		for _, source in ipairs({ false, ' { "a" : 1, "foreign" : false }\n' }) do
			storage_cohort_fixture(source or nil, function(storage, files, path, backup, _, read)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "new" })); local receipt = assert(storage.capture_owned(owner))
				helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = false }, new = { present = true, value = 0 } }, backup, files))
				helpers.assert_eq(storage.get("a"), false); helpers.assert_eq(storage.get("new"), 0)
				helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), source or nil); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)

	helpers.it("script-storage-cohort false native ACK retains actual compensation and blocks release", function()
		storage_cohort_fixture('{"a":1}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner)); local first = true
			local failed = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				local result = files.write_if_unchanged(name, bytes, expected)
				if name == path and first then first = false; return false end
				return result
			end }
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, failed), false)
			helpers.assert_eq(read(path), '{"a":2}'); helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":1}')
			helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort same-value live module and backup callback method replacements refuse", function()
		storage_cohort_fixture('{"a":1}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			local successor = helpers.load_module("adapters.storage"); helpers.assert_eq(successor.get("a"), 1)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, files), false)
			helpers.assert_nil(read(backup)); helpers.assert_eq(read(path), '{"a":1}'); package.loaded["adapters.storage"] = storage
			local previous_set = storage.set
			local replacing = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				local okay = files.write_if_unchanged(name, bytes, expected); if name == backup then storage.set = function() return true end end; return okay
			end }
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, replacing), false)
			helpers.assert_eq(read(path), '{"a":1}'); storage.set = previous_set; helpers.assert_true(storage.release_owned(owner))
		end)
	end)

	helpers.it("script-storage-cohort strict capture refuses malformed and nonobject bytes without recovery", function()
		for _, source in ipairs({ '[1,2]', '{"a":', '{"a":1,"a":2}', '{"a":01}', 'null', 'true', '{"a":1} trailing' }) do
			storage_cohort_fixture(source, function(storage, _, path, _, _, read)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_eq(storage.capture_owned(owner), nil)
				helpers.assert_eq(read(path), source); helpers.assert_nil(read(path .. ".corrupt")); helpers.assert_nil(storage.recovery_status()); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)

	helpers.it("script-storage-cohort native FIFO and symlink source kinds refuse without mutation", function()
		for _, kind in ipairs({ "fifo", "symlink" }) do
			storage_cohort_fixture(nil, function(storage, _, path, backup, write, read)
				local Shell = require("adapters.shell_runner")
				if kind == "fifo" then helpers.assert_true(Shell.run("mkfifo -- " .. Shell.quote(path)))
				else write(backup, '{"a":1}'); helpers.assert_true(Shell.run("ln -s -- " .. Shell.quote(backup) .. " " .. Shell.quote(path))) end
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_eq(storage.capture_owned(owner), nil)
				helpers.assert_true(Shell.run("test " .. (kind == "fifo" and "-p " or "-L ") .. Shell.quote(path)))
				if kind == "symlink" then helpers.assert_eq(read(backup), '{"a":1}') end
				helpers.assert_nil(storage.recovery_status()); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)
end)




helpers.describe("script storage receipt finalization", function()
	helpers.it("script-storage-cohort refused capture releases its native owner without a receipt", function()
		local retained_storage, weak
		storage_cohort_fixture('{"a":', function(storage)
			retained_storage = storage
			local owner = {}
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_nil(storage.capture_owned(owner), "malformed native source cannot issue a receipt")
			helpers.assert_true(storage.release_owned(owner))
			weak = setmetatable({ owner }, { __mode = "v" })
			owner = nil
		end)
		collectgarbage("collect")
		helpers.assert_nil(weak[1], "a refused capture must not retain its native owner without a receipt to finalize")
		helpers.assert_eq(type(retained_storage.capture_owned), "function", "the native producer remains reachable during the collection proof")
	end)
	helpers.it("script-storage-cohort explicit forget finalizes without IO and breaks native owner cycles", function()
		local retained_storage, retained_receipt, weak
		storage_cohort_fixture('{"a":1}', function(storage, files, path, backup, _, read)
			retained_storage = storage
			local owner, receipt = {}, nil
			owner.pending = function() local retained = receipt; return retained == nil end
			helpers.assert_true(storage.acquire_owned(owner, { "a" })); receipt = assert(storage.capture_owned(owner))
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 2 } }, backup, files))
			helpers.assert_eq(storage.forget_owned(owner, receipt), false, "held alias gates forbid journal finalization"); helpers.assert_true(storage.release_owned(owner)); local source, snapshot = read(path), read(backup)
			local pending = owner.pending; owner.pending = function() return true end
			helpers.assert_eq(storage.forget_owned(owner, receipt), false)
			owner.pending = pending; helpers.assert_true(storage.forget_owned(owner, receipt)); helpers.assert_true(storage.forget_owned(owner, receipt))
			helpers.assert_eq(storage.forget_owned({}, receipt), false); helpers.assert_eq(read(path), source); helpers.assert_eq(read(backup), snapshot)
			helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_eq(storage.restore_owned(owner, receipt), false); helpers.assert_true(storage.release_owned(owner))
			weak = setmetatable({ owner, receipt }, { __mode = "v" })
			retained_receipt = receipt
			owner, receipt, pending = nil, nil, nil
		end)
		collectgarbage("collect")
		helpers.assert_nil(weak[1], "a finalized journal must not retain its native owner while its receipt stays reachable")
		helpers.assert_eq(weak[2], retained_receipt, "the first collection still observes the actual rooted receipt")
		retained_receipt = nil
		collectgarbage("collect")
		helpers.assert_nil(weak[1]); helpers.assert_nil(weak[2])
		helpers.assert_eq(type(retained_storage.forget_owned), "function", "the native producer remains reachable during the collection proof")
	end)
	helpers.it("script-storage-cohort foreign ordinary writes remain admitted during a distinct backup publication", function()
		storage_cohort_fixture('{"a":1,"foreign":2}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			local racing = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
				local result = files.write_if_unchanged(name, bytes, expected)
				if name == backup then helpers.assert_true(storage.set("foreign", 99)) end
				return result
			end }
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, backup, racing), false)
			helpers.assert_eq(require("json").decode_lossless(read(path)), { a = 1, foreign = 99 })
			helpers.assert_eq(storage.pending_owned(owner, receipt), false); helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)




helpers.describe("script storage fake contract", function()
	helpers.it("script-storage-cohort in-memory fake rejects owned writes and preserves foreign cells on retained inverse", function()
		storage_cohort_fixture(nil, function(_, files, _, backup)
			local storage = require("tests.fakes").storage({ initial = { a = false, foreign = 1 } })
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a", "missing" }))
			local receipt, cells = storage.capture_owned(owner); helpers.assert_eq(cells.a.value, false); cells.a.present = false
			helpers.assert_eq(storage.set("a", true), false); helpers.assert_eq(storage.set_many({ a = true, foreign = 4 }), false)
			helpers.assert_eq(storage.delete("missing"), false); helpers.assert_eq(storage.clear(), false)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true }, missing = { present = true, value = 0 } }, backup, files))
			helpers.assert_true(storage.set("foreign", 9)); helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.acquire_owned(owner, { "missing", "a" }))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(storage.get("a"), false); helpers.assert_eq(storage.get("foreign"), 9); helpers.assert_nil(storage.get("missing"))
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
end)




helpers.describe("script storage opaque owner identity", function()
	helpers.it("script-storage-cohort table equality metamethod cannot forge receipt owner or update alias ownership", function()
		storage_cohort_fixture('{"a":1,"foreign":2}', function(storage, files, _, backup)
			local mt = { __eq = function() return true end }
			local owner, foreign = setmetatable({}, mt), setmetatable({}, mt)
			helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_true(storage.acquire_owned(foreign, { "foreign" }))
			local receipt = assert(storage.capture_owned(owner))
			helpers.assert_eq(storage.publish_owned(owner, receipt, { foreign = { present = true, value = 99 } }, backup, files), false)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 3 } }, backup, files)); helpers.assert_true(storage.release_owned(owner))
			helpers.assert_eq(storage.forget_owned(foreign, receipt), false); helpers.assert_true(storage.release_owned(foreign)); helpers.assert_true(storage.acquire_owned(foreign, { "a" }))
			helpers.assert_eq(storage.restore_owned(foreign, receipt), false); helpers.assert_true(storage.release_owned(foreign))
			helpers.assert_true(storage.acquire_owned(owner, { "a" })); helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
			helpers.assert_eq(storage.forget_owned(foreign, receipt), false)
		end)
	end)
end)




helpers.describe("script storage numeric source admission", function()
	helpers.it("script-storage-cohort unsafe future decimal tokens survive source-bound owned effects", function()
		local cases = {
			'{"a":false,"future":9007199254740993}',
			'{"a":false,"future":0.1}',
			'{"a":false,"future":1e-400}',
			'{"a":false,"future":[0.12345678901234567890123456789]}',
			'{"a":false,"future":{"nested":9007199254740993}}',
		}
		for _, source in ipairs(cases) do
			storage_cohort_fixture(source, function(storage, files, path, backup, _, read)
				local owner = { pending = function() return false end }
				helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt, cells = storage.capture_owned(owner)
				helpers.assert_true(type(receipt) == "table"); helpers.assert_eq(cells.a.value, false)
				helpers.assert_eq(storage.set("a", true), false)
				helpers.assert_eq(read(path), source); helpers.assert_nil(read(backup))
				helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
				local expected = source:gsub('"a":false', '"a":true', 1)
				helpers.assert_eq(read(path), expected)
				helpers.assert_eq(require("json").decode_lossless(read(backup)).source.content, source)
				helpers.assert_true(storage.set("foreign", true))
				helpers.assert_eq(read(path), expected:sub(1, -2) .. ',"foreign":true}')
				helpers.assert_true(storage.restore_owned(owner, receipt))
				helpers.assert_eq(read(path), source:sub(1, -2) .. ',"foreign":true}')
				helpers.assert_nil(read(path .. ".tmp")); helpers.assert_nil(read(path .. ".corrupt"))
				helpers.assert_nil(storage.recovery_status()); helpers.assert_true(storage.release_owned(owner))
				helpers.assert_true(storage.forget_owned(owner, receipt))
				helpers.assert_eq(helpers.load_module("adapters.storage").get("a"), false)
			end)
		end
	end)

	helpers.it("script-storage-cohort representable tokens and escaped numeric strings preserve native source", function()
		local source = [[{"a":false,"fraction":0.125,"padded":16.50e+1,"exponent":1e3,"zero":0e9999,"future":null,"empty":[],"9007199254740993":"1e-400 0.1","escaped":"\\\"9007199254740993"}]]
		storage_cohort_fixture(source, function(storage, files, path, backup, _, read)
			local json = require("json"); local owner = {}
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt, cells = storage.capture_owned(owner); helpers.assert_true(type(receipt) == "table"); helpers.assert_eq(cells.a.value, false)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			local current = json.decode_lossless(read(path)); local saved = json.decode_lossless(read(backup))
			helpers.assert_eq(current.a, true); helpers.assert_eq(current.fraction, 0.125)
			helpers.assert_eq(current.padded, 165); helpers.assert_eq(current.exponent, 1000); helpers.assert_eq(current.zero, 0)
			helpers.assert_true(json.is_null(current.future)); helpers.assert_true(json.is_array(current.empty))
			helpers.assert_eq(current["9007199254740993"], "1e-400 0.1"); helpers.assert_eq(current.escaped, '\\"9007199254740993')
			helpers.assert_eq(saved.source.content, source); helpers.assert_eq(saved.cells.a.value, false)
			helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.set("foreign", 0.5)); helpers.assert_true(storage.restore_owned(owner, receipt))
			current = json.decode_lossless(read(path)); helpers.assert_eq(current.a, false); helpers.assert_eq(current.foreign, 0.5)
			helpers.assert_eq(current.fraction, 0.125); helpers.assert_eq(current["9007199254740993"], "1e-400 0.1")
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)

	helpers.it("script-storage-cohort numeric backup refusal leaves the native owner unspent", function()
		storage_cohort_fixture('{"a":false}', function(storage, files, path, backup, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" })); local receipt = assert(storage.capture_owned(owner))
			local integer = 9007199254740993
			-- Only Lua5.4 supplies this exact integer to the actual native adapter;
			-- LuaJIT has rounded it before the call and cannot prove this premise.
			if type(integer) == "number" and integer % 1 == 0 and integer - 9007199254740992 == 1 then
				helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = integer } }, backup, files), false)
				helpers.assert_eq(read(path), '{"a":false}'); helpers.assert_nil(read(backup)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			end
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = 0.125 } }, backup, files))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":false}')
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
end)




helpers.describe("script storage raw producer identity", function()
	helpers.it("script-storage-cohort forged module equality cannot authorize actual native publication", function()
		for _, stage in ipairs({ "capture", "publish", "backup", "readback" }) do
			storage_cohort_fixture('{"a":false,"future":[]}', function(storage, files, path, backup, _, read)
				local comparisons = 0
				local mt = { __index = function(_, key) return rawget(storage, key) end, __eq = function() comparisons = comparisons + 1; return true end }
				setmetatable(storage, mt)
				local successor = setmetatable({}, mt)
				helpers.assert_true(not rawequal(successor, storage))
				local owner = { pending = function() return false end }; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				if stage == "capture" then
					package.loaded["adapters.storage"] = successor
					helpers.assert_nil(storage.capture_owned(owner)); helpers.assert_nil(read(backup))
				else
					local receipt = assert(storage.capture_owned(owner)); local producer, replaced = files, false
					if stage == "publish" then package.loaded["adapters.storage"] = successor
					else producer = { delete = files.delete, write_if_unchanged = function(name, bytes, expected)
						local result = files.write_if_unchanged(name, bytes, expected)
						if not replaced and name == (stage == "backup" and backup or path) then replaced = true; package.loaded["adapters.storage"] = successor end
						return result
					end } end
					helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, producer), false)
					if stage == "readback" then
						helpers.assert_eq(require("json").decode_lossless(read(path)).a, true, "actual effect requires retained compensation")
						helpers.assert_true(storage.pending_owned(owner, receipt)); helpers.assert_eq(storage.release_owned(owner), false)
					else helpers.assert_eq(read(path), '{"a":false,"future":[]}'); helpers.assert_eq(storage.pending_owned(owner, receipt), false) end
					if stage == "publish" then helpers.assert_nil(read(backup)) end
					helpers.assert_eq(storage.restore_owned(owner, receipt), false)
					package.loaded["adapters.storage"] = storage
					helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), '{"a":false,"future":[]}')
				end
				helpers.assert_eq(comparisons, 0, "authority must never invoke producer equality metamethods")
				package.loaded["adapters.storage"] = storage; setmetatable(storage, nil)
				helpers.assert_eq(read(path), '{"a":false,"future":[]}'); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)
end)




helpers.describe("native storage exact root-member source publication", function()
	local source = ' \n{ "a" : false, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 1 }\t'
	helpers.it("preserves full handwritten bytes through owned effect, held writes and inverse", function()
		storage_cohort_fixture(source, function(storage, files, path, backup, _, read)
			local owner = { pending = function() return false end }
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner))
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			helpers.assert_eq(read(path), ' \n{ "a" : true, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 1 }\t')
			helpers.assert_true(storage.set("foreign", 2))
			helpers.assert_eq(read(path), ' \n{ "a" : true, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 2 }\t')
			helpers.assert_true(storage.set_many({ appended = false, other = "x" }))
			helpers.assert_eq(read(path), ' \n{ "a" : true, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 2 ,"appended":false,"other":"x"}\t')
			helpers.assert_true(storage.delete("other")); helpers.assert_true(storage.delete("missing"))
			helpers.assert_true(storage.restore_owned(owner, receipt))
			helpers.assert_eq(read(path), ' \n{ "a" : false, "future" : [0.1,{"i":9223372036854775807,"empty":[],"map":{},"n":null,"e":1.230000e-20}], "\\u0066oreign" : 2 ,"appended":false}\t')
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
	for _, token in ipairs({ "0.1", "9007199254740993", "1e-400", "-0" }) do
		helpers.it("refuses an unsafe captured numeric cell " .. token .. " before native effects", function()
			local input = '{"a":' .. token .. ',"future":0.1}'
			storage_cohort_fixture(input, function(storage, _, path, backup, _, read)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = storage.capture_owned(owner)
				local decoded = require("json").decode_lossless(token)
				if token == "-0" and 1 / decoded == -math.huge then
					helpers.assert_true(type(receipt) == "table", "runtime retains exact negative-zero inverse")
				else helpers.assert_nil(receipt) end
				helpers.assert_eq(read(path), input)
				helpers.assert_nil(read(backup)); helpers.assert_nil(read(path .. ".tmp"))
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("rejects actual codec instance or method replacement without equality callbacks", function()
		for _, mode in ipairs({ "instance", "method" }) do
			storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, files, path, backup, _, read)
				local json = require("json"); local owner = {}
				helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = assert(storage.capture_owned(owner))
				local original = json.splice_root_object_source
				if mode == "instance" then package.loaded["json"] = setmetatable({}, { __eq = function() error("forged equality") end })
				else json.splice_root_object_source = function() return '{}', {}, {} end end
				local result = storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files)
				package.loaded["json"], json.splice_root_object_source = json, original
				helpers.assert_eq(result, false); helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
				helpers.assert_nil(read(backup)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
				helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
				helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
			end)
		end
	end)
end)




helpers.describe("storage source-read foreign publication fences", function()
	helpers.it("retains alias ownership and refuses source-read writer reentry", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local owner, competing = {}, {}
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local reader = require("infra.regular_file_reader")
			local open, observed, entered = reader.open, {}, false
			reader.open = function(name, ...)
				if name == path and not entered then
					entered = true
					observed.set = storage.set("reentered", true)
					observed.claim = storage.acquire_owned(competing, { "foreign" })
				end
				return open(name, ...)
			end
			local okay, committed = pcall(storage.set, "foreign", true)
			reader.open = open
			helpers.assert_true(okay); helpers.assert_true(committed)
			helpers.assert_eq(observed.set, false); helpers.assert_eq(observed.claim, false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"foreign":true}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("refuses a codec successor inserted by actual classified source read", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local json, reader = require("json"), require("infra.regular_file_reader")
			local open = reader.open
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path then package.loaded["json"] = {} end
				return handle, detail, errno
			end
			local okay, committed = pcall(storage.set, "foreign", true)
			reader.open, package.loaded["json"] = open, json
			helpers.assert_true(okay); helpers.assert_eq(committed, false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
			helpers.assert_true(storage.set("foreign", true))
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"foreign":true}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)




helpers.describe("storage native backup transitive codec authority", function()
	helpers.it("rejects source-read quote replacement before backup and permits the repaired same owner", function()
		local source = '{"a":false,"future":0.1}'
		storage_cohort_fixture(source, function(storage, files, path, backup, _, read)
			local json, reader = require("json"), require("infra.regular_file_reader")
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner))
			local open, quote, replaced = reader.open, json.quote, false
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path and not replaced then
					replaced = true
					json.quote = function(value)
						return quote(value == source and "tampered" or value)
					end
				end
				return handle, detail, errno
			end
			local okay, result = pcall(storage.publish_owned, owner, receipt, { a = { present = true, value = true } }, backup, files)
			reader.open, json.quote = open, quote
			helpers.assert_true(okay); helpers.assert_true(replaced); helpers.assert_eq(result, false)
			helpers.assert_eq(read(path), source); helpers.assert_nil(read(backup))
			helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			helpers.assert_eq(require("json").decode_lossless(read(backup)).source.content, source)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), source)
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
end)

