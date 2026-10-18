--- _shared/lua/test/user_hotstring_menu_contract.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Menu Contract
--- DESCRIPTION:
--- Independent behavior checks use each driver's actual manifest renderer.
--- Rendering is inert; explicit commands, live gates and typing intervals own
--- admission. A refusal never opens a dialog: it redraws the menu, whose
--- feature row names the source problem the native owner reports.
--- ==============================================================================

local M = {}

--- Registers portable menu regressions with the native renderer under test.
--- @param helpers table Assertions and test registration.
--- @param manifest table Driver-bound actual manifest renderer.
--- @param Logger table The exact native logger captured by this renderer.
function M.run(helpers, manifest, Logger)
	local Policy = require("menu.programmable_hotstrings")
	--- @param problem string|nil The source problem the native owner reports.
	local function fixture(problem)
		local f = { enabled = false, seconds = 0.5, master = true, paused = false, problem = problem,
			calls = { open = 0, reload = 0, create = 0, set = 0, changed = 0 } }
		local ports = { manifest = manifest, i18n = function(key) return key end,
			get = function() return f.enabled, f.seconds end,
			master = function() return f.master end, paused = function() return f.paused end,
			set = function(enabled, seconds)
				f.calls.set = f.calls.set + 1
				if f.refuse then return false end
				f.enabled, f.seconds = enabled, seconds
				return true
			end,
			changed = function() f.calls.changed = f.calls.changed + 1 end,
			prompt = function()
				if f.on_prompt then f.on_prompt() end
				return f.selected
			end,
			problem = function() return f.problem end }
		for _, kind in ipairs({ "open", "reload", "create" }) do
			ports[kind] = function() f.calls[kind] = f.calls[kind] + 1; return not f.refuse end
		end
		f.rows = Policy.build(ports)
		helpers.assert_eq(#f.rows, 4, "shared declaration owns the feature and three source commands")
		return f
	end
	helpers.describe("programmable native menu contract", function()
		helpers.it("(user-hotstrings-menu) uses the declared parent around rendered child controls", function()
			local f = fixture()
			local rows = Policy.build_entry(manifest, function() return f.rows end)
			helpers.assert_eq(#rows, 1, "the manifest owns one parent without an added native separator")
			helpers.assert_eq(#rows[1].menu, 4)
			helpers.assert_type(rows[1].menu[2].fn, "function")
			helpers.assert_eq(f.calls, { open = 0, reload = 0, create = 0, set = 0, changed = 0 })
		end)
		helpers.it("(user-hotstrings-menu) keeps the declared source controls reachable through the actual category renderer", function()
			local f = fixture()
			local rows = Policy.build_entry_rows(manifest, function() return f.rows end)
			helpers.assert_eq(#rows, 1)
			helpers.assert_type(rows[1].label, "string")
			helpers.assert_nil(rows[1].title, "a list provider cannot return a finished native parent")
			helpers.assert_nil(rows[1].menu, "rendered children must be carried through submenu")
			local original, errors = Logger.error, {}
			Logger.error = function(module, message, ...)
				errors[#errors + 1] = tostring(module) .. ": " .. tostring(message)
				return original(module, message, ...)
			end
			local rejected_ok, rejected_problem = pcall(function()
				local rejected = manifest.build("hotstring_category_menu", "Hotstrings", nil, nil,
					{ commands = { hotstring_category_enable_all = function() return true end,
						hotstring_category_disable_all = function() return true end } }, {
						hotstring_category_file = function() return {} end,
						hotstring_category_sections = function()
							return Policy.build_entry(manifest, function() return f.rows end)
						end,
					})
				local rejected_parent = nil
				for _, row in ipairs(rejected) do if row.title == rows[1].label then rejected_parent = row end end
				helpers.assert_nil(rejected_parent, "negative control: native parent dialect is rejected by the category provider")
				helpers.assert_true(#errors >= 2, "negative control must report the native title/menu dialect")
			end)
			if not rejected_ok then Logger.error = original; error(rejected_problem, 0) end
			errors = {}
			local ok, category = pcall(manifest.build, "hotstring_category_menu", "Hotstrings", nil, nil,
				{ commands = { hotstring_category_enable_all = function() return true end,
					hotstring_category_disable_all = function() return true end } }, {
					hotstring_category_file = function() return {} end,
					hotstring_category_sections = function() return rows end,
				})
			Logger.error = original
			helpers.assert_true(ok)
			helpers.assert_eq(errors, {}, "actual renderer must accept provider shape without dropping the parent")
			local parent = nil
			for _, row in ipairs(category) do
				if row.title == rows[1].label then parent = row end
			end
			helpers.assert_not_nil(parent, "declared parent must remain reachable in the actual category")
			helpers.assert_eq(#parent.menu, 4)
			helpers.assert_eq(f.calls, { open = 0, reload = 0, create = 0, set = 0, changed = 0 })
			for index, kind in ipairs({ "open", "reload", "create" }) do
				helpers.assert_type(parent.menu[index + 1].fn, "function")
				helpers.assert_true(parent.menu[index + 1].fn())
				helpers.assert_eq(f.calls[kind], 1)
			end
		end)
		helpers.it("(user-hotstrings-menu) rendering and cancellation evaluate no user code", function()
			local f = fixture()
			helpers.assert_eq(f.calls, { open = 0, reload = 0, create = 0, set = 0, changed = 0 })
			helpers.assert_eq(f.rows[1].menu[2].fn(), false)
			helpers.assert_eq(f.calls.set, 0)
			helpers.assert_eq(f.calls.changed, 0, "a cancelled prompt is no refusal")
		end)
		for index, kind in ipairs({ "open", "reload", "create" }) do
			helpers.it("(user-hotstrings-menu) explicit " .. kind .. " command invokes only its native owner", function()
				local f = fixture()
				helpers.assert_true(f.rows[index + 1].fn())
				for _, other in ipairs({ "open", "reload", "create", "set" }) do
					helpers.assert_eq(f.calls[other], other == kind and 1 or 0)
				end
				helpers.assert_eq(f.calls.changed, 1)
			end)
		end
		helpers.it("(user-hotstrings-menu) toggles the live preference and converts milliseconds once", function()
			local f = fixture()
			f.enabled = true
			helpers.assert_true(f.rows[1].menu[1].fn())
			helpers.assert_eq(f.enabled, false, "the stale rendered checkbox cannot dictate the next preference")
			f.selected = "125"
			helpers.assert_true(f.rows[1].menu[2].fn())
			helpers.assert_eq(f.seconds, 0.125)
			f.selected = "0"
			helpers.assert_true(f.rows[1].menu[2].fn())
			helpers.assert_eq(f.seconds, 0)
		end)
		helpers.it("(user-hotstrings-menu) refuses stale pause/master gates and malformed intervals", function()
			local f = fixture()
			f.paused = true
			helpers.assert_eq(f.rows[1].menu[1].fn(), false)
			f.paused, f.master = false, false
			helpers.assert_eq(f.rows[1].menu[1].fn(), false)
			f.master = true
			for _, invalid in ipairs({ "bad", "-1", "1.5", "1e999" }) do
				f.selected = invalid
				helpers.assert_eq(f.rows[1].menu[2].fn(), false)
			end
			helpers.assert_eq(f.calls.set, 0)
			helpers.assert_eq(f.calls.changed, 6, "every refusal redraws the menu, and opens nothing")
			helpers.assert_eq(f.calls.open, 0, "a refusal never offers or opens the source")
		end)
		for _, changed in ipairs({ "enabled", "seconds" }) do
			helpers.it("(user-hotstrings-menu-held-prompt) refuses changed " .. changed .. " preference without overwriting it", function()
				local f = fixture()
				f.selected = "125"
				f.on_prompt = function()
					if changed == "enabled" then f.enabled = true else f.seconds = 0.75 end
				end
				helpers.assert_eq(f.rows[1].menu[2].fn(), false)
				helpers.assert_eq(f.enabled, changed == "enabled")
				helpers.assert_eq(f.seconds, changed == "seconds" and 0.75 or 0.5)
				helpers.assert_eq(f.calls.set, 0)
				helpers.assert_eq(f.calls.changed, 1, "the refusal redraws the menu")
				helpers.assert_eq(f.calls.open, 0)
			end)
		end
		helpers.it("(user-hotstrings-menu) refused native publication redraws the menu and opens nothing", function()
			local f = fixture()
			f.refuse = true
			helpers.assert_eq(f.rows[1].menu[1].fn(), false)
			helpers.assert_eq(f.calls.changed, 1, "the redrawn row shows the state the owner now reports")
			helpers.assert_eq(f.calls.open, 0, "no dialog offers the source opener any more")
			helpers.assert_eq(f.calls.reload, 0)
		end)
		helpers.it("(user-hotstrings-problem) names no problem on a healthy source", function()
			local f = fixture()
			helpers.assert_eq(f.rows[1].title, "menu.hotstrings.user_code.title")
			helpers.assert_true(not f.rows[2].disabled, "an existing source opens")
		end)
		for _, problem in ipairs({ "missing", "failed" }) do
			helpers.it("(user-hotstrings-problem) shows a " .. problem .. " source on the feature row", function()
				local f = fixture(problem)
				helpers.assert_eq(f.rows[1].title, "menu.hotstrings.user_code.title — menu.hotstrings.user_code.problem_" .. problem)
				helpers.assert_eq(f.rows[2].disabled == true, problem == "missing",
					"only a missing source has nothing to open")
				helpers.assert_true(not f.rows[3].disabled and not f.rows[4].disabled, "reload and create stay offered")
			end)
		end
		helpers.it("(user-hotstrings-problem) refuses an undeclared problem", function()
			local ok, err = pcall(fixture, "broken")
			helpers.assert_eq(ok, false)
			helpers.assert_contains(tostring(err), "unknown programmable source problem")
		end)
		helpers.it("(user-hotstrings-problem) creates the example and enables it at once when the option is on", function()
			local f = fixture("missing")
			f.enabled, f.seconds = true, 0.25
			helpers.assert_true(f.rows[4].fn())
			helpers.assert_eq(f.calls.create, 1)
			helpers.assert_eq(f.calls.set, 1, "the created source is loaded at once")
			helpers.assert_eq(f.enabled, true)
			helpers.assert_eq(f.seconds, 0.25, "the interval is kept")
			helpers.assert_eq(f.calls.changed, 1)
		end)
		helpers.it("(user-hotstrings-problem) creates the example without enabling it when the option is off or gated", function()
			for _, gate in ipairs({ "off", "paused", "master" }) do
				local f = fixture("missing")
				f.enabled = gate ~= "off"
				f.paused = gate == "paused"
				f.master = gate ~= "master"
				helpers.assert_true(f.rows[4].fn(), gate)
				helpers.assert_eq(f.calls.create, 1, gate)
				helpers.assert_eq(f.calls.set, 0, gate .. ": nothing is enabled")
			end
		end)
		helpers.it("(user-hotstrings-problem) a refused creation or load redraws the row and enables nothing", function()
			local f = fixture("missing")
			f.enabled, f.refuse = true, true
			helpers.assert_eq(f.rows[4].fn(), false)
			helpers.assert_eq(f.calls.create, 1)
			helpers.assert_eq(f.calls.set, 0, "an example that was not created is not loaded")
			helpers.assert_eq(f.calls.changed, 1)
		end)
	end)
end

return M
