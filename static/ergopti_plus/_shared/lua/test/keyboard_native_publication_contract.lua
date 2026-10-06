--- _shared/lua/test/keyboard_native_publication_contract.lua

--- ==============================================================================
--- MODULE: Native Keyboard Publication Controls
--- DESCRIPTION:
--- Handwritten source-census controls and genuine existing native catalogue
--- calls, independent of current assignments, visible groups and dispatch.
--- ==============================================================================

local M = {}

--- Restores all module identities and IO even when a control raises.
--- @param body function Disposable native control.
local function scope(body)
	local saved, previous_open = {}, io.open
	for name, value in pairs(package.loaded) do saved[name] = value end
	local okay, detail = xpcall(body, debug.traceback)
	io.open = previous_open
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not okay then error(detail, 0) end
end

--- Registers actual native acquisition and pure source-census controls.
--- @param helpers table Registered native test API.
--- @param driver string macos or linux.
function M.register(helpers, driver)
	local Publication = require("config_keyboard_publication")
	local native = "modules.shortcuts.keyboard_shortcuts"
	local prefix = driver == "macos" and "hs_ctrl_" or "ctrl_"
	local function fresh()
		package.loaded[native] = nil
		return require(native)
	end
	helpers.describe("complete native keyboard publication", function()
		helpers.it("keeps the cold accessor pure and publishes the complete private native slot space", function()
			scope(function()
				local owner = fresh()
				local previous_open = io.open
				io.open = function() error("cold accessor must not read") end
				helpers.assert_nil(owner.published_binding_catalogue())
				io.open = previous_open
				helpers.assert_eq(#owner.available_slots(prefix), 40)
				io.open = function() error("logical-only authority cannot load physical source") end
				helpers.assert_nil(owner.published_binding_catalogue(), "one source does not claim complete authority")
				io.open = previous_open
				helpers.assert_type(owner.physical_slot_descriptor("physical_none_KeyJ"), "table")
				local published = owner.published_binding_catalogue()
				helpers.assert_eq(published.prefix, "keyboard__")
				local count, physical_count = 0, 0
				for id in pairs(published.slots) do
					if id:sub(1, 9) == "physical_" then physical_count = physical_count + 1
					else count = count + 1 end
				end
				helpers.assert_eq(count, driver == "macos" and 201 or 241)
				helpers.assert_eq(physical_count, 1536, "96 registry key positions times all 16 exact modifier subsets")
				helpers.assert_eq(published.slots.physical_none_KeyJ, true)
				helpers.assert_eq(published.slots.physical_ctrl_alt_shift_super_KeyJ, true)
				helpers.assert_nil(published.slots.physical_none_KeyFuture)
				helpers.assert_eq(published.slots.magic_editor, true)
				helpers.assert_eq(published.slots[prefix .. "enter"], true)
				if driver == "linux" then
					helpers.assert_eq(published.slots.alt_shift_enter, true)
					helpers.assert_eq(published.slots.super_shift_enter, true)
				end
				published.slots[prefix .. "enter"] = nil
				published.slots.removed_key = true
				io.open = function() error("published accessor must not read") end
				helpers.assert_eq(owner.published_binding_catalogue().slots[prefix .. "enter"], true)
				helpers.assert_nil(owner.published_binding_catalogue().slots.removed_key)
				package.loaded[native] = setmetatable({}, { __eq = function() return true end, __index = owner })
				helpers.assert_nil(owner.published_binding_catalogue())
			end)
		end)
		helpers.it("withdraws a replaced compositor without invoking fabricated authority or reading either source", function()
			scope(function()
				local owner = fresh()
				helpers.assert_eq(#owner.available_slots(prefix), 40)
				helpers.assert_type(owner.physical_slot_descriptor("physical_none_KeyJ"), "table")
				local compose, open, calls, reads = Publication.compose, io.open, 0, 0
				Publication.compose = function()
					calls = calls + 1
					return { prefix = "keyboard__", slots = { physical_none_KeyFuture = true } }
				end
				io.open = function() reads = reads + 1; error("compositor withdrawal cannot read another source") end
				local replaced = owner.published_binding_catalogue()
				Publication.compose = compose
				local repaired = owner.published_binding_catalogue()
				setmetatable(Publication, { __index = function() calls = calls + 1; error("inherited compositor must not run") end })
				local inherited = owner.published_binding_catalogue()
				setmetatable(Publication, nil)
				local restored = owner.published_binding_catalogue()
				io.open = open
				helpers.assert_nil(replaced)
				helpers.assert_nil(inherited)
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(reads, 0)
				helpers.assert_eq(repaired.slots.physical_ctrl_KeyJ, true)
				helpers.assert_eq(restored.slots[prefix .. "enter"], true)
				helpers.assert_nil(restored.slots.physical_none_KeyFuture)
			end)
		end)
		helpers.it("withdraws replaced source classes through raw identity and restores only the exact classes", function()
			scope(function()
				local owner, callbacks = fresh(), 0
				helpers.assert_eq(#owner.available_slots(prefix), 40)
				local Model = require("shortcuts.physical_slots")
				local proxy = setmetatable({}, {
					__index = function() callbacks = callbacks + 1; error("replacement class must not be inherited") end,
					__eq = function() callbacks = callbacks + 1; return true end,
				})
				package.loaded["shortcuts.physical_slots"] = proxy
				local open, reads = io.open, 0
				io.open = function() reads = reads + 1; error("replacement class cannot initialize a source") end
				local admitted = pcall(owner.physical_slot_descriptor, "physical_none_KeyJ")
				package.loaded["shortcuts.physical_slots"] = Model
				io.open = open
				helpers.assert_eq(admitted, false)
				helpers.assert_type(owner.physical_slot_descriptor("physical_none_KeyJ"), "table")
				io.open = function() reads = reads + 1; error("class withdrawal must remain pure") end
				package.loaded["shortcuts.physical_slots"] = proxy
				local withdrawn = owner.published_binding_catalogue()
				package.loaded["shortcuts.physical_slots"] = Model
				local repaired = owner.published_binding_catalogue()
				package.loaded["config_keyboard_publication"] = proxy
				local wrong_compositor = owner.published_binding_catalogue()
				package.loaded["config_keyboard_publication"] = Publication
				local restored = owner.published_binding_catalogue()
				io.open = open
				helpers.assert_nil(withdrawn)
				helpers.assert_nil(wrong_compositor)
				helpers.assert_eq(callbacks, 0)
				helpers.assert_eq(reads, 0)
				helpers.assert_eq(repaired.slots.physical_ctrl_KeyJ, true)
				helpers.assert_eq(restored.slots[prefix .. "enter"], true)
			end)
		end)
		helpers.it("rejects a replaced physical constructor before reading or accepting fabricated authority", function()
			scope(function()
				local owner = fresh()
				helpers.assert_eq(#owner.available_slots(prefix), 40)
				local Model = require("shortcuts.physical_slots")
				local constructor, calls, reads = Model.new, 0, 0
				local open = io.open
				Model.new = function()
					calls = calls + 1
					return {}, function() return { prefix = "keyboard__", slots = { physical_none_KeyFuture = true } } end
				end
				io.open = function() reads = reads + 1; error("withdrawn constructor cannot initialize another source") end
				local okay = pcall(owner.physical_slot_descriptor, "physical_none_KeyJ")
				io.open, Model.new = open, constructor
				helpers.assert_eq(okay, false)
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(reads, 0)
				helpers.assert_nil(owner.published_binding_catalogue())
				helpers.assert_type(owner.physical_slot_descriptor("physical_none_KeyJ"), "table")
				helpers.assert_eq(owner.published_binding_catalogue().slots.physical_none_KeyJ, true)
			end)
		end)
		helpers.it("publishes every handwritten physical modifier vector and withdraws changed genuine method ownership", function()
			scope(function()
				local Paths = require("infra.paths")
				local Json = require("json")
				local function decoded(relative)
					local file = assert(io.open(Paths.shared(relative), "rb"))
					local body = assert(file:read("*a")); assert(file:close())
					return Json.decode(body)
				end
				local registry = decoded("data/keycodes/physical_keys.json")
				local corpus = decoded("tests/corpus/shortcuts/physical_slots.json")
				local Model = require("shortcuts.physical_slots")
				local owner, receipt = Model.new(registry)
				local original = Json.encode(registry)
				local open = io.open
				io.open = function() error("physical receipt must never read") end
				local catalogue = receipt(owner)
				for _, vector in ipairs(corpus.valid) do helpers.assert_eq(catalogue.slots[vector.slot], true) end
				for _, invalid in ipairs(corpus.invalid_slots) do helpers.assert_nil(catalogue.slots[invalid]) end
				helpers.assert_nil(receipt(setmetatable({}, { __index = owner, __eq = function() error("equality must not run") end })))
				local encode, calls = owner.encode, 0
				owner.encode = function() calls = calls + 1; return "physical_none_KeyFuture" end
				helpers.assert_nil(receipt(owner))
				helpers.assert_eq(calls, 0)
				owner.encode = encode
				local constructor = Model.new
				Model.new = function() calls = calls + 1; return owner, function() return catalogue end end
				helpers.assert_nil(receipt(owner))
				helpers.assert_eq(calls, 0)
				Model.new = constructor
				local modifiers = Model.modifiers
				Model.modifiers = function() calls = calls + 1; return { "future" } end
				helpers.assert_nil(receipt(owner))
				helpers.assert_eq(calls, 0)
				Model.modifiers = modifiers
				catalogue.slots.physical_ctrl_KeyJ = nil
				helpers.assert_eq(receipt(owner).slots.physical_ctrl_KeyJ, true)
				registry.keys.KeyJ = nil
				helpers.assert_eq(receipt(owner).slots.physical_ctrl_KeyJ, true, "the actual constructor owns an immutable snapshot")
				io.open = open
				helpers.assert_eq(original == Json.encode(registry), false, "the test mutation must actually change the caller source")
			end)
		end)
		helpers.it("withdraws every changed consumed source field and restores only the exact source", function()
			local keys = { { id = "a" }, { id = "enter", chord_key = "return" } }
			local modifiers = { "ctrl" }
			local groups = { { "ctrl_", modifiers } }
			local receipt = Publication.publish(keys, groups, "magic_editor")
			helpers.assert_eq(receipt(keys, groups, "magic_editor"), {
				prefix = "keyboard__", slots = { ctrl_a = true, ctrl_enter = true, magic_editor = true },
			})
			keys[1].id = "b"; helpers.assert_nil(receipt(keys, groups, "magic_editor")); keys[1].id = "a"
			keys[2].chord_key = "space"; helpers.assert_nil(receipt(keys, groups, "magic_editor")); keys[2].chord_key = "return"
			modifiers[1] = "alt"; helpers.assert_nil(receipt(keys, groups, "magic_editor")); modifiers[1] = "ctrl"
			groups[1][1] = "alt_"; helpers.assert_nil(receipt(keys, groups, "magic_editor")); groups[1][1] = "ctrl_"
			local original = keys[1]; keys[1] = { id = "a" }; helpers.assert_nil(receipt(keys, groups, "magic_editor")); keys[1] = original
			helpers.assert_nil(receipt(keys, groups, "another_contextual_owner"))
			helpers.assert_nil(receipt({ keys[1], keys[2] }, groups, "magic_editor"))
			helpers.assert_eq(receipt(keys, groups, "magic_editor").slots.ctrl_enter, true)
		end)
		helpers.it("preserves simultaneous case-distinct native identities without an equality fallback", function()
			local keys = { { id = "a" }, { id = "A" } }
			local groups = { { "ctrl_", { "ctrl" } } }
			local receipt = Publication.publish(keys, groups, "magic_editor")
			helpers.assert_eq(receipt(keys, groups, "magic_editor"), {
				prefix = "keyboard__", slots = { ctrl_a = true, ctrl_A = true, magic_editor = true },
			})
			local replacement = setmetatable({ keys[1], keys[2] }, { __eq = function() return true end })
			helpers.assert_nil(receipt(replacement, groups, "magic_editor"))
			keys[2].id = "a"
			helpers.assert_nil(receipt(keys, groups, "magic_editor"))
			keys[2].id = "A"
			helpers.assert_eq(receipt(keys, groups, "magic_editor").slots.ctrl_A, true)
		end)
		helpers.it("refuses malformed inventories rather than publishing a manufactured empty set", function()
			for _, keys in ipairs({ {}, { [2] = { id = "a" } }, { { id = "a" }, { id = "a" } },
				{ setmetatable({}, { __index = { id = "a" } }) },
				setmetatable({ { id = "a" } }, { __pairs = function() error("metamethod must not run") end }),
			}) do
				local okay, detail = pcall(Publication.publish, keys, { { "ctrl_", { "ctrl" } } }, "magic_editor")
				helpers.assert_eq(okay, false)
				helpers.assert_contains(tostring(detail), "config_keyboard_publication: invalid")
			end
			for _, groups in ipairs({ {}, { [2] = { "ctrl_", { "ctrl" } } },
				{ { "ctrl_", {} } }, { { "ctrl_", { "ctrl", "ctrl" } } },
				{ { "ctrl_", { "ctrl" } }, { "ctrl_", { "ctrl" } } },
			}) do
				local okay, detail = pcall(Publication.publish, { { id = "a" } }, groups, "magic_editor")
				helpers.assert_eq(okay, false)
				helpers.assert_contains(tostring(detail), "config_keyboard_publication: invalid")
			end
		end)
		if driver == "linux" then
			for _, mode in ipairs({ "nil", "false", "throw", "read_throw" }) do
				local receipt_mode = mode
				helpers.it("does not publish physical authority after an unacknowledged physical read: " .. receipt_mode, function()
					scope(function()
						local owner, previous_open, closes = fresh(), io.open, 0
						helpers.assert_eq(#owner.available_slots(prefix), 40)
						io.open = function(path, mode)
							local file = assert(previous_open(path, mode))
							return {
								read = function(_, format)
									if receipt_mode == "read_throw" then error("injected physical read refusal") end
									return file:read(format)
								end,
								close = function()
									closes = closes + 1; assert(file:close())
									if receipt_mode == "throw" then error("injected physical close refusal") end
									if receipt_mode == "false" then return false end
									if receipt_mode == "read_throw" then return true end
								end,
							}
						end
						local okay = pcall(owner.physical_slot_descriptor, "physical_none_KeyJ")
						helpers.assert_eq(okay, false)
						helpers.assert_eq(closes, 1)
						helpers.assert_nil(owner.published_binding_catalogue())
						io.open = previous_open
						helpers.assert_type(owner.physical_slot_descriptor("physical_none_KeyJ"), "table")
						helpers.assert_eq(owner.published_binding_catalogue().slots.physical_none_KeyJ, true)
					end)
				end)
			end
			for _, mode in ipairs({ "nil", "false", "throw", "read_throw" }) do
				local receipt_mode = mode
				helpers.it("refuses the actual native reader's unacknowledged completion: " .. receipt_mode, function()
					scope(function()
						local owner, previous_open, closes = fresh(), io.open, 0
						io.open = function(path, mode)
							local file = assert(previous_open(path, mode))
							return {
								read = function(_, format)
									if receipt_mode == "read_throw" then error("injected read refusal") end
									return file:read(format)
								end,
								close = function()
									closes = closes + 1; assert(file:close())
									if receipt_mode == "throw" then error("injected close refusal") end
									if receipt_mode == "false" then return false end
									if receipt_mode == "read_throw" then return true end
								end,
							}
						end
						helpers.assert_eq(owner.available_slots(prefix), {})
						helpers.assert_eq(closes, 1)
						helpers.assert_nil(owner.published_binding_catalogue())
					end)
				end)
			end
		end
	end)
end

return M
