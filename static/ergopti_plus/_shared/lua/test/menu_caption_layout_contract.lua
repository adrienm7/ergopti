--- _shared/lua/test/menu_caption_layout_contract.lua

--- Proves declared inert affixes through physical source and real locale data.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a")); assert(file:close())
	return content
end

local function with_layout(driver, language, scenario)
	local Paths = require("infra.paths")
	local corpus = assert(Json.decode(read(Paths.shared("tests/corpus/menus/inert_caption_layouts.json"))))
	local captions = assert(Json.decode(read(Paths.shared("data/locales/" .. language .. ".json"))))
	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	assert(file:write(Json.encode({ layout_frame = corpus.rows,
		omit_layout = { { type = "include", section = "layout_frame", on_refusal = "omit_presentation" } },
		status_layout = { { type = "list", id = "native", status_rows = { unavailable = corpus.rows } } } })))
	assert(file:close())
	local calls = 0
	local menu = assert(Renderer.new({ platform = driver == "macos" and "hs" or "linux",
		manifest_path = function() return path end, json_decode = Json.decode,
		i18n = { get = function(key) return captions[key] or key end,
			section = function(key) return "§ " .. (captions[key] or key) .. " §" end },
		logger = { warn = function() end, error = function() end } }))
	local getters = { native_detail = function() calls = calls + 1; return corpus.value end }
	local ok, detail = xpcall(function() scenario(menu, getters, corpus, function() return calls end) end, debug.traceback)
	assert(os.remove(path))
	if not ok then error(detail, 0) end
end

--- Registers the same actual factory boundary in both native owning modules.
--- @param helpers table Native assertions.
--- @param driver string Native driver root.
function M.register(helpers, driver)
	helpers.describe("declared inert caption layouts", function()
		for _, code in ipairs({ "en", "fr" }) do
			local language = code
			helpers.it("preserves exact literal prefixes, suffixes and values in " .. language, function()
				with_layout(driver, language, function(menu, getters, corpus, count)
					local rows = assert(menu.template_rows("layout_frame", {}, getters, {}))
					helpers.assert_eq(rows, { { label = corpus.expected[language][1], disabled = true },
						{ label = corpus.expected[language][2], disabled = true } })
					helpers.assert_eq(count(), 2)
					local native = menu.render_rows(rows, "layout-child")
					helpers.assert_eq(native[1].title, corpus.expected[language][1])
					helpers.assert_eq(native[2].title, corpus.expected[language][2])
					helpers.assert_eq(native[1].disabled, true)
					helpers.assert_eq(native[2].disabled, true)
					helpers.assert_nil(native[1].fn)
					helpers.assert_nil(native[2].fn)
				end)
			end)
		end
		for _, name in ipairs({ "layout", "numeric layout", "missing joiner", "numeric joiner", "control joiner",
			"missing getter", "header layout", "command layout", "unknown key", "format key" }) do
			local case = name
			helpers.it("refuses " .. case .. " before the caption getter", function()
				with_layout(driver, "en", function(menu, getters, _, count)
					local row = menu.get_array("layout_frame")[1]
					if case == "layout" then row.caption_layout = "infix"
					elseif case == "numeric layout" then row.caption_layout = 7
					elseif case == "missing joiner" then row.caption_joiner = nil
					elseif case == "numeric joiner" then row.caption_joiner = 7
					elseif case == "control joiner" then row.caption_joiner = "\n"
					elseif case == "missing getter" then row.caption_getter = nil
					elseif case == "header layout" then row.type = "section_header"
					elseif case == "command layout" then row.type = "command"
					elseif case == "unknown key" then row.i18n = "future.unknown_caption"
					else row.i18n = "menu.llm.hw_header" end
					helpers.assert_nil(menu.template_rows("layout_frame", {}, getters, {}))
					helpers.assert_eq(count(), 0)
				end)
			end)
		end
		for _, name in ipairs({ "missing", "nil", "false", "number", "table", "throw" }) do
			local case = name
			helpers.it("refuses " .. case .. " native layout receipt", function()
				with_layout(driver, "en", function(menu, getters)
					if case == "missing" then getters.native_detail = nil
					else getters.native_detail = function()
						if case == "false" then return false end
						if case == "number" then return 7 end
						if case == "table" then return {} end
						if case == "throw" then error("native caption refusal") end
					end end
					local called, rows = pcall(menu.template_rows, "layout_frame", {}, getters, {})
					helpers.assert_true(not called or rows == nil)
				end)
			end)
		end
		helpers.it("keeps omission and status getter-free", function()
			with_layout(driver, "en", function(menu, getters, _, count)
				helpers.assert_eq(menu.template_rows("omit_layout", {}, getters, {}), {})
				helpers.assert_nil(menu.status_rows("status_layout", "native", "unavailable"))
				helpers.assert_eq(count(), 0)
			end)
		end)
		helpers.it("keeps newly introduced metadata physical on an unrelated include", function()
			with_layout(driver, "en", function(menu)
				local root = menu.get_root()
				root.metadata_frame = {
					{ type = "include", section = "layout_frame", on_refusal = "omit_presentation" },
					{ type = "list", id = "native" },
				}
				local calls, actions = 0, 0
				setmetatable(root.metadata_frame[1], { __index = function(_, key)
					if key == "caption_layout" or key == "caption_joiner" then calls = calls + 1 end
				end })
				local leaf = { label = "Actual native leaf", action = function() actions = actions + 1 end }
				local ok, rows = pcall(menu.template_rows, "metadata_frame", {}, {}, { native = function() return { leaf } end })
				helpers.assert_true(ok, "actual factory admission retains the unrelated include contract")
				helpers.assert_true(rows and rawequal(rows[#rows], leaf), "the genuine native leaf survives")
				helpers.assert_eq(calls, 0, "new metadata inspection must not invoke inherited getters")
				helpers.assert_eq(actions, 0, "presentation never executes the native action")
			end)
		end)
	end)
end

return M
