--- _shared/lua/test/storage_owned_contract.lua

--- ==============================================================================
--- MODULE: Storage Owned-Alias Protocol Contract
--- DESCRIPTION:
--- Pins the backend-independent half of the Storage port's owned-alias protocol
--- (storage_owned.lua) against a modelled adapter on both Lua runners, and
--- checks that the driver's real adapter publishes the shared gates rather
--- than a retyped copy.
--- ==============================================================================

local M = {}
local Owned = require("storage_owned")
local json = require("json")

local SUBJECT = "tests.virtual.storage_owned_subject"
local SHARED_METHODS = { "acquire_owned", "release_owned", "pending_owned", "forget_owned" }

--- Builds one modelled adapter and its owned state.
--- @param hooks table|nil admit/quiet/live switches.
--- @return table adapter Module table registered under SUBJECT.
--- @return table owned Shared protocol state.
--- @return table logged Error lines the protocol reported.
local function build(hooks)
	local adapter, logged = {}, {}
	for _, name in ipairs({ "capture_owned", "publish_owned", "restore_owned", "set", "delete", "clear" }) do
		adapter[name] = function() return true end
	end
	local switches = hooks or {}
	local owned = Owned.new({
		name = SUBJECT, module = adapter, log = "tests.storage_owned",
		logical_key = function(key) return key:sub(1, 1) ~= "!" end,
		logger = { error = function(_, template, ...) logged[#logged + 1] = string.format(template, ...) end },
		admit = function() return switches.admit ~= false end,
		quiet = function() return switches.quiet ~= false end,
		live = function() return switches.live ~= false end,
	})
	adapter.acquire_owned, adapter.release_owned = owned.acquire, owned.release
	adapter.pending_owned, adapter.forget_owned = owned.pending, owned.forget
	return adapter, owned, logged
end

--- Runs body with the modelled adapter loaded, restoring package.loaded after.
--- @param hooks table|nil Hook switches, mutable by body.
--- @param body function Receives adapter, owned, logged and hooks.
local function with_adapter(hooks, body)
	local previous = package.loaded[SUBJECT]
	hooks = hooks or {}
	local adapter, owned, logged = build(hooks)
	package.loaded[SUBJECT] = adapter
	local ok, failure = xpcall(body, debug.traceback, adapter, owned, logged, hooks)
	package.loaded[SUBJECT] = previous
	if not ok then error(failure, 0) end
end

--- Records one receipt the way an adapter's capture does.
--- @param owned table
--- @param owner table
--- @return table receipt
--- @return table record
local function capture(owned, owner)
	local gate = assert(owned.gates[owner])
	gate.sequence = gate.sequence + 1
	local receipt = {}
	local record = { owner = owner, keys = Owned.copy(gate.keys), epoch = gate.epoch, sequence = gate.sequence,
		pending = false, methods = owned.methods() }
	owned.receipts[receipt] = record
	return receipt, record
end

--- Registers the protocol vectors in a driver suite.
--- @param helpers table Driver test API.
function M.register(helpers)
	helpers.describe("shared storage owned-alias protocol (storage-owned-protocol)", function()
		helpers.it("copies only finite, plain, dense values and compares their native kinds", function()
			local source = { list = json.array({ 1, 2 }), nested = { flag = false } }
			local copy = Owned.copy(source)
			helpers.assert_true(copy ~= source and copy.nested ~= source.nested, "a detached copy")
			helpers.assert_true(Owned.equal(copy, source))
			helpers.assert_true(json.is_array(copy.list), "an array stays an array")
			for _, bad in ipairs({ 0 / 0, math.huge, setmetatable({}, {}), { 1, nil, 3 }, { 1, key = 2 }, function() end }) do
				helpers.assert_eq(pcall(Owned.copy, bad), false, "refuses " .. tostring(bad))
			end
			local cyclic = {}; cyclic.self = cyclic
			helpers.assert_eq(pcall(Owned.copy, cyclic), false, "refuses a cycle")
			helpers.assert_eq(Owned.equal(json.array({}), {}), false, "an empty array is not an empty object")
			helpers.assert_eq(Owned.equal(json.null, false), false)
			helpers.assert_eq(Owned.cell_equal({ present = false }, { present = true, value = false }), false)
			helpers.assert_true(Owned.cell_equal({ present = false }, { present = false, value = 1 }), "absence ignores value")
		end)

		helpers.it("refuses an invalid adapter declaration", function()
			local base = { name = SUBJECT, module = {}, logical_key = function() return true end,
				logger = { error = function() end }, log = "x" }
			helpers.assert_true(pcall(Owned.new, base))
			for field, value in pairs({ name = "", module = false, logical_key = false, logger = {}, log = "",
				admit = true, extra = true }) do
				local options = {}
				for key, child in pairs(base) do options[key] = child end
				options[field] = value
				helpers.assert_eq(pcall(Owned.new, options), false, "refuses " .. field)
			end
		end)

		helpers.it("acquires a dense, unique, logical alias set once per owner", function()
			with_adapter(nil, function(adapter, owned)
				local owner, other = {}, {}
				helpers.assert_eq(adapter.acquire_owned("owner", { "a" }), false, "a non-table owner")
				for _, list in ipairs({ {}, { "a", "a" }, { "a", nil, "c" }, { "a", key = "b" }, { "!a" }, { "" }, { "a\0b" },
					setmetatable({ "a" }, {}) }) do
					helpers.assert_eq(adapter.acquire_owned(owner, list), false, "refuses an invalid alias list")
				end
				helpers.assert_true(adapter.acquire_owned(owner, { "b", "a" }))
				helpers.assert_eq(owned.gates[owner].keys, { "a", "b" }, "sorted keys")
				helpers.assert_true(rawequal(owned.aliases.a, owner))
				helpers.assert_eq(adapter.acquire_owned(owner, { "c" }), false, "one gate per owner")
				helpers.assert_eq(adapter.acquire_owned(other, { "b", "c" }), false, "an overlapping alias")
				helpers.assert_true(adapter.acquire_owned(other, { "c" }))
			end)
		end)

		helpers.it("releases only after pending() settles and keeps its exact identity", function()
			with_adapter(nil, function(adapter, owned)
				local owner = { pending = function() return true end }
				helpers.assert_true(adapter.acquire_owned(owner, { "a" }))
				helpers.assert_eq(adapter.release_owned(owner), false, "pending compensation")
				owner.pending = function() error("modelled pending refusal") end
				helpers.assert_eq(adapter.release_owned(owner), false, "a throwing pending()")
				local replaced = function() return false end
				owner.pending = function() owner.pending = replaced; return false end
				helpers.assert_eq(adapter.release_owned(owner), false, "a pending() replaced during the call")
				owner.pending = replaced
				owned.gates[owner].debt = {}
				helpers.assert_eq(adapter.release_owned(owner), false, "unsettled native debt")
				owned.gates[owner].debt = nil
				helpers.assert_true(adapter.release_owned(owner))
				helpers.assert_nil(owned.aliases.a)
				helpers.assert_nil(owned.gates[owner])
				helpers.assert_eq(adapter.release_owned(owner), false, "nothing left to release")
			end)
		end)

		helpers.it("grants authority only to the receipt's owner, gate and sequence", function()
			with_adapter(nil, function(_, owned)
				local owner, other = {}, {}
				helpers.assert_true(owned.acquire(owner, { "a" }))
				helpers.assert_true(owned.acquire(other, { "b" }))
				local receipt, record = capture(owned, owner)
				local gate = owned.authority(owner, receipt, true)
				helpers.assert_true(rawequal(gate, owned.gates[owner]))
				helpers.assert_nil(owned.authority(other, receipt, true), "a foreign owner")
				helpers.assert_nil(owned.authority(owner, {}, true), "a forged receipt")
				owned.gates[owner].busy = true
				helpers.assert_nil(owned.authority(owner, receipt, false), "a busy gate")
				owned.gates[owner].busy = false
				owned.gates[owner].debt = {}
				helpers.assert_nil(owned.authority(owner, receipt, false), "another receipt's debt")
				owned.gates[owner].debt = record
				helpers.assert_type(owned.authority(owner, receipt, false), "table", "this receipt's own debt")
				owned.gates[owner].debt = nil
				capture(owned, owner)
				helpers.assert_nil(owned.authority(owner, receipt, true), "a later capture supersedes it for publishing")
				helpers.assert_type(owned.authority(owner, receipt, false), "table", "restore keeps its authority")
				record.used = true
				helpers.assert_nil(owned.authority(owner, receipt, true), "a used receipt")
			end)
		end)

		helpers.it("detaches update cells and refuses aliases outside the owner's gate", function()
			with_adapter(nil, function(_, owned)
				local owner = {}
				helpers.assert_true(owned.acquire(owner, { "a", "b" }))
				local value = { 1, 2 }
				local detached = owned.updates(owner, { a = { present = true, value = value }, b = { present = false } })
				helpers.assert_type(detached, "table")
				helpers.assert_true(detached.a.value ~= value, "a detached value")
				for _, updates in ipairs({ { c = { present = false } }, { a = { present = true } }, { a = { present = false, value = 1 } },
					{ a = { present = true, value = 1, extra = 1 } }, { a = { present = "yes" } }, setmetatable({}, {}) }) do
					helpers.assert_nil(owned.updates(owner, updates), "refuses an invalid update")
				end
			end)
		end)

		helpers.it("refuses owned work while a backend hook declines", function()
			with_adapter(nil, function(adapter, owned, _, hooks)
				local owner = {}
				hooks.admit = false
				helpers.assert_eq(adapter.acquire_owned(owner, { "a" }), false, "admit() refuses acquisition")
				hooks.admit = nil
				hooks.quiet = false
				helpers.assert_eq(adapter.acquire_owned(owner, { "a" }), false, "quiet() refuses acquisition")
				hooks.quiet = nil
				helpers.assert_true(adapter.acquire_owned(owner, { "a" }))
				local receipt, record = capture(owned, owner)
				hooks.admit = false
				helpers.assert_nil(owned.authority(owner, receipt, true), "admit() refuses authority")
				hooks.admit = nil
				hooks.live = false
				helpers.assert_nil(owned.authority(owner, receipt, true), "live() refuses authority")
				helpers.assert_eq(owned.live(record), false, "live() refuses a pinned record")
				hooks.live = nil
				helpers.assert_true(owned.live(record))
			end)
		end)

		helpers.it("pins the adapter's methods and refuses a replaced one or module", function()
			with_adapter(nil, function(adapter, owned)
				local methods = owned.methods()
				helpers.assert_true(rawequal(methods.acquire_owned, adapter.acquire_owned))
				helpers.assert_nil(methods.set_many, "an optional method the adapter lacks")
				adapter.set_many = function() end
				helpers.assert_true(rawequal(owned.methods().set_many, adapter.set_many), "an optional method it has")
				local record = { methods = methods }
				helpers.assert_true(owned.live(record))
				local publish = adapter.publish_owned
				adapter.publish_owned = function() end
				helpers.assert_eq(owned.live(record), false, "a replaced method")
				adapter.publish_owned = publish
				local files = { write = function() end }
				record.file_owner, record.file_methods = files, { write = files.write }
				helpers.assert_true(owned.live(record))
				files.write = function() end
				helpers.assert_eq(owned.live(record), false, "a replaced file capability")
				record.file_owner = nil
				package.loaded[SUBJECT] = {}
				helpers.assert_eq(owned.live(record), false, "a replaced adapter module")
				package.loaded[SUBJECT] = adapter
			end)
		end)

		helpers.it("finalizes a released journal once and keeps only a weak owner tombstone", function()
			with_adapter(nil, function(adapter, owned)
				local owner = { pending = function() return false end }
				helpers.assert_true(adapter.acquire_owned(owner, { "a" }))
				local receipt, record = capture(owned, owner)
				helpers.assert_eq(adapter.forget_owned(owner, receipt), false, "a held gate")
				helpers.assert_true(adapter.release_owned(owner))
				helpers.assert_eq(adapter.forget_owned("owner", receipt), false, "a non-table owner")
				helpers.assert_eq(adapter.forget_owned({}, receipt), false, "a foreign owner")
				record.pending = true
				helpers.assert_true(adapter.pending_owned(owner, receipt))
				helpers.assert_eq(adapter.forget_owned(owner, receipt), false, "unsettled debt")
				record.pending = false
				helpers.assert_eq(adapter.pending_owned(owner, receipt), false)
				owner.pending = function() return true end
				helpers.assert_eq(adapter.forget_owned(owner, receipt), false, "pending compensation")
				helpers.assert_true(rawequal(record.owner, owner), "a refusal keeps the journal's owner")
				owner.pending = function() return false end
				helpers.assert_true(adapter.forget_owned(owner, receipt))
				helpers.assert_nil(record.owner, "the journal detached its owner")
				helpers.assert_true(owned.receipts[receipt].forgotten)
				helpers.assert_true(adapter.forget_owned(owner, receipt), "idempotent for the same owner")
				helpers.assert_eq(adapter.forget_owned({}, receipt), false, "never for another owner")
			end)
		end)

		helpers.it("guards a native step against reentry and reports a throw as a refusal", function()
			with_adapter(nil, function(_, owned, logged)
				local gate = { busy = false }
				local seen
				local result, cells = owned.guard(gate, function() seen = gate.busy; return "token", "cells" end)
				helpers.assert_eq(seen, true, "busy while the step runs")
				helpers.assert_eq(gate.busy, false)
				helpers.assert_eq(result, "token")
				helpers.assert_eq(cells, "cells")
				helpers.assert_eq(owned.guard(gate, function() error("modelled native throw") end), false)
				helpers.assert_eq(gate.busy, false)
				helpers.assert_eq(#logged, 1)
				helpers.assert_true(logged[1]:find("modelled native throw", 1, true) ~= nil)
			end)
		end)
	end)
end

--- Checks that the driver's real Storage adapter publishes the shared gates.
--- @param helpers table Driver test API.
function M.register_adapter(helpers)
	helpers.describe("the Storage adapter uses the shared owned-alias protocol (storage-owned-protocol)", function()
		helpers.it("adapters.storage installs the shared gates", function()
			local storage = require("adapters.storage")
			for _, method in ipairs(SHARED_METHODS) do
				local fn = rawget(storage, method)
				helpers.assert_type(fn, "function", method)
				local source = debug.getinfo(fn, "S").source
				helpers.assert_true(source:find("storage_owned.lua", 1, true) ~= nil,
					method .. " must come from storage_owned.lua, not " .. source)
			end
		end)
	end)
end

return M
