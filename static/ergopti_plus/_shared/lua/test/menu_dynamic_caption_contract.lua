--- _shared/lua/test/menu_dynamic_caption_contract.lua

--- Proves inert formatted captions through real files, locale data and renderer.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

local function with_renderer(helpers, driver, language, scenario)
	local corpus = Json.decode(read(require("infra.paths").shared("tests/corpus/menus/inert_dynamic_captions.json")))
	local captions = Json.decode(read(require("infra.paths").shared("data/locales/" .. language .. ".json")))
	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	assert(file:write(Json.encode({ format_frame = corpus.rows,
		omission = { { type = "include", section = "format_frame", on_refusal = "omit_presentation" },
			{ type = "list", id = "native" } },
		status_owner = { { type = "list", id = "native", status_rows = { unavailable = corpus.rows } } } })))
	assert(file:close())
	local calls, errors = 0, {}
	local logger = { warn = function() end }
	logger.error = function(_, message) errors[#errors + 1] = message end
	local i18n = { get = function(key) return captions[key] or key end,
		section = function(key) return "§ " .. (captions[key] or key) .. " §" end }
	local menu = assert(Renderer.new({ platform = driver == "macos" and "hs" or "linux",
		manifest_path = function() return path end, json_decode = Json.decode, i18n = i18n, logger = logger }))
	local getters = { native_detail = function() calls = calls + 1; return corpus.value end }
	local ok, detail = xpcall(function()
		scenario(menu, getters, corpus, captions, errors, function() return calls end, i18n)
	end, debug.traceback)
	local removed = os.remove(path)
	assert(removed, "dynamic caption fixture cleanup refused")
	if not ok then error(detail, 0) end
end

--- Registers genuine shared-renderer controls in both existing native suites.
--- @param helpers table Native assertions and real shared path owner.
--- @param driver string macos or linux.
function M.register(helpers, driver)
	helpers.describe("inert dynamic caption ownership", function()
		for _, language in ipairs({ "en", "fr" }) do
			helpers.it("keeps literal values, disabled posture and header decoration in " .. language, function()
				with_renderer(helpers, driver, language, function(menu, getters, corpus, _, _, count)
					local rows = assert(menu.template_rows("format_frame", {}, getters, {}))
					helpers.assert_eq(rows, { { label = corpus.expected[language][1], disabled = true },
						{ label = "§ " .. corpus.expected[language][2] .. " §", disabled = true } })
					helpers.assert_eq(count(), 2)
					local native = menu.render_rows(rows, "dynamic-inert")
					helpers.assert_eq(native[1].disabled, true)
					helpers.assert_nil(native[1].fn)
					helpers.assert_nil(native[2].fn)
				end)
			end)
		end
		for _, case in ipairs({ "missing", "nil", "number", "table", "false", "throw" }) do
			helpers.it("refuses " .. case .. " native caption receipts", function()
				with_renderer(helpers, driver, "en", function(menu, getters)
					if case == "missing" then getters.native_detail = nil
					else getters.native_detail = function()
						if case == "number" then return 7 end
						if case == "table" then return {} end
						if case == "false" then return false end
						if case == "throw" then error("native caption unavailable") end
					end end
					local called, rows = pcall(menu.template_rows, "format_frame", {}, getters, {})
					helpers.assert_true(not called or rows == nil)
				end)
			end)
		end
		for _, field in ipairs({ "command", "action", "checked_when", "items" }) do
			helpers.it("refuses behavior metadata " .. field .. " before getter work", function()
				with_renderer(helpers, driver, "en", function(menu, getters, _, _, _, count)
					menu.get_array("format_frame")[1][field] = "foreign"
					helpers.assert_nil(menu.template_rows("format_frame", {}, getters, {}))
					helpers.assert_eq(count(), 0)
				end)
			end)
		end
		for _, case in ipairs({ "empty getter", "numeric getter", "missing header identity", "list caption" }) do
			helpers.it("refuses malformed caption metadata " .. case, function()
				with_renderer(helpers, driver, "en", function(menu, getters, _, _, _, count)
					local row = menu.get_array("format_frame")[1]
					if case == "empty getter" then row.caption_getter = ""
					elseif case == "numeric getter" then row.caption_getter = 7
					elseif case == "missing header identity" then row.type, row.id = "section_header", nil
					else row.type = "list" end
					helpers.assert_nil(menu.template_rows("format_frame", {}, getters, {}))
					helpers.assert_eq(count(), 0)
				end)
			end)
		end
		helpers.it("does not admit dynamic captions as omittable presentation or inert status", function()
			with_renderer(helpers, driver, "en", function(menu, getters, _, _, _, count)
				local leaf = { label = "Native leaf", action = function() return "native receipt" end }
				local rows = assert(menu.template_rows("omission", {}, getters, { native = function() return { leaf } end }))
				helpers.assert_eq(rows, { leaf })
				helpers.assert_true(rawequal(rows[1], leaf))
				helpers.assert_eq(count(), 0)
				helpers.assert_nil(menu.status_rows("status_owner", "native", "unavailable"))
				helpers.assert_eq(count(), 0)
			end)
		end)
		for index = 1, 7 do
			helpers.it("distinguishes supported slots from literal escapes in hand case " .. index, function()
				with_renderer(helpers, driver, "en", function(menu, getters, corpus, captions)
					local case = corpus.format_cases[index]
					captions["menu.llm.model_backend"], captions["menu.llm.hw_header"] = case.format, case.format
					local rows = menu.template_rows("format_frame", {}, getters, {})
					if case.slot then
						helpers.assert_eq(rows, { { label = case.expected, disabled = true },
							{ label = "§ " .. case.expected .. " §", disabled = true } })
					else helpers.assert_nil(rows) end
				end)
			end)
		end
		for _, format in ipairs({ "static", "%%s" }) do
			helpers.it("refuses decorator-manufactured slots for source " .. format, function()
				with_renderer(helpers, driver, "en", function(menu, getters, _, captions, _, count, i18n)
					local declaration = menu.get_array("format_frame")
					local header = declaration[2]
					declaration[1], declaration[2] = header, nil
					captions[header.i18n] = format
					i18n.section = function(key) return "literal %s | " .. captions[key] end
					local row = menu.template_rows("format_frame", {}, getters, {})
					helpers.assert_nil(row)
					helpers.assert_eq(count(), 0, "raw caption refuses before native getter")
					captions[header.i18n] = "[%s]"
					local repaired = assert(menu.template_rows("format_frame", {}, getters, {}))
					helpers.assert_eq(repaired, { { label = "literal 50% / $1 / %s | [50% / $1 / %s]", disabled = true } })
					helpers.assert_eq(count(), 1)
				end)
			end)
		end

	end)
end

return M
