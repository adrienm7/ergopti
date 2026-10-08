--- _shared/lua/test/menu_numbered_caption_contract.lua

--- Explicit numbered scalar policy, exercised by both genuine native Lua bindings.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")

local function with_frame(driver, format, body)
	local path = os.tmpname()
	local file
	local ok, err = xpcall(function()
		local row = {type = "command", id = "native_action", i18n = "contract.numbered",
			caption_getter = "native_value", caption_format = "numbered"}
		file = assert(io.open(path, "wb")); assert(file:write(Json.encode({frame = {row}})))
		assert(file:close()); file = nil
		local menu = assert(Renderer.new({platform = driver == "macos" and "hs" or "linux",
			manifest_path = function() return path end, json_decode = Json.decode,
			i18n = {get = function(key) return key == "contract.numbered" and format or key end,
				section = function() return {} end},
			logger = {error = function() end, warn = function() end}}))
		local effects = {commands = 0}
		local commands = {native_action = function() effects.commands = effects.commands + 1; return "native-terminal" end}
		local getters = {native_value = function() return "Native% $& {1}" end}
		body(menu, commands, getters, effects)
	end, debug.traceback)
	if file then assert(file:close()) end
	assert(os.remove(path)); if not ok then error(err, 0) end
end

--- Appends independent policy subjects to the current already registered native renderer owner.
function M.register(helpers, driver)
	helpers.describe("explicit numbered scalar caption policy (numbered-caption-contract)", function()
		for _, vector in ipairs({
			{format = "Caption {1}", expected = "Caption Native% $& {1}"},
			{format = "50% %s {1} / {1}", expected = "50% %s Native% $& {1} / Native% $& {1}"},
			{format = "Empty ({1})", value = "", expected = "Empty ()"},
		}) do
			local case = vector
			helpers.it("preserves literal and repeated original numbered value for " .. case.format .. " (numbered-caption-contract)", function()
				with_frame(driver, case.format, function(menu, commands, getters, effects)
					if case.value ~= nil then getters.native_value = function() return case.value end end
					local selected = assert(menu.command_row("frame", "native_action", commands, getters))
					helpers.assert_eq(selected.label, case.expected)
					local rows = assert(menu.template_rows("frame", commands, getters, {}))
					helpers.assert_eq(rows[1].label, case.expected)
					local built = menu.build("frame", "Agent", {}, {}, {commands = commands, state_getters = getters}, {})
					helpers.assert_eq(built[1].title, case.expected)
					helpers.assert_eq(effects.commands, 0)
					helpers.assert_eq(rows[1].action(), "native-terminal")
					helpers.assert_eq(effects.commands, 1)
				end)
			end)
		end
		for _, format in ipairs({"Caption", "Caption {2}", "Caption {1} {2}", "Caption {{1}}", "Caption {1", "Caption {1}}"}) do
			local text = format
			helpers.it("refuses unsupported original numbered grammar " .. text .. " (numbered-caption-contract)", function()
				with_frame(driver, text, function(menu, commands, getters, effects)
					helpers.assert_nil(menu.command_row("frame", "native_action", commands, getters))
					helpers.assert_nil(menu.template_rows("frame", commands, getters, {}))
					helpers.assert_eq(effects.commands, 0)
				end)
			end)
		end
		for _, kind in ipairs({"foreign mode", "vector", "affix", "native source", "prefix", "missing getter", "wrong value", "throws", "control", "invalid utf8"}) do
			local case = kind
			helpers.it("refuses " .. case .. " numbered ownership before publication (numbered-caption-contract)", function()
				with_frame(driver, "Caption {1}", function(menu, commands, getters, effects)
					local item = menu.get_array("frame")[1]
					if case == "foreign mode" then item.caption_format = "foreign"
					elseif case == "vector" then item.caption_getters = {"native_value"}
					elseif case == "affix" then item.caption_layout = "suffix"; item.caption_joiner = " "
					elseif case == "native source" then item.caption_source = "native"
					elseif case == "prefix" then item.label_prefix = "!"
					elseif case == "missing getter" then getters.native_value = nil
					elseif case == "wrong value" then getters.native_value = function() return {} end
					elseif case == "throws" then getters.native_value = function() error("native caption reader refused") end
					elseif case == "control" then getters.native_value = function() return "bad\nvalue" end
					else getters.native_value = function() return string.char(0xFF) end end
					helpers.assert_nil(menu.command_row("frame", "native_action", commands, getters))
					helpers.assert_nil(menu.template_rows("frame", commands, getters, {}))
					helpers.assert_eq(effects.commands, 0)
				end)
			end)
		end
		helpers.it("hands off the exact existing completed numbered parent (numbered-caption-contract)", function()
			with_frame(driver, "50% %s {1} / {1}", function(menu, _, getters, effects)
				local item = menu.get_array("frame")[1]; item.type = "group"; item.id = "native_parent"
				local finished = {{title = "existing native child"}}
				local selected = assert(menu.group_row("frame", "native_parent", finished, getters))
				helpers.assert_eq(selected.label, "50% %s Native% $& {1} / Native% $& {1}")
				helpers.assert_true(rawequal(selected.submenu, finished))
				local raw = {{label = "existing native child"}}
				local rows = assert(menu.template_rows("frame", {}, getters, {native_parent = raw}))
				helpers.assert_true(rawequal(rows[1].items, raw))
				local built = menu.build("frame", "Agent", {}, {native_parent = function() return {menu = finished} end},
					{commands = {}, state_getters = getters}, {})
				helpers.assert_eq(built[1].title, selected.label)
				helpers.assert_true(rawequal(built[1].menu, finished))
				helpers.assert_eq(effects.commands, 0)
			end)
		end)
		helpers.it("retains the exact default percent formatter and literal default numbered text (numbered-caption-contract)", function()
			with_frame(driver, "Value %s / %%", function(menu, commands, getters)
				menu.get_array("frame")[1].caption_format = nil
				helpers.assert_eq(menu.template_rows("frame", commands, getters, {})[1].label, "Value Native% $& {1} / %")
			end)
			with_frame(driver, "Caption {1}", function(menu, commands, getters)
				menu.get_array("frame")[1].caption_format = nil
				helpers.assert_eq(menu.template_rows("frame", commands, getters, {})[1].label, "Caption {1}")
			end)
		end)
	end)
end

return M
