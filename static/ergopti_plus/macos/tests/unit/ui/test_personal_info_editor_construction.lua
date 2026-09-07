--- tests/unit/ui/test_personal_info_editor_construction.lua

--- ==============================================================================
--- MODULE: Personal Information Editor Construction Transactions
--- DESCRIPTION:
--- Drives real controller APIs with exact native allocation and cleanup records.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ============================================
-- ============================================
-- ======= 1/ Construction Transactions =======
-- ============================================
-- ============================================

--- Runs an isolated real editor and real focus controller with native doubles.
--- @param scenario function Behavioral assertions.
local function with_editor(scenario)
	local loaded, prior_hs = {}, _G.hs
	for key, value in pairs(package.loaded) do loaded[key] = value end
	local records = { views = {}, bridges = {}, deferred = {}, errors = {}, focuses = 0, saves = 0 }
	local ok, err = xpcall(function()
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end, warn = function() end,
			error = function(_, message, ...)
				records.errors[#records.errors + 1] = string.format(message, ...)
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.paths"] = { shared = function() return "/virtual/shared" end }
		package.loaded["infra.deferred_work"] = { after = function(_, callback)
			records.deferred[#records.deferred + 1] = callback
			return true
		end }
		_G.hs = {
			json = { encode = function() return "{}" end },
			focus = function() records.focuses = records.focuses + 1 end,
			screen = { mainScreen = function()
				if records.screen_throws then error("injected screen failure") end
				return { frame = function() return { w = 1440, h = 900 } end }
			end },
			webview = { windowMasks = {}, usercontent = { new = function()
				local bridge = { clears = 0 }
				function bridge:setCallback(callback)
					if callback == nil then
						self.clears = self.clears + 1
						if records.clear_throws then error("injected bridge release failure") end
					else
						self.callback = callback
						if records.bind_throws then error("injected bridge binding failure") end
					end
					return self
				end
				records.bridges[#records.bridges + 1] = bridge
				return bridge
			end } },
		}
		package.loaded["hs.spaces"] = {}
		package.loaded["ui.ui_builder"] = nil
		local real_builder = require("ui.ui_builder")
		package.loaded["ui.ui_builder"] = {
			force_focus = real_builder.force_focus,
			get_app_geometry = function() return { width = 800, height = 600 } end,
			get_centered_frame = function(w, h) return { w = w, h = h } end,
			show_webview = function(options)
				if records.factory_before_throws then error("injected factory entry failure") end
				local view = { deletes = 0, options = options }
				function view:delete()
					self.deletes = self.deletes + 1
					if records.delete_throws then error("injected native delete failure") end
					options.on_close()
					return self
				end
				function view:hswindow()
					if self.deletes > 0 then error("deleted native view") end
					return nil
				end
				function view:bringToFront()
					if self.deletes > 0 then error("deleted native view") end
					return self
				end
				records.views[#records.views + 1] = view
				if options.on_webview_created then options.on_webview_created(view) end
				if records.factory_after_throws then error("injected post-allocation failure") end
				return view
			end,
		}
		package.loaded["ui.personal_info_editor"] = nil
		scenario(require("ui.personal_info_editor"), records)
	end, debug.traceback)
	for key in pairs(package.loaded) do if loaded[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(loaded) do package.loaded[key] = value end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("personal editor construction rollback", function()
	for _, failure in ipairs({ "bind_throws", "screen_throws", "factory_before_throws", "factory_after_throws" }) do
		helpers.it("rolls back " .. failure .. " and permits retry (personal-editor-construction)", function()
			with_editor(function(editor, records)
				records[failure] = true
				local returned, result = pcall(editor.open, {}, function()
					records.saves = records.saves + 1
					return true
				end)
				helpers.assert_eq({ returned, result }, { true, false })
				helpers.assert_eq(records.bridges[1].clears, 1)
				if failure == "factory_after_throws" then helpers.assert_eq(records.views[1].deletes, 1) end
				records.bridges[1].callback({ body = { action = "save", values = {} } })
				helpers.assert_eq(records.saves, 0)
				helpers.assert_true(#records.errors > 0, "failed construction must have a visible diagnostic")
				records[failure] = false
				helpers.assert_eq(editor.open({}, function() return true end), true)
			end)
		end)
	end

	for _, failure in ipairs({ "clear_throws", "delete_throws" }) do
		helpers.it("retains exact " .. failure .. " cleanup debt (personal-editor-construction)", function()
			with_editor(function(editor, records)
				records.factory_after_throws = true
				records[failure] = true
				helpers.assert_eq(editor.open({}, function() return true end), false)
				helpers.assert_eq(editor.open({}, function() return true end), false)
				helpers.assert_eq(#records.views, 1)
				helpers.assert_eq(#records.bridges, 1)
				records[failure] = false
				records.factory_after_throws = false
				helpers.assert_eq(editor.close(), true)
				helpers.assert_eq(editor.open({}, function() return true end), true)
				helpers.assert_eq(#records.views, 2)
			end)
		end)
	end
end)
