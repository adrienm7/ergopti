--- _shared/lua/test/menu_layout_caption_values_contract.lua

--- Verifies ordered original-format values and genuine literal native record captions.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return bytes
end

local function with_frame(driver, language, body)
	local Paths = require("infra.paths")
	local corpus = assert(Json.decode(read(Paths.shared("tests/corpus/menus/layout_caption_values.json"))))
	local captions = assert(Json.decode(read(Paths.shared("data/locales/" .. language .. ".json"))))
	local rows = corpus.rows
	rows[2].platforms = {driver == "macos" and "hs" or "linux"}
	local path = os.tmpname()
	local file
	local ok, detail = xpcall(function()
		file = assert(io.open(path, "wb")); assert(file:write(Json.encode({frame = rows})))
		assert(file:close()); file = nil
		local menu = assert(Renderer.new({platform = rows[2].platforms[1],
			manifest_path = function() return path end, json_decode = Json.decode,
			i18n = {get = function(key) return captions[key] or key end, section = function(key) return captions[key] or key end},
			logger = {error = function() end, warn = function() end}}))
		local calls = {commands = 0, captions = 0}
		local commands = {upgrade = function() calls.commands = calls.commands + 1; return "native-terminal" end,
			native = function() calls.commands = calls.commands + 1; return false end}
		local getters = {ready = function() return true end, selected = function() return true end}
		for key, value in pairs(corpus.values) do
			local captured = value
			getters[key] = function() calls.captions = calls.captions + 1; return captured end
		end
		body(menu, commands, getters, calls, corpus)
	end, debug.traceback)
	if file then assert(file:close()) end
	assert(os.remove(path)); if not ok then error(detail, 0) end
end

--- Appends this shared contract to both existing registered native renderer owners.
function M.register(helpers, driver)
	helpers.describe("ordered caption values and literal native record data", function()
		for _, language in ipairs({"da", "de", "en", "es", "fr", "it", "nl", "no", "pl", "pt", "sv", "tr", "cs", "ar", "he", "hi", "uk", "ru", "zh", "ja", "ko"}) do
			helpers.it("preserves independent original-format captions through selected, template and built rows in " .. language, function()
				with_frame(driver, language, function(menu, commands, getters, calls, corpus)
					local selected = assert(menu.command_row("frame", "upgrade", commands, getters))
					helpers.assert_eq(selected.label, corpus.expected[language][1])
					local native = assert(menu.check_row("frame", "native", commands, getters))
					helpers.assert_eq(native.label, corpus.expected[language][2])
					helpers.assert_eq(native.checked, true)
					local rows = assert(menu.template_rows("frame", commands, getters, {}))
					helpers.assert_eq(#rows, 2)
					for index, row in ipairs(rows) do helpers.assert_eq(row.label, corpus.expected[language][index]) end
					local built = menu.build("frame", "Layout", {}, {}, {commands = commands, state_getters = getters}, {})
					helpers.assert_eq(#built, 2)
					for index, row in ipairs(built) do helpers.assert_eq(row.title, corpus.expected[language][index]) end
					helpers.assert_eq(calls.commands, 0)
					helpers.assert_eq(rows[1].action(), "native-terminal")
					helpers.assert_eq(rows[2].action(), false)
					helpers.assert_eq(calls.commands, 2)
				end)
			end)
		end
		for _, invalid in ipairs({"empty", "sparse", "named", "wrong_name", "missing_getter", "mixed_scalar", "mixed_layout", "wrong_value", "missing_value", "throws"}) do
			helpers.it("refuses " .. invalid .. " ordered caption values before publication", function()
				with_frame(driver, "en", function(menu, commands, getters, calls)
					local item = menu.get_array("frame")[1]
					if invalid == "empty" then item.caption_getters = {}
					elseif invalid == "sparse" then item.caption_getters = {[1] = "scope", [3] = "latest"}
					elseif invalid == "named" then item.caption_getters = {name = "scope"}
					elseif invalid == "wrong_name" then item.caption_getters = {false}
					elseif invalid == "missing_getter" then getters.old = nil
					elseif invalid == "mixed_scalar" then item.caption_getter = "scope"
					elseif invalid == "mixed_layout" then item.caption_layout = "prefix"; item.caption_joiner = ""
					elseif invalid == "wrong_value" then getters.old = function() return false end
					elseif invalid == "throws" then getters.old = function() error("native reader refused") end
					else getters.old = function() return nil end end
					helpers.assert_nil(menu.template_rows("frame", commands, getters, {}))
					helpers.assert_eq(calls.commands, 0)
				end)
			end)
		end
		for _, invalid in ipairs({"empty", "boolean", "table", "control", "invalid_utf8", "translation", "decoration", "throws"}) do
			helpers.it("refuses " .. invalid .. " native record caption without inventing a translation", function()
				with_frame(driver, "en", function(menu, commands, getters, calls)
					local row = menu.get_array("frame")[2]
					if invalid == "translation" then row.i18n = "menu.layout.title"
					elseif invalid == "decoration" then row.caption_layout = "prefix"; row.caption_joiner = ""
					elseif invalid == "throws" then getters.native = function() error("native reader refused") end
					else
						local values = {empty = "", boolean = false, table = {}, control = "Native\nCaption", invalid_utf8 = string.char(0xFF)}
						getters.native = function() return values[invalid] end
					end
					helpers.assert_nil(menu.template_rows("frame", commands, getters, {}))
					helpers.assert_eq(calls.commands, 0)
				end)
			end)
		end
		helpers.it("hidden other-driver caption rows require no native data or mutation owners", function()
			with_frame(driver, "en", function(menu)
				local other = driver == "macos" and "linux" or "hs"
				for _, row in ipairs(menu.get_array("frame")) do row.platforms = {other}; row.unavailable = "hide" end
				local rows = assert(menu.template_rows("frame", {}, {}, {}))
				helpers.assert_eq(#rows, 0)
			end)
		end)
		helpers.it("disabled reason stand-ins retain the fully formatted native values", function()
			with_frame(driver, "en", function(menu, commands, getters, calls, corpus)
				local row = menu.get_array("frame")[1]
				row.disabled_when = {"available"}; row.disabled_reason_key = "platform_reason.layout_bundle_and_menubar_are_macos"
				getters.available = function() return false end
				local built = menu.build("frame", "Layout", {}, {}, {commands = commands, state_getters = getters}, {})
				helpers.assert_eq(built[1].title, corpus.expected.en[1] .. " — macOS only")
				helpers.assert_eq(built[1].disabled, true)
				helpers.assert_nil(built[1].fn)
				helpers.assert_eq(calls.commands, 0)
			end)
		end)
		helpers.it("a genuine native record parent retains its completed subtree identity and literal caption", function()
			with_frame(driver, "en", function(menu, commands, getters, calls, corpus)
				local row = {type = "group", id = "native_parent", caption_source = "native", caption_getter = "native", unavailable = "hide"}
				menu.get_array("frame")[3] = row
				local finished = {{title = "native child", fn = function() return "actual-child-terminal" end}}
				local parent = assert(menu.group_row("frame", "native_parent", finished, getters))
				helpers.assert_eq(parent.label, corpus.expected.en[2])
				helpers.assert_true(rawequal(parent.submenu, finished))
				local raw = {{label = "native child", action = finished[1].fn}}
				local template = assert(menu.template_rows("frame", commands, getters, {native_parent = raw}))
				helpers.assert_eq(template[3].label, corpus.expected.en[2])
				helpers.assert_true(rawequal(template[3].items, raw))
				local built = menu.build("frame", "Layout", {}, {native_parent = function() return {menu = finished} end}, {commands = commands, state_getters = getters}, {})
				helpers.assert_eq(built[3].title, corpus.expected.en[2])
				helpers.assert_true(rawequal(built[3].menu, finished))
				helpers.assert_eq(calls.commands, 0)
			end)
		end)
		for _, invalid in ipairs({"missing", "wrong_value", "control", "invalid_utf8", "translation", "layout", "foreign", "wrong_kind"}) do
			helpers.it("refuses " .. invalid .. " native parent authority before publishing its genuine child", function()
				with_frame(driver, "en", function(menu, _, getters, calls)
					local row = {type = "group", id = "native_parent", caption_source = "native", caption_getter = "native", unavailable = "hide"}
					menu.get_array("frame")[3] = row
					if invalid == "missing" then getters.native = nil
					elseif invalid == "wrong_value" then getters.native = function() return {} end
					elseif invalid == "control" then getters.native = function() return "bad\ncaption" end
					elseif invalid == "invalid_utf8" then getters.native = function() return string.char(0xFF) end
					elseif invalid == "translation" then row.i18n = "menu.layout.title"
					elseif invalid == "layout" then row.caption_layout = "prefix"; row.caption_joiner = ""
					elseif invalid == "foreign" then row.caption_source = "foreign"
					else row.type = "command" end
					helpers.assert_nil(menu.group_row("frame", "native_parent", {{title = "actual child"}}, getters))
					helpers.assert_eq(calls.commands, 0)
				end)
			end)
		end
		helpers.it("retained native callbacks refuse withdrawn declaration and preserve exact native results", function()
			with_frame(driver, "en", function(menu, commands, getters, calls)
				local rows = assert(menu.template_rows("frame", commands, getters, {}))
				menu.get_array("frame")[2].id = "withdrawn_native_owner"
				helpers.assert_eq(rows[2].action(), false)
				helpers.assert_eq(calls.commands, 0)
			end)
		end)
	end)
end

return M
