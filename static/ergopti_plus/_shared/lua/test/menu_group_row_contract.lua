--- _shared/lua/test/menu_group_row_contract.lua

--- Preserves declared parent policy around an already completed native subtree.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")

local MANIFEST = [[{
 "checked": [{"type":"group","id":"parent","i18n":"menu.llm.title","checked_when":["enabled"]}],
 "plain": [{"type":"group","id":"parent","i18n":"menu.global.language"}],
 "compound": [{"type":"group","id":"parent","i18n":"menu.llm.title","checked_when":["enabled","ready"]}],
 "disabled": [{"type":"group","id":"parent","i18n":"menu.llm.title","disabled_when":["ready"],"disabled_reason_key":"platform_reason.shortcuts_restore_is_composed_on_macos"}],
 "foreign": [{"type":"group","id":"parent","i18n":"menu.llm.title","platforms":["ahk"]}],
 "duplicate": [{"type":"group","id":"parent","i18n":"menu.llm.title"},{"type":"group","id":"parent","i18n":"menu.global.language"}],
 "wrong": [{"type":"command","id":"parent","i18n":"menu.llm.title"}]
}]]

local function with_parent(driver, language, body)
	local Paths = require("infra.paths")
	local file = assert(io.open(Paths.shared("data/locales/" .. language .. ".json"), "rb"))
	local captions = assert(Json.decode(assert(file:read("*a"))))
	assert(file:close())
	local path = os.tmpname()
	file = assert(io.open(path, "wb")); assert(file:write(MANIFEST)); assert(file:close())
	local errors = {}
	local menu = assert(Renderer.new({ platform = driver == "macos" and "hs" or "linux",
		manifest_path = function() return path end, json_decode = Json.decode,
		i18n = { get = function(key) return captions[key] or key end,
			section = function(key) return captions[key] or key end },
		logger = { error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end,
			warn = function() end } }))
	local calls = 0
	local child = { { title = "Native action", fn = function() calls = calls + 1 end } }
	local ok, detail = xpcall(function() body(menu, child, errors, function() return calls end) end, debug.traceback)
	assert(os.remove(path))
	if not ok then error(detail, 0) end
end

--- Registers the same declared projection contract in both native owning modules.
--- @param helpers table Native assertions.
--- @param driver string Native driver root.
function M.register(helpers, driver)
	helpers.describe("declared finished group parents", function()
		for _, code in ipairs({ "en", "fr" }) do
			local language = code
			for _, value in ipairs({ true, false, "absent" }) do
				local state = value
				helpers.it("preserves singleton " .. tostring(state) .. " checked presence in " .. language, function()
					with_parent(driver, language, function(menu, child, _, count)
						local reads = 0
						local row = assert(menu.group_row("checked", "parent", child, { enabled = function()
							reads = reads + 1
							if state == "absent" then return nil end
							return state
						end }))
						helpers.assert_eq(reads, 1)
						helpers.assert_true(rawequal(row.submenu, child))
						if state == "absent" then helpers.assert_nil(row.checked)
						else helpers.assert_eq(row.checked, state) end
						local native = menu.render_rows({ row }, "parent-projection")
						helpers.assert_true(rawequal(native[1].menu, child))
						helpers.assert_true(rawequal(native[1].menu[1].fn, child[1].fn))
						helpers.assert_eq(count(), 0)
					end)
				end)
			end
			helpers.it("keeps the independently translated plain parent and genuine empty subtree in " .. language, function()
				with_parent(driver, language, function(menu)
					local empty = {}
					local row = assert(menu.group_row("plain", "parent", empty, {}))
					helpers.assert_eq(row.label, ({ en = "🌐 Language", fr = "🌐 Langue" })[language])
					helpers.assert_nil(row.checked)
					helpers.assert_true(rawequal(row.submenu, empty))
					helpers.assert_true(rawequal(menu.render_rows({ row }, "empty-parent")[1].menu, empty))
				end)
			end)
		end
		helpers.it("retains the completed depth and every native callback without materializing items", function()
			with_parent(driver, "en", function(menu, child, _, count)
				local deep = child
				for _ = 1, 8 do deep = { { title = "Completed native level", menu = deep } } end
				local row = assert(menu.group_row("plain", "parent", deep, {}))
				helpers.assert_nil(row.items)
				helpers.assert_true(rawequal(menu.render_rows({ row }, "deep-parent")[1].menu, deep))
				helpers.assert_eq(count(), 0)
			end)
		end)
		for _, name in ipairs({ "withdrawn", "wrong", "duplicate", "foreign", "missing child", "invalid id" }) do
			local case = name
			helpers.it("refuses " .. case .. " before calling state or child functions", function()
				with_parent(driver, "en", function(menu, child, _, count)
					local key, id, native = "checked", "parent", child
					if case == "withdrawn" then id = "missing"
					elseif case == "missing child" then native = false
					elseif case == "invalid id" then id = false
					else key = case end
					helpers.assert_nil(menu.group_row(key, id, native, { enabled = function() error("refused state") end }))
					helpers.assert_eq(count(), 0)
				end)
			end)
		end
		helpers.it("keeps missing checked getters false and diagnostic, and propagates thrown getters", function()
			with_parent(driver, "en", function(menu, child, errors)
				local row = assert(menu.group_row("checked", "parent", child, {}))
				helpers.assert_eq(row.checked, false)
				helpers.assert_true(#errors > 0)
				local ok = pcall(menu.group_row, "checked", "parent", child, { enabled = function() error("native state failed") end })
				helpers.assert_eq(ok, false)
			end)
		end)
		helpers.it("preserves Boolean compound short circuit and the existing public resolver", function()
			with_parent(driver, "en", function(menu, child)
				local reads = 0
				local getters = { enabled = function() reads = reads + 1; return nil end,
					ready = function() error("short circuit must retain this callback") end }
				helpers.assert_eq(assert(menu.group_row("compound", "parent", child, getters)).checked, false)
				helpers.assert_eq(reads, 1)
				helpers.assert_eq(menu.resolve_checked_when("compound", "parent", getters), false)
				helpers.assert_eq(reads, 2)
			end)
		end)
		helpers.it("forwards the existing disabled predicate and its reason without touching the subtree", function()
			with_parent(driver, "en", function(menu, child)
				local row = assert(menu.group_row("disabled", "parent", child, { ready = function() return false end }))
				helpers.assert_eq(row.disabled, true)
				helpers.assert_eq(row.disabled_reason_key, "platform_reason.shortcuts_restore_is_composed_on_macos")
				helpers.assert_true(rawequal(row.submenu, child))
			end)
		end)
	end)
end

local function with_physical_parent(driver, language, body)
	local Paths = require("infra.paths")
	local file = assert(io.open(Paths.shared("data/locales/" .. language .. ".json"), "rb"))
	local captions = assert(Json.decode(assert(file:read("*a"))))
	assert(file:close())
	local menu = assert(Renderer.new({ platform = driver == "macos" and "hs" or "linux",
		manifest_path = function() return Paths.shared("modules/menu/menu_manifest.json") end,
		json_decode = Json.decode, i18n = { get = function(key) return captions[key] or key end,
			section = function(key) return captions[key] or key end },
		logger = { error = function() end, warn = function() end } }))
	body(menu)
end

local register_previous = M.register

--- Extends the selected parent contract with the published physical caption owner.
--- @param helpers table Native assertions.
--- @param driver string Native driver root.
function M.register(helpers, driver)
	register_previous(helpers, driver)
	helpers.describe("declared parent existing caption policy", function()
		for _, code in ipairs({ "en", "fr" }) do
			local language = code
			helpers.it("reads the authentic TapHold group caption once in " .. language, function()
				with_physical_parent(driver, language, function(menu)
					local reads, calls = 0, 0
					local child = { { title = "Native child", fn = function() calls = calls + 1 end } }
					local row = assert(menu.group_row("tap_hold_key_delay_tail", "tap_hold_key_delay", child,
						{ tap_hold_key_delay_caption = function() reads = reads + 1; return "12% / 🦀" end }))
					helpers.assert_eq(row.label, ({ en = "Tap delay: 12% / 🦀", fr = "Délai de tap : 12% / 🦀" })[language])
					helpers.assert_eq(reads, 1)
					helpers.assert_true(rawequal(row.submenu, child))
					helpers.assert_eq(calls, 0)
				end)
			end)
		end
		helpers.it("refuses a missing actual caption getter and admits its explicit repaired receipt", function()
			with_physical_parent(driver, "en", function(menu)
				local child = {}
				helpers.assert_nil(menu.group_row("tap_hold_key_delay_tail", "tap_hold_key_delay", child, {}))
				local reads = 0
				local row = assert(menu.group_row("tap_hold_key_delay_tail", "tap_hold_key_delay", child,
					{ tap_hold_key_delay_caption = function() reads = reads + 1; return "30 ms" end }))
				helpers.assert_eq(row.label, "Tap delay: 30 ms")
				helpers.assert_eq(reads, 1)
				helpers.assert_true(rawequal(row.submenu, child))
			end)
		end)
		for _, name in ipairs({ "nil", "false", "number", "table" }) do
			local case = name
			helpers.it("refuses the actual " .. case .. " caption receipt", function()
				with_physical_parent(driver, "en", function(menu)
					local reads = 0
					local row = menu.group_row("tap_hold_key_delay_tail", "tap_hold_key_delay", {},
						{ tap_hold_key_delay_caption = function()
							reads = reads + 1
							if case == "false" then return false end
							if case == "number" then return 17 end
							if case == "table" then return {} end
						end })
					helpers.assert_nil(row)
					helpers.assert_eq(reads, 1)
				end)
			end)
		end
		for _, name in ipairs({ "unknown key", "unsupported affix" }) do
			local case = name
			helpers.it("refuses " .. case .. " before reading the native caption", function()
				with_physical_parent(driver, "en", function(menu)
					local declaration
					for _, item in ipairs(menu.get_array("tap_hold_key_delay_tail")) do
						if item.id == "tap_hold_key_delay" then declaration = item end
					end
					assert(declaration, "the actual caption group must be published")
					if case == "unknown key" then declaration.i18n = "future.unknown_group_caption"
					else declaration.caption_layout = "prefix"; declaration.caption_joiner = "" end
					local reads = 0
					helpers.assert_nil(menu.group_row("tap_hold_key_delay_tail", "tap_hold_key_delay", {},
						{ tap_hold_key_delay_caption = function() reads = reads + 1; return "30 ms" end }))
					helpers.assert_eq(reads, 0)
				end)
			end)
		end
		helpers.it("refuses nonstring identities without calling their tostring hooks", function()
			with_parent(driver, "en", function(menu, child)
				local calls = 0
				local foreign = setmetatable({}, { __tostring = function() calls = calls + 1; return "parent" end })
				helpers.assert_nil(menu.group_row("checked", foreign, child, {}))
				helpers.assert_nil(menu.group_row(foreign, "parent", child, {}))
				helpers.assert_eq(calls, 0)
			end)
		end)
	end)
end

return M
