--- _shared/lua/test/menu_disabled_reasons_contract.lua

--- Replays the shared disabled-reasons corpus through the genuine renderer: a
--- greyed row names the first cause whose getter answers true (a configuration
--- saved by a newer version) instead of its generic reason.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return bytes
end

--- The short form the renderers draw: the text before the first colon.
local function head(text)
	local cut = nil
	for _, mark in ipairs({ ":", "\239\188\154" }) do
		local at = text:find(mark, 1, true)
		if at and (cut == nil or at < cut) then cut = at end
	end
	return ((cut and text:sub(1, cut - 1) or text):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function with_menu(driver, body)
	local Paths = require("infra.paths")
	local corpus = assert(Json.decode(read(Paths.shared("tests/corpus/menus/disabled_reasons.json"))))
	local captions = assert(Json.decode(read(Paths.shared("data/locales/en.json"))))
	local path = os.tmpname()
	local file
	local ok, detail = xpcall(function()
		file = assert(io.open(path, "wb"))
		assert(file:write(Json.encode({ reasons_frame = corpus.rows })))
		assert(file:close()); file = nil
		local menu = assert(Renderer.new({ platform = driver == "macos" and "hs" or "linux",
			manifest_path = function() return path end, json_decode = Json.decode,
			i18n = { get = function(key) return captions[key] or key end,
				section = function(key) return captions[key] or key end },
			logger = { error = function() end, warn = function() end } }))
		body(menu, corpus, captions)
	end, debug.traceback)
	if file then assert(file:close()) end
	assert(os.remove(path)); if not ok then error(detail, 0) end
end

--- Appends the shared contract to a native renderer owner.
--- @param helpers table Native assertion owner.
--- @param driver string Native platform root.
function M.register(helpers, driver)
	helpers.describe("disabled reasons name the cause of a greyed row", function()
		with_menu(driver, function(_, corpus)
			for _, case in ipairs(corpus.cases) do
				local scenario = case
				helpers.it("draws " .. scenario.name, function()
					with_menu(driver, function(menu, data, captions)
						local calls = 0
						local commands = {
							power = function() calls = calls + 1 end,
							restore = function() calls = calls + 1 end,
						}
						local getters = { ready = function() return scenario.ready end }
						if scenario.newer ~= "absent" then getters.newer = function() return scenario.newer end end
						local built = menu.build("reasons_frame", "LLM", {}, {},
							{ commands = commands, state_getters = getters }, {})
						if scenario.reason == "refused" then
							helpers.assert_eq(#built, 0, "a cause without a getter refuses the row")
							return
						end
						helpers.assert_eq(#built, #data.rows)
						for index, row in ipairs(data.rows) do
							local label = captions[row.i18n]
							if scenario.reason == "none" then
								helpers.assert_eq(built[index].title, label)
								helpers.assert_true(type(built[index].fn) == "function", "a ready row runs")
							else
								helpers.assert_eq(built[index].title, label .. " — " .. head(captions[scenario.reason]))
								helpers.assert_true(built[index].disabled == true)
								helpers.assert_nil(built[index].fn, "a greyed row has nothing to run")
							end
						end
						helpers.assert_eq(calls, 0)
					end)
				end)
			end
		end)
	end)
end

return M
