--- _shared/lua/test/metrics_parent_contract.lua
--- Structural parent admission preserves completed native children, not child grammar.
local M = {}

--- Registers source-bound Metrics parent controls against a genuine native owner.
--- @param helpers table Existing registered assertions.
--- @param fixture function Actual native renderer and Metrics builder fixture.
--- @param corpus table Hand-authored physical parent captions.
--- @param platform string Actual platform token.
function M.register(helpers, fixture, corpus, platform)
	local function with_case(body)
		fixture(function(renderer, build, observed, locale)
			local root = assert(renderer.get_root())
			local section, top, parent = root.metrics_menu, root.top_level
			for _, row in ipairs(top) do if row.id == "metrics" then parent = row end end
			local fields = {}; for key, value in next, parent do fields[key] = value end
			local original_build, original_group = renderer.build, renderer.group_row
			renderer.build = function(key, ...)
				local rows = original_build(key, ...)
				if key ~= "metrics_menu" then return rows end
				observed.builds = observed.builds + 1
				observed.child = rows
				observed.child_complete = true
				if observed.after_child then observed.after_child(root, parent, rows) end
				if observed.override then rows = observed.override(rows); observed.child = rows end
				return rows
			end
			renderer.group_row = function(key, id, rows, getters)
				if key ~= "top_level" or id ~= "metrics" then return original_group(key, id, rows, getters) end
				observed.parents = observed.parents + 1
				observed.retained = rows
				local actual = getters.keylogger_enabled
				local wrapped = { keylogger_enabled = function()
					observed.getters = observed.getters + 1
					return actual()
				end }
				return original_group(key, id, rows, wrapped)
			end
			local ok, detail = xpcall(function() body(root, parent, build, observed, locale) end, debug.traceback)
			renderer.build, renderer.group_row = original_build, original_group
			root.metrics_menu, root.top_level = section, top
			for key in next, parent do parent[key] = nil end
			for key, value in next, fields do parent[key] = value end
			if not ok then error(detail, 0) end
		end)
	end
	helpers.describe("Metrics structural completed-parent ownership (" .. platform .. ")", function()
		for _, code in ipairs({ "en", "fr" }) do
			local language = code
			helpers.it("metrics-parent reads genuine " .. language .. " parent caption and completed child identity", function()
				with_case(function(_, _, build, observed, locale)
					locale.set_locale(language)
					local row = build(false)
					helpers.assert_eq(row.title, corpus[language])
					helpers.assert_true(rawequal(row.menu, observed.child))
					helpers.assert_true(rawequal(observed.retained, observed.child))
					helpers.assert_eq(observed.parents, 1)
					helpers.assert_eq(observed.getters, 1)
					if platform == "hs" then helpers.assert_nil(row.checked)
					else helpers.assert_eq(row.checked, false);helpers.assert_eq(observed.native_reads_after_child,1) end
				end)
			end)
		end
		helpers.it("metrics-parent uses a changed actual declared caption and preserves raw false", function()
			with_case(function(_, parent, build, observed)
				parent.i18n = "button.ok"
				local row = build(false, false)
				helpers.assert_eq(row.title, "OK")
				helpers.assert_eq(row.checked, false)
				helpers.assert_eq(observed.getters, 1)
			end)
		end)
		local mutants = {
			missing = function(root) root.metrics_menu = nil end,
			wrong_kind = function(root) root.metrics_menu = false end,
			sparse = function(root) root.metrics_menu = { [2] = root.metrics_menu[1] } end,
			metatable = function(root) root.metrics_menu = setmetatable({}, { __index = function() error("foreign accessor") end }) end,
			duplicate = function(root, parent) local top = {}; for i,row in ipairs(root.top_level) do top[i] = row end; top[#top+1] = parent; root.top_level = top end,
			parent_type = function(_, parent) parent.type = "command" end,
			parent_rows = function(_, parent) parent.rows = false end,
			wrong_platform = function(_, parent) parent.platforms = { platform == "hs" and "linux" or "hs" } end,
		}
		for _, name in ipairs({ "missing", "wrong_kind", "sparse", "metatable", "duplicate", "parent_type", "parent_rows", "wrong_platform" }) do
			local mode = name
			helpers.it("metrics-parent withholds parent getter and projection for " .. mode .. " source", function()
				with_case(function(root, parent, build, observed)
					mutants[mode](root, parent)
					local ok, row = pcall(build, false)
					if mode == "metatable" and platform == "hs" then helpers.assert_eq(ok, false)
					else helpers.assert_true(ok);helpers.assert_nil(row) end
					helpers.assert_eq(observed.parents, 0)
					helpers.assert_eq(observed.getters, 0)
					if platform == "linux" then helpers.assert_eq(observed.builds, 0) end
				end)
			end)
		end
		for _, name in ipairs({ "withdraw", "replace", "caption" }) do
			local mode = name
			helpers.it("metrics-parent withholds projection after completed child changes " .. mode .. " authority", function()
				with_case(function(_, _, build, observed)
					observed.after_child = function(root, parent)
						if mode == "withdraw" then root.metrics_menu = nil
						elseif mode == "replace" then root.metrics_menu = {}
						else parent.i18n = "button.ok" end
					end
					helpers.assert_nil(build(false))
					helpers.assert_eq(observed.parents, 0)
					helpers.assert_eq(observed.getters, 0)
				end)
			end)
		end
		for _, name in ipairs({ "nil", "throw", "sparse", "metatable" }) do
			local mode = name
			helpers.it("metrics-parent preserves genuine native " .. mode .. " child refusal", function()
				with_case(function(_, _, build, observed)
					observed.override = function()
						if mode == "throw" then error("actual child refused")
						elseif mode == "sparse" then return { [2] = {title="bad"} }
						elseif mode == "metatable" then return setmetatable({}, {}) end
					end
					local ok, row = pcall(build, false)
					if mode == "throw" then helpers.assert_eq(ok, false) else helpers.assert_true(ok);helpers.assert_nil(row) end
					helpers.assert_eq(observed.parents, 0)
					helpers.assert_eq(observed.getters, 0)
				end)
			end)
		end
		helpers.it("metrics-parent accepts genuine authored empty Metrics source and repairs after withdrawal", function()
			with_case(function(root, _, build, observed)
				root.metrics_menu = {}
				local row = build(false)
				helpers.assert_true(row ~= nil);helpers.assert_eq(#row.menu,0)
				helpers.assert_true(rawequal(row.menu,observed.child))
				root.metrics_menu = nil
				helpers.assert_nil(build(false))
				helpers.assert_eq(observed.parents,1);helpers.assert_eq(observed.getters,1)
				root.metrics_menu = {}
				row = build(false)
				helpers.assert_true(row ~= nil);helpers.assert_eq(#row.menu,0)
				helpers.assert_eq(observed.parents,2);helpers.assert_eq(observed.getters,2)
			end)
		end)

		helpers.it("metrics-parent retains authentic empty and completed deep callback trees by identity", function()
			with_case(function(_, _, build, observed)
				local delivered = 0
				local fn = function() delivered = delivered+1; return false end
				local child = {}
				observed.override = function() return child end
				helpers.assert_true(rawequal(build(false).menu, child))
				child = { {title="native leaf",fn=fn, image={native=true}} }
				local leaf = child[1]
				for _=1,12 do child = { {title="native depth",menu=child} } end
				local row = build(false)
				helpers.assert_true(rawequal(row.menu, child))
				helpers.assert_eq(delivered, 0)
				helpers.assert_true(rawequal(leaf.fn,fn));helpers.assert_eq(leaf.fn(),false)
				helpers.assert_eq(delivered, 1)
			end)
		end)
		helpers.it("independent final physical Metrics caption callback cannot withdraw parent authority", function()
			with_case(function(root, _, build, observed)
				local i18n = require("infra.i18n")
				local old_get, old_group, top = i18n.get, require("infra.manifest_menu").group_row, root.top_level
				local renderer = require("infra.manifest_menu")
				local in_parent, calls = false, 0
				renderer.group_row = function(...)
					in_parent = true
					local row = old_group(...)
					in_parent = false
					return row
				end
				i18n.get = function(key, ...)
					local label = old_get(key, ...)
					if in_parent and key == "menu.metrics.title" then
						calls = calls + 1
						root.top_level = {}
					end
					return label
				end
				local ok, row = pcall(build, false)
				i18n.get, renderer.group_row, root.top_level = old_get, old_group, top
				print("INDEPENDENT_FINAL_METRICS", platform, "caption_calls", calls, "returned", row ~= nil, "called", ok)
				helpers.assert_eq(calls, 1, "the genuine final physical caption getter ran")
				helpers.assert_true(ok)
				helpers.assert_nil(row, "parent authority withdrawn during final caption must refuse")
			end)
		end)
		helpers.it("metrics-parent refuses direct source field drift during the final physical caption", function()
			with_case(function(_, parent, build)
				local i18n, renderer = require("infra.i18n"), require("infra.manifest_menu")
				local original_get, original_group = i18n.get, renderer.group_row
				local inside, calls = false, 0
				renderer.group_row = function(...)
					inside = true
					local row = original_group(...)
					inside = false
					return row
				end
				i18n.get = function(key, ...)
					local label = original_get(key, ...)
					if inside and key == "menu.metrics.title" then calls=calls+1;parent.i18n="button.ok" end
					return label
				end
				local ok, row = pcall(build, false)
				i18n.get, renderer.group_row = original_get, original_group
				helpers.assert_true(ok);helpers.assert_eq(calls,1)
				helpers.assert_nil(row,"captured direct parent fields must survive the final getter")
			end)
		end)
	end)
end
return M
