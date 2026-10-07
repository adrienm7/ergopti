--- _shared/lua/test/menu_command_literal_prefix_contract.lua

--- Verifies literal command prefixes at the genuine final caption owners.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return bytes
end

local function with_commands(driver, language, body)
	local Paths = require("infra.paths")
	local corpus = assert(Json.decode(read(Paths.shared("tests/corpus/menus/command_literal_prefixes.json"))))
	local captions = assert(Json.decode(read(Paths.shared("data/locales/" .. language .. ".json"))))
	local path = os.tmpname()
	local file
	local ok, detail = xpcall(function()
		file = assert(io.open(path, "wb"))
		assert(file:write(Json.encode({ prefix_frame = corpus.rows, legacy_frame = { corpus.legacy } })))
		assert(file:close()); file = nil
		local calls = { commands = 0, captions = 0 }
		local menu = assert(Renderer.new({ platform = driver == "macos" and "hs" or "linux",
			manifest_path = function() return path end, json_decode = Json.decode,
			i18n = { get = function(key) return captions[key] or key end,
				section = function(key) return captions[key] or key end },
			logger = { error = function() end, warn = function() end } }))
		local commands = {}
		for _, row in ipairs(corpus.rows) do
			commands[row.id] = function() calls.commands = calls.commands + 1; return "native-result" end
		end
		commands.legacy = commands.indented
		local getters = { detail = function() calls.captions = calls.captions + 1; return corpus.value end,
			blocked = function() return true end }
		body(menu, commands, getters, calls, corpus)
	end, debug.traceback)
	if file then assert(file:close()) end
	assert(os.remove(path)); if not ok then error(detail, 0) end
end

--- Appends the same shared contract to each existing native renderer owner.
--- @param helpers table Native assertion owner.
--- @param driver string Native platform root.
function M.register(helpers, driver)
	helpers.describe("literal command prefix policy", function()
		for _, code in ipairs({ "en", "fr" }) do
			local language = code
			helpers.it("keeps hand-authored selected and built images exact in " .. language, function()
				with_commands(driver, language, function(menu, commands, getters, calls, corpus)
					for index, row in ipairs(corpus.rows) do
						local selected = assert(menu.command_row("prefix_frame", row.id, commands, getters))
						helpers.assert_eq(selected.label, corpus.expected[language][index])
					end
					helpers.assert_eq(calls.captions, 2); helpers.assert_eq(calls.commands, 0)
					calls.captions = 0
					local built = menu.build("prefix_frame", "Hotstrings", {}, {}, { commands = commands, state_getters = getters }, {})
					helpers.assert_eq(#built, #corpus.rows)
					for index, row in ipairs(built) do helpers.assert_eq(row.title, corpus.expected[language][index]) end
					helpers.assert_eq(calls.captions, 2); helpers.assert_eq(calls.commands, 0)
					helpers.assert_true(rawequal(built[3].fn, commands.indented))
					helpers.assert_eq(built[3].fn(), "native-result"); helpers.assert_eq(calls.commands, 1)
				end)
			end)
			helpers.it("prefixes final template and legacy getter captions exactly once in " .. language, function()
				with_commands(driver, language, function(menu, commands, getters, calls, corpus)
					local rows = assert(menu.template_rows("prefix_frame", commands, getters, {}))
					for index, row in ipairs(rows) do helpers.assert_eq(row.label, corpus.expected[language][index]) end
					helpers.assert_eq(calls.captions, 2); helpers.assert_eq(calls.commands, 0)
					local legacy = assert(menu.template_rows("legacy_frame", commands, getters, {}))
					helpers.assert_eq(legacy[1].label, corpus.legacy_expected[language])
					helpers.assert_eq(calls.captions, 3); helpers.assert_eq(calls.commands, 0)
				end)
			end)
			helpers.it("keeps prefixed disabled stand-ins inert in " .. language, function()
				with_commands(driver, language, function(menu, commands, getters, calls, corpus)
					local item = menu.get_array("prefix_frame")[6]
					item.disabled_when = { "not_blocked" }; getters.not_blocked = function() return false end
					item.disabled_reason_key = "menu.hotstrings.personal_file_unavailable"
					local selected = assert(menu.command_row("prefix_frame", "affix", commands, getters))
					helpers.assert_eq(selected.label, corpus.disabled_expected[language])
					helpers.assert_true(selected.disabled); helpers.assert_nil(selected.action)
					helpers.assert_eq(calls.commands, 0)
					local built = menu.build("prefix_frame", "Hotstrings", {}, {}, { commands = commands, state_getters = getters }, {})
					helpers.assert_eq(built[6].title, corpus.disabled_expected[language]); helpers.assert_nil(built[6].fn)
					helpers.assert_eq(calls.commands, 0)
				end)
			end)
		end
		helpers.it("keeps platform-grey command prefixes literal without exposing a callback", function()
			with_commands(driver, "en", function(menu, commands, getters, calls, corpus)
				local item = menu.get_array("prefix_frame")[3]
				item.platforms = { "ahk" }; item.unavailable = "grey"
				item.reason_key = "menu.hotstrings.personal_file_unavailable"
				local built = menu.build("prefix_frame", "Hotstrings", {}, {}, { commands = commands, state_getters = getters }, {})
				helpers.assert_eq(built[3].title, "    Restore the default key — Unavailable")
				helpers.assert_true(built[3].disabled); helpers.assert_nil(built[3].fn)
				helpers.assert_eq(calls.commands, 0)
			end)
		end)
		for _, kind in ipairs({ "check", "group", "label", "section_header", "list", "---" }) do
			local target = kind
			helpers.it("refuses a literal prefix on " .. target .. " rows", function()
				with_commands(driver, "en", function(menu, commands, getters, calls)
					local item = menu.get_array("prefix_frame")[1]
					item.type, item.label_prefix = target, "    "
					helpers.assert_nil(menu.template_rows("prefix_frame", commands, getters, {}))
					if target == "check" then helpers.assert_nil(menu.check_row("prefix_frame", item.id, commands, getters)) end
					if target == "group" then helpers.assert_nil(menu.group_row("prefix_frame", item.id, {}, getters)) end
					helpers.assert_eq(calls.captions, 0); helpers.assert_eq(calls.commands, 0)
				end)
			end)
		end
		helpers.it("refuses a withdrawn declaration and missing real command without effects", function()
			with_commands(driver, "en", function(menu, commands, getters, calls)
				local row = menu.get_array("prefix_frame")[3]
				commands.indented = nil
				helpers.assert_nil(menu.command_row("prefix_frame", row.id, commands, getters))
				helpers.assert_nil(menu.template_rows("prefix_frame", commands, getters, {}))
				menu.get_root().prefix_frame = nil
				helpers.assert_nil(menu.command_row("prefix_frame", row.id, commands, getters))
				helpers.assert_nil(menu.template_rows("prefix_frame", commands, getters, {}))
				helpers.assert_eq(calls.captions, 0); helpers.assert_eq(calls.commands, 0)
			end)
		end)
		for _, specimen in ipairs({ { "boolean", false }, { "number", 7 }, { "table", {} }, { "null", assert(Json.decode_lossless("null")) },
			{ "newline", "\n" }, { "tab", "\t" }, { "NUL", "\0" }, { "DEL", string.char(127) },
			{ "isolated lead", string.char(194) }, { "surrogate", string.char(237, 160, 128) },
			{ "out of range", string.char(244, 144, 128, 128) } }) do
			local name, value = specimen[1], specimen[2]
			helpers.it("refuses " .. name .. " before native caption or callback delivery", function()
				with_commands(driver, "en", function(menu, commands, getters, calls)
					local item = menu.get_array("prefix_frame")[6]
					item.label_prefix = value
					helpers.assert_nil(menu.command_row("prefix_frame", "affix", commands, getters))
					helpers.assert_nil(menu.template_rows("prefix_frame", commands, getters, {}))
					helpers.assert_eq(calls.captions, 0); helpers.assert_eq(calls.commands, 0)
				end)
			end)
		end
	end)
end

return M
