--- _shared/lua/test/configuration_parent_contract.lua
--- Replays structural source ownership through the actual complete native tray.
local M = {}

--- Registers native parent controls without reconstructing Configuration child rows.
--- @param helpers table Existing native test assertions and registration.
--- @param fixture function Actual native builder/renderer fixture.
--- @param corpus table Independent physical caption and order images.
--- @param platform string Native platform token.
function M.register(helpers, fixture, corpus, platform)
	local function find(rows, label)
		for _, row in ipairs(rows) do if row.title == label then return row end end
	end
	local function with_case(body)
		fixture(function(renderer, build, callbacks, locale, getter_observer)
			local root = assert(renderer.get_root())
			local child, top, parent = root.configuration_menu, root.top_level
			for _, row in ipairs(top) do if row.id == "configuration" then parent = row end end
			assert(parent)
			local original_build, original_group = renderer.build, renderer.group_row
			local observed = { builds = 0, parents = 0, effects = callbacks, getter_observer = getter_observer }
			renderer.build = function(key, ...)
				if key ~= "configuration_menu" then return original_build(key, ...) end
				observed.builds = observed.builds + 1
				local rows = original_build(key, ...)
				observed.child = rows
				if observed.after_child then observed.after_child(root, parent, rows) end
				if observed.override then return observed.override(rows) end
				return rows
			end
			renderer.group_row = function(key, id, rows, getters)
				if key == "top_level" and id == "configuration" then
					observed.parents = observed.parents + 1
					observed.retained = rows
				end
				return original_group(key, id, rows, getters)
			end
			local fields = {}; for key, value in next, parent do fields[key] = value end
			local ok, detail = xpcall(function() body(root, parent, build, observed, locale) end, debug.traceback)
			renderer.build, renderer.group_row = original_build, original_group
			root.configuration_menu, root.top_level = child, top
			for key in next, parent do parent[key] = nil end
			for key, value in next, fields do parent[key] = value end
			if not ok then error(detail, 0) end
		end)
	end
	helpers.describe("Configuration parent structural source ownership (" .. platform .. ")", function()
		for _, code in ipairs({ "en", "fr" }) do
			local language = code
			helpers.it("retains complete physical " .. language .. " order, native window callbacks and paused posture", function()
				with_case(function(_, _, build, observed, locale)
					locale.set_locale(language)
					local expected = corpus[language]
					local rows = build(false)
					local parent = find(rows, expected.parent)
					helpers.assert_true(parent ~= nil)
					helpers.assert_true(parent.disabled ~= true)
					helpers.assert_eq(observed.parents, 1)
					helpers.assert_true(rawequal(observed.child, observed.retained), "finished child is passed by identity")
					local labels = {}; for _, row in ipairs(parent.menu) do labels[#labels + 1] = row.title end
					helpers.assert_eq(labels, expected.children, "complete hand-authored native child image")
					helpers.assert_eq(observed.effects, {}, "constructing Configuration invokes no action")
					local expected_result
					if platform == "hs" then expected_result = false end
					helpers.assert_eq(parent.menu[6].fn(), expected_result)
					helpers.assert_eq(parent.menu[7].fn(), expected_result)
					helpers.assert_eq(observed.effects, { "paths_editor", "setup_wizard" })
					for index = #observed.effects, 1, -1 do observed.effects[index] = nil end
					local paused = find(build(true), expected.parent)
					helpers.assert_true(paused ~= nil)
					helpers.assert_true(paused.disabled ~= true)
					for _, index in ipairs({ 1, 2, 4 }) do
						if platform == "hs" then
							helpers.assert_true(paused.menu[index].disabled == true)
							helpers.assert_nil(paused.menu[index].fn)
						elseif index ~= 4 then helpers.assert_eq(paused.menu[index].fn(), false) end
					end
					for _, index in ipairs({ 6, 7 }) do
						helpers.assert_true(paused.menu[index].disabled ~= true)
						helpers.assert_eq(type(paused.menu[index].fn), "function")
					end
					helpers.assert_eq(observed.effects, {})
					if platform == "linux" then helpers.assert_eq(rows[#rows].title, expected.quit) end
				end)
			end)
		end
		helpers.it("uses the genuine declared parent caption instead of a native literal", function()
			with_case(function(_, parent, build, observed, locale)
				locale.set_locale("en")
				parent.i18n = "button.ok"
				local row = find(build(), "OK")
				helpers.assert_true(row ~= nil)
				helpers.assert_eq(observed.parents, 1)
				helpers.assert_true(rawequal(row.menu, observed.child))
				helpers.assert_eq(observed.effects, {})
			end)
		end)

		local mutants = {
			missing = function(root) root.configuration_menu = nil end,
			wrong_kind = function(root) root.configuration_menu = false end,
			sparse = function(root) root.configuration_menu = { [2] = root.configuration_menu[1] } end,
			metatable = function(root) root.configuration_menu = setmetatable({}, { __index = function() error("foreign source accessor") end }) end,
			duplicate = function(root, parent) local rows = {}; for i, row in ipairs(root.top_level) do rows[i] = row end; rows[#rows + 1] = parent; root.top_level = rows end,
			parent_type = function(_, parent) parent.type = "command" end,
			parent_rows = function(_, parent) parent.rows = false end,
			wrong_platform = function(_, parent) parent.platforms = { platform == "hs" and "linux" or "hs" } end,
		}
		for _, name in ipairs({ "missing", "wrong_kind", "sparse", "metatable", "duplicate", "parent_type", "parent_rows", "wrong_platform" }) do
			local case = name
			helpers.it("refuses " .. case .. " source before native Configuration context or children", function()
				with_case(function(root, parent, build, observed, locale)
					locale.set_locale("en")
					mutants[case](root, parent)
					local rows = build()
					helpers.assert_nil(find(rows, corpus.en.parent))
					helpers.assert_eq(observed.builds, 0)
					helpers.assert_eq(observed.parents, 0)
					if observed.getter_observer then helpers.assert_eq(observed.getter_observer.calls, 0, "source refusal precedes actual action accessor") end
					helpers.assert_eq(observed.effects, {})
				end)
			end)
		end

		for _, mode in ipairs({ "withdraw", "replace", "caption" }) do
			local case = mode
			helpers.it("refuses source " .. case .. " during genuine child building", function()
				with_case(function(_, _, build, observed, locale)
					locale.set_locale("en")
					observed.after_child = function(root, parent)
						if case == "withdraw" then root.configuration_menu = nil
						elseif case == "replace" then local copy = {}; for i, row in ipairs(root.configuration_menu) do copy[i] = row end; root.configuration_menu = copy
						else parent.i18n = "menu.global.quit" end
					end
					helpers.assert_nil(find(build(), corpus.en.parent))
					helpers.assert_eq(observed.builds, 1)
					helpers.assert_eq(observed.parents, 0)
					helpers.assert_eq(observed.effects, {})
				end)
			end)
		end
		for _, mode in ipairs({ "nil", "throw", "sparse", "metatable" }) do
			local case = mode
			helpers.it("refuses " .. case .. " native child without manufacturing an empty parent", function()
				with_case(function(_, _, build, observed, locale)
					locale.set_locale("en")
					observed.override = function(rows)
						if case == "nil" then return nil elseif case == "throw" then error("native Configuration child refused")
						elseif case == "sparse" then return { [2] = rows[1] } else return setmetatable({}, {}) end
					end
					local ok, rows = pcall(build)
					if ok then helpers.assert_nil(find(rows, corpus.en.parent)) end
					helpers.assert_eq(observed.parents, 0)
					helpers.assert_eq(observed.effects, {})
				end)
			end)
		end
		helpers.it("repairs the same genuine cached source without weakening refusal", function()
			with_case(function(root, _, build, observed, locale)
				locale.set_locale("en")
				local children = root.configuration_menu
				root.configuration_menu = false
				helpers.assert_nil(find(build(), corpus.en.parent))
				helpers.assert_eq(observed.builds, 0)
				helpers.assert_eq(observed.parents, 0)
				root.configuration_menu = children
				helpers.assert_true(find(build(), corpus.en.parent) ~= nil)
				helpers.assert_eq(observed.builds, 1)
				helpers.assert_eq(observed.parents, 1)
				helpers.assert_eq(observed.effects, {})
			end)
		end)

		helpers.it("retains finished child depth beyond the provider-data bound", function()
			with_case(function(_, _, build, observed, locale)
				locale.set_locale("en")
				local deep = { { title = "finished terminal" } }
				for index = 1, 12 do deep = { { title = "finished depth " .. index, menu = deep } } end
				observed.override = function(rows) rows[#rows + 1] = { title = "finished child", menu = deep }; return rows end
				local row = find(build(), corpus.en.parent)
				helpers.assert_true(row ~= nil)
				helpers.assert_true(rawequal(observed.child, observed.retained))
				helpers.assert_true(rawequal(row.menu[#row.menu].menu, deep), "no depth-changing conversion of finished child")
				helpers.assert_eq(observed.effects, {})
			end)
		end)

		helpers.it("retains actual admitted empty child by identity", function()
			with_case(function(root, _, build, observed, locale)
				locale.set_locale("en"); root.configuration_menu = {}
				local row = find(build(), corpus.en.parent)
				helpers.assert_true(row ~= nil)
				helpers.assert_eq(observed.builds, 1)
				helpers.assert_eq(observed.parents, 1)
				helpers.assert_true(rawequal(observed.child, observed.retained))
				helpers.assert_eq(row.menu, {})
				helpers.assert_eq(observed.effects, {})
			end)
		end)
	end)
end
return M
