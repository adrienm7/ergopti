--- _shared/lua/test/menu_native_composition.lua

--- Actual completed-row composition contract, shared by the native Lua drivers.
local M = {}
function M.register(helpers, platform)
	local function scenario(body)
		local path, handle = assert(os.tmpname()), nil
		local ok, detail = pcall(function()
			handle = assert(io.open(path, "wb"))
			assert(handle:write([[{
"probe":[{"type":"native_content","id":"badge","kind":"image"},
{"type":"native_content","id":"boundary","kind":"boundary"},
{"type":"native_content","id":"body","kind":"rows","target":true}],
"download":[{"type":"native_content","id":"download","kind":"command"},
{"type":"---","after":"download"},
{"type":"native_content","id":"body","kind":"rows","target":true}]
}]]))
			assert(handle:close()); handle = nil
			local renderer = assert(require("menu.renderer").new({ platform = platform,
				manifest_path = function() return path end, json_decode = require("json").decode,
				i18n = require("infra.i18n"), logger = helpers.make_logger_stub() }))
			local effects = 0
			local callback = function(...) effects = effects + 1; return ... end
			local resource = {}
			local badge, boundary, row = { title = "", image = resource, fn = callback }, { title = "-" }, { title = "Actual root", fn = callback }
			local slots = { badge = { badge }, boundary = { boundary }, body = { row } }
			body(renderer, slots, function() return effects end, callback, resource)
		end)
		if handle then pcall(handle.close, handle) end
		assert(os.remove(path), "composition fixture must release its exact owned file")
		if not ok then error(detail, 0) end
	end
	local function unchanged(slots, previous)
		helpers.assert_eq(#slots.body, #previous)
		for index, row in ipairs(previous) do helpers.assert_true(rawequal(slots.body[index], row)) end
	end
	helpers.describe("completed native composition: " .. platform, function()
		helpers.it("preserves actual row resource callback and target identities without construction effects", function()
			scenario(function(renderer, slots, effects, callback, resource)
				local target, badge, boundary, body = slots.body, slots.badge[1], slots.boundary[1], slots.body[1]
				local compose = assert(renderer.native_composition("probe"))
				helpers.assert_eq(compose(slots), true)
				helpers.assert_true(rawequal(slots.body, target))
				for index, row in ipairs({ badge, boundary, body }) do helpers.assert_true(rawequal(target[index], row)) end
				helpers.assert_true(rawequal(target[1].image, resource))
				helpers.assert_true(rawequal(target[1].fn, callback))
				helpers.assert_eq(effects(), 0)
				helpers.assert_eq(target[1].fn("native-ack", 19), "native-ack")
				helpers.assert_eq(effects(), 1)
			end)
		end)
		for _, present in ipairs({ false, true }) do
			helpers.it("owns the download boundary from the actual completed receipt: " .. tostring(present), function()
				scenario(function(renderer, slots, effects, callback)
					local target, body = slots.body, slots.body[1]
					local download = { title = "Actual download", fn = callback }
					local compose = assert(renderer.native_composition("download"))
					helpers.assert_eq(compose({ download = present and { download } or {}, body = target }), true)
					helpers.assert_eq(#target, present and 3 or 1)
					helpers.assert_true(rawequal(target[present and 3 or 1], body))
					if present then helpers.assert_true(rawequal(target[1], download)); helpers.assert_eq(target[2], { title = "-" }) end
					helpers.assert_eq(effects(), 0)
				end)
			end)
		end
		local corruptions = {
			["sparse receipt"] = function(slots) slots.badge[3] = slots.badge[1] end,
			["extra receipt"] = function(slots) slots.unowned = {} end,
			["missing receipt"] = function(slots) slots.boundary = nil end,
			["cross target alias"] = function(slots) slots.badge = slots.body end,
			["receipt metatable"] = function(slots) setmetatable(slots.badge, {}) end,
			["native row metatable"] = function(slots) setmetatable(slots.badge[1], {}) end,
			["image role lost"] = function(slots) slots.badge[1].image = nil end,
			["image callback lost"] = function(slots) slots.badge[1].fn = nil end,
			["boundary action"] = function(slots) slots.boundary[1].fn = function() error("must never invoke") end end,
			["DATA dialect"] = function(slots) slots.badge[1] = { label = "DATA", action = function() end } end,
			["cyclic native tree"] = function(slots) slots.body[1].fn = nil; slots.body[1].menu = slots.body end,
		}
		for name, corrupt in pairs(corruptions) do
			helpers.it("refuses all publication atomically: " .. name, function()
				scenario(function(renderer, slots, effects)
					local compose, previous = assert(renderer.native_composition("probe")), { slots.body[1] }
					corrupt(slots)
					helpers.assert_eq(compose(slots), false)
					unchanged(slots, previous)
					helpers.assert_eq(effects(), 0)
				end)
			end)
		end
		local withdrawals = {
			["source row identity"] = function(renderer, rows) rows[1] = { type = "native_content", id = "badge", kind = "image" } end,
			["source array identity"] = function(renderer, rows) renderer.get_root().probe = { rows[1], rows[2], rows[3] } end,
			["source role"] = function(_, rows) rows[1].kind = "rows" end,
			["source platform"] = function(_, rows) rows[1].platforms = { platform == "hs" and "linux" or "hs" } end,
			["source withdrawn"] = function(renderer) renderer.get_root().probe = nil end,
		}
		for name, withdraw in pairs(withdrawals) do
			helpers.it("a held composer rechecks its exact actual canonical owner: " .. name, function()
				scenario(function(renderer, slots, effects)
					local compose, previous = assert(renderer.native_composition("probe")), { slots.body[1] }
					withdraw(renderer, renderer.get_array("probe"))
					helpers.assert_eq(compose(slots), false)
					unchanged(slots, previous)
					helpers.assert_eq(effects(), 0)
				end)
			end)
		end
		local malformed = {
			["duplicate identity"] = function(rows) rows[2].id = "badge" end,
			["unknown role"] = function(rows) rows[1].kind = "unowned" end,
			["behavior hidden in role"] = function(rows) rows[1].command = "unowned" end,
			["sparse policy"] = function(rows) rows[5] = rows[1] end,
			["no target"] = function(rows) rows[3].target = nil end,
			["wrong target role"] = function(rows) rows[3].kind = "image" end,
			["early target"] = function(rows) rows[1].target = true end,
		}
		for name, corrupt in pairs(malformed) do
			helpers.it("policy is admitted before any native producer: " .. name, function()
				scenario(function(renderer, slots, effects)
					local previous = { slots.body[1] }
					corrupt(renderer.get_array("probe"))
					helpers.assert_nil(renderer.native_composition("probe"))
					unchanged(slots, previous)
					helpers.assert_eq(effects(), 0)
				end)
			end)
		end
	end)
	helpers.describe("completed native target ownership: " .. platform, function()
		for _, depth in ipairs({ 0, 2 }) do
			helpers.it("refuses a prefix submenu that aliases the target before any write: " .. depth, function()
				scenario(function(renderer, slots, effects, callback, resource)
					renderer.get_root().probe = {
						{ type = "native_content", id = "prefix", kind = "rows" },
						{ type = "native_content", id = "body", kind = "rows", target = true },
					}
					local target, body = slots.body, slots.body[1]
					local nested = target
					for _ = 1, depth do nested = { { title = "Nested", menu = nested } } end
					local parent = { title = "Parent", menu = nested }
					local prefix = { slots.badge[1], parent }
					local compose = assert(renderer.native_composition("probe"))
					helpers.assert_eq(compose({ prefix = prefix, body = target }), false)
					helpers.assert_true(rawequal(slots.body, target))
					unchanged(slots, { body })
					helpers.assert_nil(rawget(target, 2))
					helpers.assert_nil(body.menu)
					helpers.assert_true(rawequal(body.fn, callback))
					helpers.assert_true(rawequal(prefix[1].image, resource))
					helpers.assert_true(rawequal(prefix[1].fn, callback))
					helpers.assert_true(rawequal(prefix[2], parent))
					helpers.assert_true(rawequal(parent.menu, nested))
					helpers.assert_eq(effects(), 0)
				end)
			end)
		end
		helpers.it("preserves shared row resource callback and non-target submenu identities", function()
			scenario(function(renderer, slots, effects, callback, resource)
				renderer.get_root().probe = {
					{ type = "native_content", id = "prefix", kind = "rows" },
					{ type = "native_content", id = "body", kind = "rows", target = true },
				}
				local target, image, leaf = slots.body, slots.badge[1], slots.body[1]
				local shared_menu = { leaf }
				local parent = { title = "Shared parent", menu = shared_menu }
				target[1], target[2] = image, parent
				local compose = assert(renderer.native_composition("probe"))
				helpers.assert_eq(compose({ prefix = { image, parent }, body = target }), true)
				helpers.assert_true(rawequal(slots.body, target))
				helpers.assert_eq(#target, 4)
				for _, index in ipairs({ 1, 3 }) do
					helpers.assert_true(rawequal(target[index], image))
					helpers.assert_true(rawequal(target[index].image, resource))
					helpers.assert_true(rawequal(target[index].fn, callback))
				end
				for _, index in ipairs({ 2, 4 }) do
					helpers.assert_true(rawequal(target[index], parent))
					helpers.assert_true(rawequal(target[index].menu, shared_menu))
				end
				helpers.assert_true(rawequal(shared_menu[1], leaf))
				helpers.assert_eq(effects(), 0)
			end)
		end)
	end)
end
return M
