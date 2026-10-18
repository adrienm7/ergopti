--- tests/unit/adapters/storage/test_storage_adapter_ordinary_native_cleanup.lua

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
local helpers, storage_cohort_fixture, ordinary_debt_fixture =
	Fixture.helpers, Fixture.storage_cohort_fixture, Fixture.ordinary_debt_fixture




helpers.describe("storage ordinary native cleanup journal", function()
	for _, failure in ipairs({ "refuse", "raise" }) do
		helpers.it("ordinary-native-debt: retains " .. failure .. " cleanup and retries only its terminal", function()
			ordinary_debt_fixture(failure, function(storage, files, path, backup, _, read, state)
				local owner, competitor = {}, {}
				helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = assert(storage.capture_owned(owner))
				helpers.assert_eq(storage.set("foreign", false), false)
				helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":false}')
				helpers.assert_eq(storage.get("foreign", "old"), "old")
				helpers.assert_eq(state.writes, 1); helpers.assert_eq(state.cleanups, 1)
				helpers.assert_nil(storage.capture_owned(owner))
				helpers.assert_eq(storage.acquire_owned(competitor, { "other" }), false)
				helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files), false)
				helpers.assert_eq(storage.restore_owned(owner, receipt), false)
				helpers.assert_eq(storage.delete("foreign"), false)
				helpers.assert_eq(state.writes, 1); helpers.assert_nil(read(backup))
				state.mode = "settle"
				helpers.assert_true(storage.set("foreign", false))
				helpers.assert_eq(storage.get("foreign"), false)
				helpers.assert_eq(state.writes, 1)
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("ordinary-native-debt: settles an unrelated request without acknowledging or replaying it", function()
		ordinary_debt_fixture("refuse", function(storage, _, path, _, _, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set_many({ foreign = true, second = false }), false)
			state.mode = "settle"
			helpers.assert_eq(storage.set("third", true), false)
			helpers.assert_eq(state.writes, 1); helpers.assert_eq(storage.get("second"), false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":true,"second":false}')
			state.mode = "normal"
			helpers.assert_true(storage.set("third", true)); helpers.assert_eq(state.writes, 2)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: preserves a foreign successor and retires only the old settled intent", function()
		ordinary_debt_fixture("refuse", function(storage, _, path, _, write, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false)
			local successor = '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":"external","neighbor":[]}'
			write(path, successor); state.mode = "settle"
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(read(path), successor); helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(storage.get("foreign"), "external")
			state.mode = "normal"
			helpers.assert_true(storage.set("fresh", true)); helpers.assert_eq(state.writes, 2)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":"external","neighbor":[],"fresh":true}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	for _, invalid in ipairs({ "missing", "string" }) do
		helpers.it("ordinary-native-debt: retains cleanup after " .. invalid .. " effect receipt and requires actual repair", function()
			ordinary_debt_fixture("settle", function(storage, _, path, _, _, read, state)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				if invalid == "missing" then state.effect = nil else state.effect = "true" end
				helpers.assert_eq(storage.set("foreign", true), false)
				helpers.assert_eq(storage.set("foreign", true), false)
				helpers.assert_eq(state.writes, 1)
				state.effect = true
				helpers.assert_true(storage.set("foreign", true))
				helpers.assert_eq(state.writes, 1)
				helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":true}')
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("ordinary-native-debt: refuses candidate acknowledgement when the native effect flag is false", function()
		ordinary_debt_fixture("settle", function(storage, _, path, _, write, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			state.effect = false
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(state.writes, 1)
			-- A fresh external source can retire the old proven nonpublication;
			-- it cannot retroactively turn a false native effect into success.
			write(path, '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":"other"}')
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(storage.get("foreign"), "other"); helpers.assert_eq(state.writes, 1)
			state.mode = "normal"
			helpers.assert_true(storage.delete("foreign"))
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: starts a fresh explicit retry only after proven no-effect settlement", function()
		ordinary_debt_fixture("refuse", function(storage, _, _, _, _, _, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			state.native_effect = false; state.effect = false
			helpers.assert_eq(storage.set("foreign", true), false); helpers.assert_eq(state.writes, 1)
			state.mode = "normal"; state.native_effect = true
			helpers.assert_true(storage.set("foreign", true)); helpers.assert_eq(state.writes, 2)
			helpers.assert_eq(storage.get("foreign"), true)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: does not infer publication from unacknowledged partial native effects", function()
		ordinary_debt_fixture("no_receipt", function(storage, _, path, _, write, read, state)
			local source = read(path); local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false)
			helpers.assert_eq(storage.set("foreign", true), false); helpers.assert_eq(state.writes, 1)
			helpers.assert_nil(storage.capture_owned(owner))
			-- Unknown native acknowledgement retains the attempt. Restoring its
			-- exact prior source is an explicit repair, not an automatic inverse.
			write(path, source); state.mode = "normal"
			helpers.assert_true(storage.set("foreign", true)); helpers.assert_eq(state.writes, 2)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: keeps native terminal identity across actual method successors", function()
		ordinary_debt_fixture("refuse", function(storage, files, _, _, _, _, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false)
			local method, count = files.write_if_unchanged, state.cleanups
			files.write_if_unchanged = function() error("successor must not publish") end
			state.mode = "settle"
			local result = storage.set("foreign", true)
			files.write_if_unchanged = method
			helpers.assert_eq(result, false); helpers.assert_eq(state.cleanups, count)
			helpers.assert_true(storage.set("foreign", true)); helpers.assert_eq(state.writes, 1)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: refuses source-read and native-cleanup owned reentry without effects", function()
		ordinary_debt_fixture("refuse", function(storage, files, path, backup, _, _, state)
			local owner, competitor = {}, {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); local observed = {}
			local function observe()
				observed.capture = storage.capture_owned(owner)
				observed.publish = storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files)
				observed.restore = storage.restore_owned(owner, receipt)
				observed.acquire = storage.acquire_owned(competitor, { "neighbor" })
				observed.set = storage.set("neighbor", true)
			end
			local reader = require("infra.regular_file_reader"); local open, entered = reader.open, false
			reader.open = function(name, ...)
				if name == path and not entered then entered = true; observe() end
				return open(name, ...)
			end
			local okay, result = pcall(storage.set, "foreign", true)
			reader.open = open
			helpers.assert_true(okay); helpers.assert_eq(result, false); helpers.assert_true(entered)
			helpers.assert_nil(observed.capture)
			for _, key in ipairs({ "publish", "restore", "acquire", "set" }) do helpers.assert_eq(observed[key], false) end
			observed = {}; state.observe = observe; state.mode = "settle"
			helpers.assert_true(storage.set("foreign", true))
			helpers.assert_nil(observed.capture)
			for _, key in ipairs({ "publish", "restore", "acquire", "set" }) do helpers.assert_eq(observed[key], false) end
			helpers.assert_eq(state.writes, 1); helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("ordinary-native-debt: blocks released ordinary effects until prior held cleanup settles", function()
		ordinary_debt_fixture("refuse", function(storage, _, path, _, _, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false); helpers.assert_true(storage.release_owned(owner))
			helpers.assert_eq(storage.clear(), false); helpers.assert_eq(state.writes, 1)
			state.mode = "settle"
			helpers.assert_eq(storage.clear(), false); helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":true}')
			helpers.assert_eq(storage.get("foreign"), true)
		end)
	end)
end)




helpers.describe("storage final ordinary publication admission", function()
	helpers.it("ordinary-native-debt: refuses a codec replacement during Writer final source read", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local json, reader = require("json"), require("infra.regular_file_reader")
			local open, samples = reader.open, 0
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path then samples = samples + 1; if samples == 2 then package.loaded["json"] = {} end end
				return handle, detail, errno
			end
			local okay, committed = pcall(storage.set, "foreign", true)
			reader.open, package.loaded["json"] = open, json
			helpers.assert_true(okay); helpers.assert_eq(committed, false); helpers.assert_eq(samples, 2)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
			helpers.assert_true(storage.set("foreign", true))
			helpers.assert_eq(read(path), '{"a":false,"future":0.1,"foreign":true}')
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)




helpers.describe("storage released ordinary source publication", function()
	helpers.it("released-source: preserves full foreign precision and kinds across ordinary mutations and restart", function()
		local source = ' \n{ "future" : [0.1,{"i":9223372036854775807,"long":1.234567890123456789,"empty":[],"map":{},"n":null,"e":1.2300e-20}], "\\u0061" : false }\t'
		storage_cohort_fixture(source, function(storage, _, path, _, _, read)
			helpers.assert_true(storage.set("a", true))
			helpers.assert_eq(read(path), ' \n{ "future" : [0.1,{"i":9223372036854775807,"long":1.234567890123456789,"empty":[],"map":{},"n":null,"e":1.2300e-20}], "\\u0061" : true }\t')
			helpers.assert_true(storage.set_many({ new = false, other = "x" }))
			helpers.assert_true(storage.delete("other"))
			local expected = ' \n{ "future" : [0.1,{"i":9223372036854775807,"long":1.234567890123456789,"empty":[],"map":{},"n":null,"e":1.2300e-20}], "\\u0061" : true ,"new":false}\t'
			helpers.assert_eq(read(path), expected)
			local restarted = helpers.load_module("adapters.storage")
			helpers.assert_eq(restarted.get("a"), true); helpers.assert_eq(restarted.get("new"), false)
			helpers.assert_true(restarted.set("a", false))
			helpers.assert_eq(read(path), ' \n{ "future" : [0.1,{"i":9223372036854775807,"long":1.234567890123456789,"empty":[],"map":{},"n":null,"e":1.2300e-20}], "\\u0061" : false ,"new":false}\t')
		end)
	end)
	for _, vector in ipairs({
		{ key = "a", expected = ' \n{\t"b":0.1,\n"c":9007199254740993 }\t' },
		{ key = "b", expected = ' \n{  "a" :1 ,\n"c":9007199254740993 }\t' },
		{ key = "c", expected = ' \n{  "a" :1 ,\t"b":0.1}\t' },
	}) do
		helpers.it("released-source: deletes " .. vector.key .. " while retaining complete adjacent bytes", function()
			storage_cohort_fixture(' \n{  "a" :1 ,\t"b":0.1,\n"c":9007199254740993 }\t', function(storage, _, path, _, _, read)
				helpers.assert_true(storage.delete(vector.key)); helpers.assert_eq(read(path), vector.expected)
			end)
		end)
	end
	helpers.it("released-source: keeps decoded case and escaped literal key identities", function()
		storage_cohort_fixture('{"Key":1,"key":2,"\\u0061":false,"literal.dot":[],"future":0.1}', function(storage, _, path, _, _, read)
			helpers.assert_true(storage.set_many({ Key = false, a = true }))
			helpers.assert_eq(read(path), '{"Key":false,"key":2,"\\u0061":true,"literal.dot":[],"future":0.1}')
			helpers.assert_true(storage.delete("literal.dot"))
			helpers.assert_eq(read(path), '{"Key":false,"key":2,"\\u0061":true,"future":0.1}')
		end)
	end)
	helpers.it("released-source: samples a fresh external source rather than stale loaded cache", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, write, read)
			helpers.assert_eq(storage.get("a"), false)
			write(path, '{"a":false,"future":0.1,"external":9007199254740993,"empty":[]}')
			helpers.assert_true(storage.set("a", true))
			helpers.assert_eq(read(path), '{"a":true,"future":0.1,"external":9007199254740993,"empty":[]}')
			write(path, '{"a":true,"future":0.1,"external":9007199254740993,"empty":[],"new":false}')
			helpers.assert_true(storage.delete("new"))
			helpers.assert_eq(read(path), '{"a":true,"future":0.1,"external":9007199254740993,"empty":[]}')
		end)
	end)
	helpers.it("released-source: clear owns all actual root members and keeps outside trivia", function()
		storage_cohort_fixture(' \n{ "future":0.1, "empty":[], "map":{}, "null":null }\t', function(storage, _, path, _, _, read)
			helpers.assert_true(storage.clear()); helpers.assert_eq(read(path), ' \n{}\t')
			helpers.assert_true(storage.clear()); helpers.assert_eq(read(path), ' \n{}\t')
		end)
	end)
	helpers.it("released-source: actual final source change refuses publication and safely admits a later explicit request", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, write, read)
			storage.get("a")
			local reader = require("infra.regular_file_reader"); local open, samples = reader.open, 0
			local successor = '{"a":false,"future":0.1,"external":9007199254740993}'
			reader.open = function(name, ...)
				if name == path then samples = samples + 1; if samples == 2 then write(path, successor) end end
				return open(name, ...)
			end
			local okay, result = pcall(storage.set, "a", true)
			reader.open = open
			helpers.assert_true(okay); helpers.assert_eq(result, false); helpers.assert_true(samples >= 2)
			helpers.assert_eq(read(path), successor); helpers.assert_nil(read(path .. ".tmp"))
			-- Native admission proved no call to rename; its Boolean false receipt
			-- retires the old intent but cannot acknowledge its value.
			helpers.assert_true(storage.set("a", true))
			helpers.assert_eq(read(path), '{"a":true,"future":0.1,"external":9007199254740993}')
		end)
	end)
	helpers.it("released-source: refuses codec changes during final read and permits exact capability repair", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			storage.get("a")
			local json, reader = require("json"), require("infra.regular_file_reader")
			local open, samples = reader.open, 0
			reader.open = function(name, ...)
				local handle, detail, errno = open(name, ...)
				if name == path then samples = samples + 1; if samples == 2 then package.loaded["json"] = {} end end
				return handle, detail, errno
			end
			local okay, result = pcall(storage.set, "a", true)
			reader.open, package.loaded["json"] = open, json
			helpers.assert_true(okay); helpers.assert_eq(result, false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
			helpers.assert_nil(read(path .. ".tmp")); helpers.assert_true(storage.set("a", true))
		end)
	end)
	helpers.it("released-source: retains an exclusive temporary inode claimed by another writer", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, write, read)
			write(path .. ".tmp", "foreign staging bytes")
			helpers.assert_eq(storage.set("a", true), false)
			helpers.assert_eq(read(path), '{"a":false,"future":0.1}')
			helpers.assert_eq(read(path .. ".tmp"), "foreign staging bytes")
		end)
	end)
	helpers.it("released-source: rejects decoded duplicate-key sources before ordinary effects", function()
		for _, source in ipairs({ '{"a":false,"\\u0061":true}', '{"a":{"x":1,"x":2},"future":0.1}' }) do
			storage_cohort_fixture(source, function(storage, _, path, _, _, read)
				helpers.assert_eq(storage.set("new", true), false); helpers.assert_eq(read(path), source)
				helpers.assert_nil(read(path .. ".tmp"))
			end)
		end
	end)
	helpers.it("released-source: native rename reentry cannot acquire or mutate another alias", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local rename, observed = os.rename, {}
			os.rename = function(from, to)
				if to == path then
					observed.claim = storage.acquire_owned({}, { "neighbor" })
					observed.set = storage.set("neighbor", true)
				end
				return rename(from, to)
			end
			local okay, result = pcall(storage.set, "a", true)
			os.rename = rename
			helpers.assert_true(okay); helpers.assert_true(result)
			helpers.assert_eq(observed.claim, false); helpers.assert_eq(observed.set, false)
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}')
		end)
	end)
end)




helpers.describe("storage released ordinary native receipt recovery", function()
	helpers.it("released-source: unknown partial rename acknowledgement cannot be replayed or inferred", function()
		local source = '{"a":false,"future":0.1}'
		storage_cohort_fixture(source, function(storage, _, path, _, write, read)
			storage.get("a")
			local rename, calls = os.rename, 0
			os.rename = function(from, to)
				local result, detail, errno = rename(from, to)
				if to == path then calls = calls + 1; return false, "native effect without ACK" end
				return result, detail, errno
			end
			local okay, result = pcall(storage.set, "a", true)
			os.rename = rename
			helpers.assert_true(okay); helpers.assert_eq(result, false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}'); helpers.assert_eq(storage.get("a"), false)
			helpers.assert_eq(storage.set("a", true), false); helpers.assert_eq(calls, 1)
			helpers.assert_eq(storage.acquire_owned({}, { "neighbor" }), false)
			write(path, source) -- Explicit actual-source repair, never an automatic inverse.
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(read(path), '{"a":true,"future":0.1}')
		end)
	end)
	helpers.it("released-source: acknowledged native rename retries only failed readback", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			storage.get("a")
			local reader = require("infra.regular_file_reader")
			local rename, open, effect, renames = os.rename, reader.open, false, 0
			os.rename = function(from, to)
				local result, detail, errno = rename(from, to)
				if to == path and result == true then effect = true; renames = renames + 1 end
				return result, detail, errno
			end
			reader.open = function(name, ...)
				if name == path and effect then return nil, "readback EACCES", 13 end
				return open(name, ...)
			end
			local okay, result = pcall(storage.set, "a", true)
			reader.open, os.rename = open, rename
			helpers.assert_true(okay); helpers.assert_eq(result, false); helpers.assert_eq(renames, 1)
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}'); helpers.assert_eq(storage.get("a"), false)
			helpers.assert_true(storage.set("a", true)); helpers.assert_eq(renames, 1)
			helpers.assert_eq(storage.get("a"), true); helpers.assert_nil(read(path .. ".tmp"))
		end)
	end)
end)




helpers.describe("storage lazy recovery permission under native ownership", function()
	for _, vector in ipairs({
		{ label = "valid", source = '{"a":false,"future":0.1}' },
		{ label = "malformed", source = '{malformed foreign bytes' },
		{ label = "absent" },
	}) do
		helpers.it("held-read: claim-only " .. vector.label .. " source refuses every lazy reader without effects", function()
			storage_cohort_fixture(vector.source, function(storage, _, path, _, _, read)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local reader = require("infra.regular_file_reader"); local open, calls = reader.open, 0
				reader.open = function(name, ...)
					if name == path then calls = calls + 1 end
					return open(name, ...)
				end
				local called, value, present, keys = pcall(function()
					return storage.get("a", "guarded-default"), storage.has("a"), storage.keys()
				end)
				reader.open = open
				helpers.assert_true(called); helpers.assert_eq(value, "guarded-default")
				helpers.assert_eq(present, false); helpers.assert_eq(keys, {})
				helpers.assert_eq(calls, 0); helpers.assert_eq(read(path), vector.source)
				helpers.assert_nil(read(path .. ".corrupt")); helpers.assert_nil(read(path .. ".tmp"))
				helpers.assert_nil(storage.recovery_status()); helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("held-read: refused claim initialization permits later source repair and released ordinary initialization", function()
		storage_cohort_fixture('{malformed original source', function(storage, _, path, _, write, read)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.get("a", "refused"), "refused")
			helpers.assert_true(storage.release_owned(owner))
			write(path, '{"a":false,"future":0.1}')
			helpers.assert_true(storage.set("a", true))
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}')
			helpers.assert_eq(storage.get("a"), true); helpers.assert_nil(read(path .. ".corrupt"))
		end)
	end)
	helpers.it("held-read: active ordinary cleanup preserves a malformed successor during all lazy reads", function()
		ordinary_debt_fixture("refuse", function(storage, _, path, _, write, read, state)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_eq(storage.set("foreign", true), false)
			local malformed = '{malformed external successor'
			write(path, malformed)
			helpers.assert_eq(storage.get("foreign", "refused"), "refused")
			helpers.assert_eq(storage.has("foreign"), false); helpers.assert_eq(storage.keys(), {})
			helpers.assert_eq(read(path), malformed); helpers.assert_nil(read(path .. ".corrupt"))
			helpers.assert_nil(storage.recovery_status()); helpers.assert_eq(state.writes, 1)
			helpers.assert_true(storage.release_owned(owner))
			helpers.assert_eq(storage.get("foreign", "still-refused"), "still-refused")
			helpers.assert_eq(read(path), malformed); helpers.assert_nil(read(path .. ".corrupt"))
			local candidate = '{"a":false,"future":0.1,"huge":9007199254740993,"foreign":true}'
			write(path, candidate); state.mode = "settle"
			helpers.assert_true(storage.set("foreign", true))
			helpers.assert_eq(state.writes, 1); helpers.assert_eq(read(path), candidate)
			helpers.assert_eq(storage.get("foreign"), true)
		end)
	end)
	helpers.it("held-read: ordinary boot initialization does not grant reentrant readers its private permission", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, _, read)
			local reader = require("infra.regular_file_reader"); local open, entered, observed = reader.open, false, {}
			reader.open = function(name, ...)
				if name == path and not entered then
					entered = true
					observed.get = storage.get("a", "refused")
					observed.has = storage.has("a")
					observed.keys = storage.keys()
				end
				return open(name, ...)
			end
			local called, result = pcall(storage.set, "a", true)
			reader.open = open
			helpers.assert_true(called); helpers.assert_true(result); helpers.assert_true(entered)
			helpers.assert_eq(observed.get, "refused"); helpers.assert_eq(observed.has, false); helpers.assert_eq(observed.keys, {})
			helpers.assert_eq(read(path), '{"a":true,"future":0.1}'); helpers.assert_nil(read(path .. ".corrupt"))
		end)
	end)
	helpers.it("held-read: cached reads remain read-only while ownership is active", function()
		storage_cohort_fixture('{"a":false,"future":0.1}', function(storage, _, path, _, write, read)
			helpers.assert_eq(storage.get("a"), false)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			write(path, '{malformed external bytes')
			helpers.assert_eq(storage.get("a"), false); helpers.assert_eq(storage.has("a"), true)
			local keys = storage.keys(); table.sort(keys)
			helpers.assert_eq(keys, { "a", "future" })
			helpers.assert_eq(read(path), '{malformed external bytes'); helpers.assert_nil(read(path .. ".corrupt"))
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)




helpers.describe("storage ordinary initialization lifetime", function()
	for _, vector in ipairs({
		{ label = "valid", source = '{"a":false,"future":0.1}' },
		{ label = "malformed", source = '{malformed actual recovery source' },
	}) do
		helpers.it("held-load: " .. vector.label .. " native read callbacks cannot acquire overlapping ownership", function()
			storage_cohort_fixture(vector.source, function(storage, _, path, _, _, read)
				local reader = require("infra.regular_file_reader"); local open, entered = reader.open, false
				local owner, observed = {}, {}
				reader.open = function(name, ...)
					if name == path and not entered then
						entered = true
						observed.acquire = storage.acquire_owned(owner, { "a" })
						observed.get = storage.get("a", "reentry-refused")
						observed.set = storage.set("foreign", true)
					end
					return open(name, ...)
				end
				local called, value = pcall(storage.get, "a", "ordinary-default")
				reader.open = open
				helpers.assert_true(called); helpers.assert_true(entered)
				helpers.assert_eq(observed.acquire, false); helpers.assert_eq(observed.set, false)
				helpers.assert_eq(observed.get, "reentry-refused")
				if vector.label == "valid" then
					helpers.assert_eq(value, false); helpers.assert_eq(read(path), vector.source)
					helpers.assert_nil(storage.recovery_status())
				else
					helpers.assert_eq(value, "ordinary-default"); helpers.assert_nil(read(path))
					helpers.assert_eq(read(path .. ".corrupt"), vector.source)
					helpers.assert_eq(storage.recovery_status().preserved, true)
				end
				helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("held-load: throwing recovery logger releases initialization lifetime without hiding the exception", function()
		storage_cohort_fixture('{malformed unclaimed source', function(storage, _, path, _, _, read)
			local logger = require("logger.shim"); local error_log = logger.error
			local owner, observed = {}, {}
			logger.error = function()
				observed.acquire = storage.acquire_owned(owner, { "a" })
				observed.set = storage.set("foreign", true)
				error("controlled actual recovery logger failure")
			end
			local called, failure = pcall(storage.get, "a")
			logger.error = error_log
			helpers.assert_eq(called, false)
			helpers.assert_true(tostring(failure):find("controlled actual recovery logger failure", 1, true) ~= nil)
			helpers.assert_eq(observed.acquire, false); helpers.assert_eq(observed.set, false)
			helpers.assert_eq(read(path .. ".corrupt"), '{malformed unclaimed source')
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
end)




helpers.describe("first owned native storage publication", function()
	local function missing_parent(body)
		storage_cohort_fixture(nil, function(storage, files, path, backup, write, read)
			local directory = path:match("^(.*)/[^/]+$")
			assert(os.remove(directory), "the actual storage parent starts absent")
			local Shell = require("adapters.shell_runner")
			local native_run, commands = Shell.run, {}
			local hook
			Shell.run = function(command)
				if command:find("mkdir -p ", 1, true) then
					commands[#commands + 1] = command
					if hook then return hook(command, native_run) end
				end
				return native_run(command)
			end
			local ok, err = xpcall(function()
				body(storage, files, path, backup, write, read, commands,
					function(callback) hook = callback end)
			end, debug.traceback)
			Shell.run = native_run
			if not ok then error(err, 0) end
		end)
	end
	helpers.it("owned-storage-parent: first native effect creates the real parent and restores exact absence", function()
		missing_parent(function(storage, files, path, backup, _, read, commands, inject)
			local owner = { pending = function() return false end }
			helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt, cells = storage.capture_owned(owner)
			helpers.assert_eq(cells, { a = { present = false } })
			local calls, reentry = {}, {}
			inject(function(command, native)
				reentry = { storage.set("foreign", true), storage.release_owned(owner), storage.capture_owned(owner) }
				return native(command)
			end)
			local observed = { delete = files.delete, write_if_unchanged = function(target, bytes, expected)
				calls[#calls + 1] = target
				if target == path then
					helpers.assert_eq(expected, { status = "absent" })
					helpers.assert_not_nil(read(backup), "the verified backup precedes the first effect")
				end
				return files.write_if_unchanged(target, bytes, expected)
			end }
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, observed))
			helpers.assert_eq(#commands, 1)
			helpers.assert_eq(reentry[1], false); helpers.assert_eq(reentry[2], false); helpers.assert_nil(reentry[3])
			helpers.assert_eq(calls, { backup, path })
			helpers.assert_eq(read(path), '{"a":true}')
			local saved = require("json").decode_lossless(read(backup))
			helpers.assert_eq(saved.source, { status = "absent" }); helpers.assert_eq(saved.cells, { a = { present = false } })
			helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_nil(read(path))
			helpers.assert_true(storage.release_owned(owner)); helpers.assert_true(storage.forget_owned(owner, receipt))
		end)
	end)
	for _, refusal in ipairs({
		{ "false", function() return false end }, { "nil", function() return nil end },
		{ "truthy string", function() return "true" end }, { "wrong object", function() return {} end },
		{ "exception", function() error("native directory preparation refused") end },
	}) do
		helpers.it("owned-storage-parent: strict native preparation " .. refusal[1] .. " leaves the receipt unspent", function()
			missing_parent(function(storage, files, path, backup, _, read, commands, inject)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = assert(storage.capture_owned(owner))
				inject(refusal[2])
				helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files), false)
				helpers.assert_eq(#commands, 1); helpers.assert_nil(read(path)); helpers.assert_nil(read(backup))
				helpers.assert_eq(storage.pending_owned(owner, receipt), false)
				inject(nil)
				helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
				helpers.assert_eq(read(path), '{"a":true}'); helpers.assert_eq(#commands, 2)
				helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_nil(read(path))
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end
	helpers.it("owned-storage-parent: a claimed preparation success never fabricates a native file effect", function()
		missing_parent(function(storage, files, path, backup, _, read, _, inject)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); inject(function() return true end)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files), false)
			helpers.assert_nil(read(path)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_nil(read(path))
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("owned-storage-parent: a source successor during real preparation is never adopted before staging", function()
		missing_parent(function(storage, files, path, backup, write, read, _, inject)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); local successor = ' {"foreign":[]}\n'
			inject(function(command, native)
				local prepared = native(command); assert(prepared == true); write(path, successor); return prepared
			end)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files), false)
			helpers.assert_eq(read(path), successor); helpers.assert_nil(read(backup)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			inject(nil)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			helpers.assert_true(require("json").is_array(require("json").decode_lossless(read(path)).foreign))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_eq(read(path), successor)
			helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("owned-storage-parent: native producer withdrawal during preparation refuses before backup", function()
		missing_parent(function(storage, files, path, backup, _, read, _, inject)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); local comparisons = 0
			local mt = { __eq = function() comparisons = comparisons + 1; return true end }
			setmetatable(storage, mt); local successor = setmetatable({}, mt)
			inject(function(command, native)
				local prepared = native(command); package.loaded["adapters.storage"] = successor; return prepared
			end)
			local accepted = storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files)
			package.loaded["adapters.storage"] = storage; setmetatable(storage, nil)
			helpers.assert_eq(accepted, false); helpers.assert_eq(comparisons, 0)
			helpers.assert_nil(read(path)); helpers.assert_nil(read(backup)); helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			inject(nil)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, files))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	helpers.it("owned-storage-parent: native file callback replacement during preparation refuses before staging", function()
		missing_parent(function(storage, files, path, backup, _, read, _, inject)
			local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
			local receipt = assert(storage.capture_owned(owner)); local calls = 0
			local producer = { delete = files.delete, write_if_unchanged = files.write_if_unchanged }
			inject(function(command, native)
				local prepared = native(command)
				producer.write_if_unchanged = function() calls = calls + 1; return true end
				return prepared
			end)
			helpers.assert_eq(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, producer), false)
			helpers.assert_eq(calls, 0); helpers.assert_nil(read(path)); helpers.assert_nil(read(backup))
			helpers.assert_eq(storage.pending_owned(owner, receipt), false)
			producer.write_if_unchanged = files.write_if_unchanged; inject(nil)
			helpers.assert_true(storage.publish_owned(owner, receipt, { a = { present = true, value = true } }, backup, producer))
			helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_true(storage.release_owned(owner))
		end)
	end)
	for _, method in ipairs({ "write_if_unchanged", "delete" }) do
		helpers.it("owned-storage-parent: source reread withdrawal of " .. method .. " refuses before staging", function()
			missing_parent(function(storage, files, path, backup, _, read, _, inject)
				local owner = {}; helpers.assert_true(storage.acquire_owned(owner, { "a" }))
				local receipt = assert(storage.capture_owned(owner))
				local producer = { delete = files.delete, write_if_unchanged = files.write_if_unchanged }
				local reader = require("infra.regular_file_reader")
				local original_open, prepared, replaced, calls = reader.open, false, false, 0
				inject(function(command, native)
					local accepted = native(command); prepared = accepted == true; return accepted
				end)
				reader.open = function(target, ...)
					if prepared and target == path and not replaced then
						replaced = true
						producer[method] = function(...)
							calls = calls + 1; return files[method](...)
						end
					end
					return original_open(target, ...)
				end
				local called, accepted = pcall(storage.publish_owned, owner, receipt,
					{ a = { present = true, value = true } }, backup, producer)
				reader.open = original_open
				-- Observe receipts/effects outside the protected publication callback.
				helpers.assert_eq(called, true); helpers.assert_eq(replaced, true)
				helpers.assert_eq(accepted, false); helpers.assert_eq(calls, 0)
				helpers.assert_nil(read(path)); helpers.assert_nil(read(backup))
				helpers.assert_eq(storage.pending_owned(owner, receipt), false)
				producer[method] = files[method]; inject(nil)
				helpers.assert_true(storage.publish_owned(owner, receipt,
					{ a = { present = true, value = true } }, backup, producer))
				helpers.assert_eq(read(path), '{"a":true}')
				helpers.assert_true(storage.restore_owned(owner, receipt)); helpers.assert_nil(read(path))
				helpers.assert_true(storage.release_owned(owner))
			end)
		end)
	end

end)

