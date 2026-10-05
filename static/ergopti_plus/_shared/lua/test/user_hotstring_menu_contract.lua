--- _shared/lua/test/user_hotstring_menu_contract.lua

--- ==============================================================================
--- MODULE: Programmable Hotstring Menu Contract
--- DESCRIPTION:
--- Independent behavior checks use each driver's actual manifest renderer.
--- Rendering is inert; explicit commands, live gates and typing intervals own
--- admission, including visible refusals with an available source-open action.
--- ==============================================================================

local M = {}

--- Registers portable menu regressions with the native renderer under test.
--- @param helpers table Assertions and test registration.
--- @param manifest table Driver-bound actual manifest renderer.
--- @param Logger table The exact native logger captured by this renderer.
function M.run(helpers, manifest, Logger)
	local Policy = require("menu.programmable_hotstrings")
	local function fixture()
		local f = { enabled = false, seconds = 0.5, master = true, paused = false,
			calls = { open = 0, reload = 0, create = 0, set = 0, changed = 0, error = 0 } }
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
			prompt = function() return f.selected end,
			error = function(open) f.calls.error = f.calls.error + 1; f.offered = open end }
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
			helpers.assert_eq(f.calls, { open = 0, reload = 0, create = 0, set = 0, changed = 0, error = 0 })
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
			helpers.assert_eq(f.calls, { open = 0, reload = 0, create = 0, set = 0, changed = 0, error = 0 })
			for index, kind in ipairs({ "open", "reload", "create" }) do
				helpers.assert_type(parent.menu[index + 1].fn, "function")
				helpers.assert_true(parent.menu[index + 1].fn())
				helpers.assert_eq(f.calls[kind], 1)
			end
		end)
		helpers.it("(user-hotstrings-menu) rendering and cancellation evaluate no user code", function()
			local f = fixture()
			helpers.assert_eq(f.calls, { open = 0, reload = 0, create = 0, set = 0, changed = 0, error = 0 })
			helpers.assert_eq(f.rows[1].menu[2].fn(), false)
			helpers.assert_eq(f.calls.set, 0)
			helpers.assert_eq(f.calls.error, 0)
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
			helpers.assert_eq(f.calls.changed, 0)
			helpers.assert_type(f.offered, "function", "every refusal offers the source opener")
		end)
		helpers.it("(user-hotstrings-menu) refused native publication surfaces a source-open action", function()
			local f = fixture()
			f.refuse = true
			helpers.assert_eq(f.rows[1].menu[1].fn(), false)
			helpers.assert_eq(f.calls.changed, 0)
			helpers.assert_eq(f.calls.error, 1)
			f.refuse = false
			helpers.assert_true(f.offered())
			helpers.assert_eq(f.calls.open, 1)
			helpers.assert_eq(f.calls.reload, 0)
		end)
	end)
end

return M
