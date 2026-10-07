--- _shared/lua/test/menu_command_group_affix_contract.lua

--- Verifies explicit declared affixes using physical translated source and native data.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a")); assert(file:close())
	return content
end

local function with_frame(driver, language, body)
	local Paths = require("infra.paths")
	local corpus = assert(Json.decode(read(Paths.shared("tests/corpus/menus/command_group_caption_layouts.json"))))
	local captions = assert(Json.decode(read(Paths.shared("data/locales/" .. language .. ".json"))))
	local path = os.tmpname()
	local file = assert(io.open(path, "wb")); assert(file:write(Json.encode({ affix_frame = corpus.rows }))); assert(file:close())
	local source_reads = {}
	local menu = assert(Renderer.new({ platform = driver == "macos" and "hs" or "linux",
		manifest_path = function() return path end, json_decode = Json.decode,
		i18n = { get = function(key) source_reads[#source_reads + 1] = key; return captions[key] or key end,
			section = function(key) return captions[key] or key end },
		logger = { error = function() end, warn = function() end } }))
	local counts = { captions = 0, commands = 0, children = 0, source_reads = source_reads }
	local commands = { personal_legacy_shortcut = function() counts.commands = counts.commands + 1; return "native-result" end }
	commands.shortcut_suffix = commands.personal_legacy_shortcut
	local paused, enabled = false, false
	local getters = { personal_default_label = function() counts.captions = counts.captions + 1; return corpus.value end,
		personal_shortcut_label = function() counts.captions = counts.captions + 1; return corpus.value end,
		not_paused = function() return not paused end, enabled = function() return enabled end }
	local child = { { title = "Finished native child", fn = commands.personal_legacy_shortcut } }
	local children = { personal_default_parent = function() counts.children = counts.children + 1; return { { label = "Child", action = commands.personal_legacy_shortcut } } end }
	children.default_suffix = children.personal_default_parent
	local ok, detail = xpcall(function()
		body(menu, getters, commands, child, children, counts, corpus,
			function(value) paused = value end, function(value) enabled = value end)
	end, debug.traceback)
	assert(os.remove(path)); if not ok then error(detail, 0) end
end

--- Appends the same renderer contract to the existing native owning tests.
--- @param helpers table Native assertions.
--- @param driver string Native platform root.
function M.register(helpers, driver)
	helpers.describe("declared command and group affixes", function()
		for _, code in ipairs({ "en", "fr" }) do
			local language = code
			helpers.it("projects exact selected captions and finished child identity in " .. language, function()
				with_frame(driver, language, function(menu, getters, commands, child, _, counts, corpus)
					for index, descriptor in ipairs(corpus.rows) do
						local row = descriptor.type == "group" and menu.group_row("affix_frame", descriptor.id, child, getters)
							or menu.command_row("affix_frame", descriptor.id, commands, getters)
						helpers.assert_eq(row.label, corpus.expected[language][index])
						if descriptor.type == "group" then helpers.assert_true(rawequal(row.submenu, child)) end
					end
					helpers.assert_eq(counts.captions, 4); helpers.assert_eq(counts.commands, 0); helpers.assert_eq(counts.children, 0)
				end)
			end)
			helpers.it("materializes template captions once with native callbacks withheld in " .. language, function()
				with_frame(driver, language, function(menu, getters, commands, _, children, counts, corpus)
					local rows = assert(menu.template_rows("affix_frame", commands, getters, children))
					for index, row in ipairs(rows) do helpers.assert_eq(row.label, corpus.expected[language][index]) end
					helpers.assert_eq(counts.captions, 4); helpers.assert_eq(counts.children, 2); helpers.assert_eq(counts.commands, 0)
				end)
			end)
			helpers.it("binds exact main-build captions before native group builders in " .. language, function()
				with_frame(driver, language, function(menu, getters, commands, child, _, counts, corpus)
					local groups = { personal_default_parent = function() helpers.assert_eq(counts.captions, 1); counts.children = counts.children + 1; return child end,
						default_suffix = function() helpers.assert_eq(counts.captions, 3); counts.children = counts.children + 1; return child end }
					local rows = menu.build("affix_frame", "Hotstrings", {}, groups, { commands = commands, state_getters = getters }, {})
					for index, row in ipairs(rows) do helpers.assert_eq(row.title, corpus.expected[language][index]) end
					helpers.assert_true(rawequal(rows[1].menu, child)); helpers.assert_true(rawequal(rows[3].menu, child))
					helpers.assert_true(rawequal(rows[2].fn, commands.personal_legacy_shortcut))
					helpers.assert_eq(counts.captions, 4); helpers.assert_eq(counts.children, 2); helpers.assert_eq(counts.commands, 0)
				end)
			end)
		end
		helpers.it("keeps empty native String details genuine and preserves selected checked false", function()
			with_frame(driver, "en", function(menu, getters, _, child)
				getters.personal_default_label = function() return "" end
				local row = assert(menu.group_row("affix_frame", "personal_default_parent", child, getters))
				helpers.assert_eq(row.label, "Default category: "); helpers.assert_eq(row.checked, false)
			end)
		end)
		helpers.it("retains the original current pause gate and native command return", function()
			with_frame(driver, "en", function(menu, getters, commands, _, _, counts, _, set_paused)
				local row = assert(menu.command_row("affix_frame", "personal_legacy_shortcut", commands, getters))
				helpers.assert_eq(counts.commands, 0); helpers.assert_eq(row.action(), "native-result")
				set_paused(true); helpers.assert_eq(row.action(), false); helpers.assert_eq(counts.commands, 1)
				local paused_row = assert(menu.command_row("affix_frame", "personal_legacy_shortcut", commands, getters))
				helpers.assert_true(paused_row.disabled); helpers.assert_eq(counts.commands, 1)
			end)
		end)
		helpers.it("keeps the existing disabled reason stand-in without a native callback", function()
			with_frame(driver, "en", function(menu, getters, commands, _, _, counts, _, set_paused)
				menu.get_array("affix_frame")[2].disabled_reason_key = "menu.hotstrings.personal_file_unavailable"
				set_paused(true)
				local row = assert(menu.command_row("affix_frame", "personal_legacy_shortcut", commands, getters))
				helpers.assert_eq(row.label, "Shortcut: Win + Native 🦀 %s 50% — Unavailable")
				helpers.assert_true(row.disabled); helpers.assert_nil(row.action)
				helpers.assert_eq(counts.captions, 1); helpers.assert_eq(counts.commands, 0)
			end)
		end)
		for _, name in ipairs({ "missing layout", "bad layout", "missing joiner", "numeric joiner", "control joiner", "missing getter", "unknown source", "format source", "check kind" }) do
			local case = name
			helpers.it("refuses " .. case .. " before group builder or caption data", function()
				with_frame(driver, "en", function(menu, getters, commands, child, children, counts)
					local row = menu.get_array("affix_frame")[1]
					if case == "missing layout" then row.caption_layout = nil
					elseif case == "bad layout" then row.caption_layout = "infix"
					elseif case == "missing joiner" then row.caption_joiner = nil
					elseif case == "numeric joiner" then row.caption_joiner = 7
					elseif case == "control joiner" then row.caption_joiner = "\n"
					elseif case == "missing getter" then row.caption_getter = nil
					elseif case == "unknown source" then row.i18n = "future.unowned_caption"
					elseif case == "format source" then row.i18n = "menu.llm.hw_header"
					else row.type = "check" end
					helpers.assert_nil(menu.group_row("affix_frame", "personal_default_parent", child, getters))
					helpers.assert_nil(menu.template_rows("affix_frame", commands, getters, children))
					local builders = { personal_default_parent = function() counts.children = counts.children + 1; return child end }
					menu.get_array("affix_frame")[2].platforms = { "foreign" }; menu.get_array("affix_frame")[3].platforms = { "foreign" }; menu.get_array("affix_frame")[4].platforms = { "foreign" }
					menu.build("affix_frame", "Hotstrings", {}, builders, { commands = commands, state_getters = getters }, {})
					helpers.assert_eq(counts.captions, 0); helpers.assert_eq(counts.children, 0); helpers.assert_eq(counts.commands, 0)
				end)
			end)
		end
		for _, name in ipairs({ "nil", "false", "number", "table", "throw" }) do
			local case = name
			helpers.it("refuses " .. case .. " caption receipts without child publication", function()
				with_frame(driver, "en", function(menu, getters, _, child, _, counts)
					getters.personal_default_label = function()
						counts.captions = counts.captions + 1
						if case == "false" then return false elseif case == "number" then return 7
						elseif case == "table" then return {} elseif case == "throw" then error("native value refusal") end
					end
					local called, row = pcall(menu.group_row, "affix_frame", "personal_default_parent", child, getters)
					helpers.assert_true(not called or row == nil); helpers.assert_eq(counts.captions, 1); helpers.assert_eq(counts.commands, 0)
				end)
			end)
		end
		helpers.it("preserves missing and foreign command owners before data getters", function()
			with_frame(driver, "en", function(menu, getters, _, _, _, counts)
				helpers.assert_nil(menu.command_row("affix_frame", "personal_legacy_shortcut", {}, getters))
				menu.get_array("affix_frame")[2].platforms = { "foreign" }
				helpers.assert_nil(menu.command_row("affix_frame", "personal_legacy_shortcut", { personal_legacy_shortcut = function() counts.commands = counts.commands + 1 end }, getters))
				helpers.assert_eq(counts.captions, 0); helpers.assert_eq(counts.commands, 0)
			end)
		end)
		helpers.it("keeps no-layout main commands and groups getter-free", function()
			with_frame(driver, "en", function(menu, getters, commands, child, _, counts)
				for _, row in ipairs(menu.get_array("affix_frame")) do row.caption_layout = nil; row.caption_joiner = nil end
				local groups = { personal_default_parent = function() return child end, default_suffix = function() return child end }
				local rows = menu.build("affix_frame", "Hotstrings", {}, groups, { commands = commands, state_getters = getters }, {})
				helpers.assert_eq(rows[1].title, "Default category: "); helpers.assert_eq(rows[2].title, "Shortcut: Win + ")
				helpers.assert_eq(counts.captions, 0); helpers.assert_eq(counts.commands, 0)
				helpers.assert_eq(menu.command_row("affix_frame", "personal_legacy_shortcut", commands, getters).label, "Shortcut: Win + ")
				helpers.assert_nil(menu.group_row("affix_frame", "personal_default_parent", child, getters)); helpers.assert_eq(counts.captions, 0)
			end)
		end)
		helpers.it("keeps no-layout command readiness before its original translated caption read", function()
			with_frame(driver, "en", function(menu, getters, commands, _, _, counts)
				local row = menu.get_array("affix_frame")[2]; row.caption_layout = nil; row.caption_joiner = nil
				getters.not_paused = function() helpers.assert_eq(#counts.source_reads, 0); return true end
				local command = assert(menu.command_row("affix_frame", "personal_legacy_shortcut", commands, getters))
				helpers.assert_eq(command.label, "Shortcut: Win + "); helpers.assert_eq(#counts.source_reads, 1)
				helpers.assert_eq(counts.captions, 0)
			end)
		end)
		helpers.it("keeps no-layout template child acquisition before its original translated caption read", function()
			with_frame(driver, "en", function(menu, getters, commands, _, children, counts)
				local rows = menu.get_array("affix_frame"); rows[1].caption_layout = nil; rows[1].caption_joiner = nil
				children.personal_default_parent = function() helpers.assert_eq(#counts.source_reads, 0); return {} end
				assert(menu.template_rows("affix_frame", commands, getters, children))
			end)
		end)
		helpers.it("retains original no-layout template caption evaluation", function()
			with_frame(driver, "en", function(menu, getters, commands, _, children, counts)
				for _, row in ipairs(menu.get_array("affix_frame")) do row.caption_layout = nil; row.caption_joiner = nil end
				local rows = assert(menu.template_rows("affix_frame", commands, getters, children))
				helpers.assert_eq(rows[1].label, "Default category: "); helpers.assert_eq(rows[2].label, "Shortcut: Win + ")
				helpers.assert_eq(counts.captions, 4); helpers.assert_eq(counts.commands, 0)
			end)
		end)
	end)
end

return M
