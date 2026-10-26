--- _shared/lua/test/menu_parent_source_contract.lua

--- ==============================================================================
--- MODULE: Menu Parent Source Contract
--- DESCRIPTION:
--- Hand-written manifests pin what the shared parent admission accepts for the
--- Debug, Configuration, Metrics and About sections, what it refuses, and which
--- later change of the direct parent row it reports. Both drivers replay it
--- against the one shared body.
--- ==============================================================================

local M = {}

local SECTIONS = {
	{ id = "debug", children = "debug_menu" },
	{ id = "configuration", children = "configuration_menu" },
	{ id = "metrics", children = "metrics_menu" },
	{ id = "about", children = "about_menu" },
}

--- A renderer with the three functions the admission requires.
--- @param root table|nil Root returned by get_root.
--- @param get_root function|nil Replaces get_root.
--- @return table renderer
local function renderer_of(root, get_root)
	return {
		get_root = get_root or function() return root end,
		build = function() end,
		group_row = function() end,
	}
end

--- Builds a plain root declaring one section.
--- @param section table Entry of SECTIONS.
--- @return table root
local function plain_root(section)
	return {
		top_level = {
			{ type = "group", id = "other", i18n = "menu.other", rows = {} },
			{ type = "group", id = section.id, i18n = "menu." .. section.id .. ".title", rows = {} },
		},
		[section.children] = { { id = "child", type = "command", i18n = "menu.child" } },
	}
end

--- The parent row of a plain root.
local function parent_of(root, section)
	return root.top_level[2]
end

--- Registers the shared pure admission contract in the actual driver suites.
--- @param helpers table The registered driver assertion owner.
function M.register(helpers)
	local ParentSource = require("menu.frames.parent_source")
	helpers.describe("the menu parent source admission", function()
		for _, section in ipairs(SECTIONS) do
			helpers.it("admits a plain " .. section.id .. " parent and sees it unchanged", function()
				local root = plain_root(section)
				local got_root, top, children, parent, fields =
					ParentSource.read(renderer_of(root), "linux", section.id)
				helpers.assert_true(got_root == root and top == root.top_level and children == root[section.children])
				helpers.assert_true(parent == parent_of(root, section))
				helpers.assert_eq(ParentSource.unchanged(parent, fields), true)
			end)

			helpers.it("refuses a " .. section.id .. " structure that is not plain", function()
				local function refused(mutate, platform)
					local root = plain_root(section)
					mutate(root, parent_of(root, section))
					return ParentSource.read(renderer_of(root), platform or "linux", section.id) == nil
				end
				helpers.assert_eq(refused(function(root) root[section.children] = nil end), true)
				helpers.assert_eq(refused(function(root) root.top_level = nil end), true)
				helpers.assert_eq(refused(function(root) setmetatable(root, {}) end), true)
				helpers.assert_eq(refused(function(root) root[section.children].extra = {} end), true)
				helpers.assert_eq(refused(function(root) root[section.children][1] = "text" end), true)
				helpers.assert_eq(refused(function(_, parent) parent.type = "command" end), true)
				helpers.assert_eq(refused(function(_, parent) parent.i18n = "" end), true)
				helpers.assert_eq(refused(function(_, parent) parent.rows = nil end), true)
				helpers.assert_eq(refused(function(_, parent) parent.rows = { sparse = {} } end), true)
				helpers.assert_eq(refused(function(root)
					root.top_level[#root.top_level + 1] = { type = "group", id = section.id, i18n = "menu.x", rows = {} }
				end), true)
				helpers.assert_eq(refused(function(root) root.top_level[1] = "text" end), true)
				helpers.assert_eq(refused(function(_, parent) parent.platforms = { "hs" } end), true)
				helpers.assert_eq(refused(function(_, parent) parent.platforms = { 7 } end), true)
				helpers.assert_eq(refused(function(_, parent) parent.platforms = { [2] = "linux" } end), true)
				helpers.assert_eq(refused(function(_, parent) parent.platforms = { "hs", "linux" } end, "windows"), true)
			end)

			helpers.it("admits a " .. section.id .. " parent restricted to the asked platform", function()
				local root = plain_root(section)
				parent_of(root, section).platforms = { "hs", "linux" }
				helpers.assert_not_nil((ParentSource.read(renderer_of(root), "hs", section.id)))
				helpers.assert_not_nil((ParentSource.read(renderer_of(root), "linux", section.id)))
				helpers.assert_nil((ParentSource.read(renderer_of(root), "windows", section.id)))
			end)

			helpers.it("refuses a renderer that lacks get_root, build or group_row for " .. section.id, function()
				local root = plain_root(section)
				for _, missing in ipairs({ "get_root", "build", "group_row" }) do
					local renderer = renderer_of(root)
					renderer[missing] = nil
					helpers.assert_nil((ParentSource.read(renderer, "linux", section.id)))
				end
				helpers.assert_nil((ParentSource.read(nil, "linux", section.id)))
				helpers.assert_nil((ParentSource.read(renderer_of(root, function() return nil end), "linux", section.id)))
			end)

			helpers.it("reports a change of the " .. section.id .. " parent row", function()
				local function changed(mutate)
					local root = plain_root(section)
					local _, _, _, parent, fields = ParentSource.read(renderer_of(root), "linux", section.id)
					mutate(parent)
					return ParentSource.unchanged(parent, fields)
				end
				helpers.assert_eq(changed(function(parent) parent.i18n = "menu.other" end), false)
				helpers.assert_eq(changed(function(parent) parent.extra = true end), false)
				helpers.assert_eq(changed(function(parent) parent.rows = {} end), false)
				helpers.assert_eq(changed(function(parent) parent.type = nil end), false)
				helpers.assert_eq(changed(function() end), true)
			end)
		end

		helpers.it("lets get_root raise for Debug, Configuration and About but not for Metrics", function()
			local function raising() error("manifest unreadable") end
			for _, id in ipairs({ "debug", "configuration", "about" }) do
				helpers.assert_true(not (pcall(ParentSource.read, renderer_of(nil, raising), "linux", id)))
			end
			local ok, root = pcall(ParentSource.read, renderer_of(nil, raising), "linux", "metrics")
			helpers.assert_true(ok)
			helpers.assert_nil(root)
		end)

		helpers.it("requires a child and a plain label for About only", function()
			local about = SECTIONS[4]
			local empty = plain_root(about)
			empty[about.children] = {}
			helpers.assert_nil((ParentSource.read(renderer_of(empty), "linux", "about")))
			local prefixed = plain_root(about)
			parent_of(prefixed, about).label_prefix = "x"
			helpers.assert_nil((ParentSource.read(renderer_of(prefixed), "linux", "about")))
			for _, section in ipairs({ SECTIONS[1], SECTIONS[2], SECTIONS[3] }) do
				local root = plain_root(section)
				root[section.children] = {}
				parent_of(root, section).label_prefix = "x"
				helpers.assert_not_nil((ParentSource.read(renderer_of(root), "linux", section.id)))
			end
		end)

		helpers.it("raises on an unknown section instead of guessing one", function()
			helpers.assert_true(not (pcall(ParentSource.read, renderer_of({}), "linux", "hotstrings")))
		end)

		helpers.it("checks raw dense arrays without metamethods", function()
			helpers.assert_eq(ParentSource.dense({}, true), true)
			helpers.assert_eq(ParentSource.dense({ {}, {} }, true), true)
			helpers.assert_eq(ParentSource.dense({ "a" }, false), true)
			helpers.assert_eq(ParentSource.dense({ "a" }, true), false)
			helpers.assert_eq(ParentSource.dense({ [2] = {} }, true), false)
			helpers.assert_eq(ParentSource.dense({ a = 1 }, false), false)
			helpers.assert_eq(ParentSource.dense({ [1.5] = true }, false), false)
			helpers.assert_eq(ParentSource.dense(setmetatable({}, {}), false), false)
			helpers.assert_eq(ParentSource.dense(nil, false), false)
		end)
	end)
end

return M
