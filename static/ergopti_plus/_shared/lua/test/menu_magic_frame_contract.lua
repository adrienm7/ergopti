--- _shared/lua/test/menu_magic_frame_contract.lua

--- ==============================================================================
--- MODULE: Menu Magic Trigger Frame Contract
--- DESCRIPTION:
--- Hand-written frames pin what the shared snapshot admits, what it refuses, and
--- which later change of the declared frame withholds publication. Both drivers
--- replay it against the one shared body.
--- ==============================================================================

local M = {}

--- Builds a renderer whose root is the given table, counting `get_root` calls.
--- @param root table Root returned by the renderer.
--- @return table renderer
local function renderer_of(root)
	local renderer = { reads = 0 }
	function renderer.get_root()
		renderer.reads = renderer.reads + 1
		return root
	end
	return renderer
end

--- Builds a plain three-row frame the way the manifest declares it.
--- @return table frame
local function plain_frame()
	return {
		{ id = "a", i18n = "menu.a", platforms = { "hs", "linux" } },
		{ id = "b", i18n = "menu.b" },
		{ id = "c", i18n = "menu.c", checked_when = { "flag" } },
	}
end

--- Registers the shared pure frame contract in the actual driver suites.
--- @param helpers table The registered driver assertion owner.
function M.register(helpers)
	local MagicFrame = require("menu.frames.magic_frame")
	helpers.describe("the magic trigger frame snapshot", function()
		helpers.it("admits a plain frame of the expected size and sees it unchanged", function()
			local root = { hotstrings_magic_trigger_frame = plain_frame() }
			local renderer = renderer_of(root)
			local snapshot = MagicFrame.snapshot(renderer)
			helpers.assert_not_nil(snapshot)
			helpers.assert_eq(MagicFrame.current(renderer, snapshot), true)
		end)

		helpers.it("honours a named frame and its own expected size", function()
			local root = { hotstrings_magic_trigger_reset = { { id = "reset" } } }
			local renderer = renderer_of(root)
			helpers.assert_nil(MagicFrame.snapshot(renderer))
			local snapshot = MagicFrame.snapshot(renderer, "hotstrings_magic_trigger_reset", 1)
			helpers.assert_not_nil(snapshot)
			helpers.assert_eq(MagicFrame.current(renderer, snapshot), true)
		end)

		helpers.it("refuses a frame that is missing, short, long or sparse", function()
			local frame = plain_frame()
			frame[4] = { id = "d" }
			helpers.assert_nil(MagicFrame.snapshot(renderer_of({ hotstrings_magic_trigger_frame = frame })))
			helpers.assert_nil(MagicFrame.snapshot(renderer_of({ hotstrings_magic_trigger_frame = { { id = "a" } } })))
			helpers.assert_nil(MagicFrame.snapshot(renderer_of({})))
			helpers.assert_nil(MagicFrame.snapshot(renderer_of(nil)))
			local keyed = plain_frame()
			keyed.extra = { id = "x" }
			helpers.assert_nil(MagicFrame.snapshot(renderer_of({ hotstrings_magic_trigger_frame = keyed })))
		end)

		helpers.it("refuses a frame carrying a function, a metatable or a nested table", function()
			local with_function = plain_frame()
			with_function[2].callback = function() end
			helpers.assert_nil(MagicFrame.snapshot(renderer_of({ hotstrings_magic_trigger_frame = with_function })))
			local with_meta = plain_frame()
			setmetatable(with_meta[1], {})
			helpers.assert_nil(MagicFrame.snapshot(renderer_of({ hotstrings_magic_trigger_frame = with_meta })))
			local nested = plain_frame()
			nested[1].platforms = { "hs", { "deep" } }
			helpers.assert_nil(MagicFrame.snapshot(renderer_of({ hotstrings_magic_trigger_frame = nested })))
		end)

		helpers.it("withholds publication once a captured field or identity changed", function()
			local function changed(mutate)
				local root = { hotstrings_magic_trigger_frame = plain_frame() }
				local renderer = renderer_of(root)
				local snapshot = MagicFrame.snapshot(renderer)
				mutate(root.hotstrings_magic_trigger_frame, root)
				return MagicFrame.current(renderer, snapshot)
			end
			helpers.assert_eq(changed(function(frame) frame[2].i18n = "menu.other" end), false)
			helpers.assert_eq(changed(function(frame) frame[1].platforms[2] = "macos" end), false)
			helpers.assert_eq(changed(function(frame) frame[3].extra = true end), false)
			helpers.assert_eq(changed(function(frame) frame[1].i18n = nil end), false)
			helpers.assert_eq(changed(function(frame) frame[2] = { id = "b", i18n = "menu.b" } end), false)
			helpers.assert_eq(changed(function(frame) frame[1].platforms = { "hs", "linux" } end), false)
			helpers.assert_eq(changed(function(frame) frame[4] = {} end), false)
			helpers.assert_eq(changed(function(_, root) root.hotstrings_magic_trigger_frame = plain_frame() end), false)
		end)

		helpers.it("refuses a missing snapshot and a swapped root", function()
			local renderer = renderer_of({ hotstrings_magic_trigger_frame = plain_frame() })
			helpers.assert_eq(MagicFrame.current(renderer, nil), false)
			local snapshot = MagicFrame.snapshot(renderer)
			local other = renderer_of({ hotstrings_magic_trigger_frame = plain_frame() })
			helpers.assert_eq(MagicFrame.current(other, snapshot), false)
		end)
	end)
end

return M
