--- tests/unit/ui/menu/test_menu_keyboard_layout_async_actions.lua

--- ==============================================================================
--- MODULE: Keyboard-layout Menu Async Action Regression
--- DESCRIPTION:
--- A committed subprocess dispatch is not the result of a layout mutation. The
--- menu must wait for the async business callback before scheduling its refresh;
--- otherwise it redraws success-era state while the child is still running or
--- after the child later reports failure.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("menu_keyboard_layout: async layout selection", function()
	helpers.it("waits for the business terminal instead of the dispatch result", function()
		helpers.with_fresh_modules({
			"modules.keymap.input_sources",
			"modules.keymap.layout_install",
			"ui.menu.menu_keyboard_layout",
			"infra.manifest_menu",
			"infra.notifications",
		}, function()
			local input_sources = helpers.load_with_stubs("modules.keymap.input_sources")
			local install = require("modules.keymap.layout_install")
			local scheduled = {}
			hs.timer.doAfter = function(delay, callback)
				scheduled[#scheduled + 1] = { delay = delay, callback = callback }
				return { stop = function() end }
			end

			local business_done = nil
			local dispatches = 0
			input_sources.list_active_keyboard_layouts = function()
				return { { id = "French", name = "French", selected = false } }
			end
			input_sources.build_kl_name_to_tis_id = function() return {} end
			input_sources.resolve_installed_ergopti_version = function() return nil end
			input_sources.set_input_source_async = function(localised, raw, on_done)
				dispatches = dispatches + 1
				helpers.assert_eq(localised, "French")
				helpers.assert_eq(raw, "French")
				business_done = on_done
				return true
			end
			install.pick_latest_bundle = function() return nil end
			install.highest_installed = function() return nil end

			package.loaded["infra.notifications"] = { notify = function() end }
			package.loaded["infra.manifest_menu"] = {
				build = function(_menu_id, _label, _a, _b, _ctx, providers)
					return providers.active_layouts()
				end,
			}
			package.loaded["ui.menu.menu_keyboard_layout"] = nil
			local menu = require("ui.menu.menu_keyboard_layout")

			local refreshes = 0
			local built = menu.build({
				base_dir = "/tmp/ergopti/",
				updateMenu = function() refreshes = refreshes + 1 end,
			})
			helpers.assert_eq(#built.items, 1, "the manifest provider must expose the active row")
			helpers.assert_true(type(built.items[1].action) == "function")

			built.items[1].action()
			helpers.assert_eq(dispatches, 0, "the TIS dispatch remains outside the menu callback frame")
			helpers.assert_eq(#scheduled, 1)
			scheduled[1].callback()
			helpers.assert_eq(dispatches, 1)
			helpers.assert_true(type(business_done) == "function")
			helpers.assert_eq(#scheduled, 1,
				"accepted=true must not schedule a refresh before the business terminal")
			helpers.assert_eq(refreshes, 0)

			business_done(false, nil, "process_failed")
			helpers.assert_eq(#scheduled, 2,
				"the terminal callback owns the one post-mutation refresh")
			helpers.assert_eq(refreshes, 0)
			scheduled[2].callback()
			helpers.assert_eq(refreshes, 1)
		end)
	end)
end)


--- Exercises one bundle mutation from the rendered menu through its deferred
--- dispatch and retained business callback.
--- @param operation string `upgrade` or `enable`.
--- @param business_ok boolean Terminal result delivered by the async owner.
local function exercise_bundle_action(operation, business_ok)
	helpers.with_fresh_modules({
		"modules.keymap.input_sources",
		"modules.keymap.layout_install",
		"ui.menu.menu_keyboard_layout",
		"infra.manifest_menu",
		"infra.notifications",
	}, function()
		local input_sources = helpers.load_with_stubs("modules.keymap.input_sources")
		local install = require("modules.keymap.layout_install")
		local scheduled = {}
		local notices = {}
		local business_done = nil
		local dispatches = 0
		hs.timer.doAfter = function(delay, callback)
			scheduled[#scheduled + 1] = { delay = delay, callback = callback }
			return { stop = function() end }
		end

		input_sources.ERGOPTI_VARIANTS = {
			{ id = "com.apple.keyboardlayout.ergopti.plus", label = "Ergopti+", suffix = "_plus" },
		}
		input_sources.list_active_keyboard_layouts = function()
			if operation == "upgrade" then
				return {
					{ id = "Ergopti_v2_2_1_plus", name = "Ergopti+ v2.2.1", selected = false },
				}
			end
			return { { id = "French", name = "French", selected = false } }
		end
		input_sources.build_kl_name_to_tis_id = function() return {} end
		input_sources.resolve_installed_ergopti_version = function() return { 2, 2, 2 } end
		input_sources.upgrade_active_list_async = function(_legacy, on_done)
			dispatches = dispatches + 1
			business_done = on_done
			return true
		end
		input_sources.enable_and_select_source_async = function(
				_id, _label, _bundle, _internal, on_done)
			dispatches = dispatches + 1
			business_done = on_done
			return true
		end

		install.pick_latest_bundle = function() return "Ergopti_v2.2.2.bundle" end
		install.highest_installed = function()
			return { name = "Ergopti_v2.2.2.bundle", version = { 2, 2, 2 } }
		end

		package.loaded["infra.notifications"] = {
			notify = function(_title, _body, kind) notices[#notices + 1] = kind end,
		}
		package.loaded["infra.manifest_menu"] = {
			build = function(_menu_id, _label, _a, _b, _ctx, providers)
				return providers.layout_bundle()
			end,
		}
		package.loaded["ui.menu.menu_keyboard_layout"] = nil
		local menu = require("ui.menu.menu_keyboard_layout")

		local refreshes = 0
		local built = menu.build({
			base_dir = "/tmp/ergopti/",
			updateMenu = function() refreshes = refreshes + 1 end,
		})
		local action = nil
		if operation == "upgrade" then
			for _, row in ipairs(built.items) do
				if row.label == "menu.layout.update_list" then action = row.action end
			end
		else
			for _, row in ipairs(built.items) do
				if type(row.items) == "table" and row.items[1] then
					action = row.items[1].action
				end
			end
		end
		helpers.assert_true(type(action) == "function", operation .. " action must be rendered")

		action()
		helpers.assert_eq(dispatches, 0)
		helpers.assert_eq(#notices, 0)
		helpers.assert_eq(refreshes, 0)
		helpers.assert_eq(#scheduled, 1)
		scheduled[1].callback()
		helpers.assert_eq(dispatches, 1)
		helpers.assert_true(type(business_done) == "function")
		helpers.assert_eq(#notices, 0,
			"accepted=true must not be rendered as the operation result")
		helpers.assert_eq(#scheduled, 1)

		business_done(business_ok)
		helpers.assert_eq(#notices, 1)
		helpers.assert_eq(notices[1], business_ok and "success" or "error")
		helpers.assert_eq(#scheduled, 2)
		helpers.assert_eq(refreshes, 0)
		scheduled[2].callback()
		helpers.assert_eq(refreshes, 1)
	end)
end


helpers.describe("menu_keyboard_layout: async bundle mutations", function()
	for _, operation in ipairs({ "upgrade", "enable" }) do
		for _, business_ok in ipairs({ false, true }) do
			helpers.it(string.format("%s waits for terminal %s", operation, tostring(business_ok)), function()
				exercise_bundle_action(operation, business_ok)
			end)
		end
	end
end)
