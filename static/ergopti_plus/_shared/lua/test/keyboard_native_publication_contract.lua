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
				local published = owner.published_binding_catalogue()
				helpers.assert_eq(published.prefix, "keyboard__")
				local count = 0
				for _ in pairs(published.slots) do count = count + 1 end
				helpers.assert_eq(count, driver == "macos" and 201 or 241)
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
