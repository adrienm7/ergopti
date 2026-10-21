--- tests/unit/ui/editors/test_layer_editor_cleanup_transaction.lua

--- ==============================================================================
--- MODULE: Layer Editor Cleanup Transactions
--- DESCRIPTION:
--- Exercises the real editor across native deletion and bridge-release refusals.
--- Failed cleanup must retain its exact owner and block replacement windows.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Supplies native window boundaries without replacing editor lifecycle logic.
--- @param scenario function Receives the real editor and retained native records.
local function with_editor(scenario)
	local prior_hs = _G.hs
	local records = { views = {}, bridges = {}, deletes = 0, errors = {} }
	local ok, err = xpcall(function()
		helpers.with_stub_scope({ "ui.layer_editor", "ui.ui_builder", "infra.logger", "infra.i18n",
			"infra.paths", "infra.config_paths", "adapters.file_system", "infra.keycodes",
			"platform.remap.nav_layer", "keymap.layer_editor", "keymap.layers" }, function()
			local logger = helpers.make_logger_stub()
			logger.error = function(_, message, ...)
				records.errors[#records.errors + 1] = string.format(message, ...)
			end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.paths"] = {
				shared_root = function() return helpers.shared() end,
				shared = function(path) return helpers.shared(path) end,
			}
			package.loaded["infra.config_paths"] = { get_config_dir = function() return "/virtual/config" end }
			_G.hs = { webview = { usercontent = { new = function()
				local bridge = {}
				function bridge:setCallback(callback)
					if callback == nil and records.release_throws then error("native controller release refused") end
					self.callback = callback
					return self
				end
				records.bridges[#records.bridges + 1] = bridge
				return bridge
			end } } }
			package.loaded["ui.ui_builder"] = {
				get_app_geometry = function() return { width = 800, height = 600 } end,
				get_centered_frame = function(w, h) return { w = w, h = h } end,
				force_focus = function() return true end,
				show_webview = function(options)
					local view = { options = options, deleted = false, scripts = 0 }
					function view:evaluateJavaScript() self.scripts = self.scripts + 1; return self end
					function view:delete()
						records.deletes = records.deletes + 1
						if records.on_delete then records.on_delete(self) end
						if records.delete_throws then error("native window deletion refused") end
						self.deleted = true
						options.on_close()
						return nil
					end
					records.views[#records.views + 1] = view
					return view
				end,
			}
			package.loaded["ui.layer_editor"] = nil
			local editor = require("ui.layer_editor")
			local options = { karabiner = { regenerate = function() return true end } }
			scenario(editor, records, options)
		end)
	end, debug.traceback)
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

helpers.describe("layer editor exact cleanup ownership", function()
	helpers.it("blocks replacement while the exact native window refuses deletion (layer-editor-cleanup)", function()
		with_editor(function(editor, records, options)
			helpers.assert_true(editor.open(options))
			records.delete_throws = true
			editor.close()
			helpers.assert_eq(editor.open(options), false,
				"a live predecessor must not be orphaned by a replacement window")
			helpers.assert_eq(#records.views, 1)
			helpers.assert_eq(records.views[1].deleted, false)
			records.bridges[1].callback({ body = "ready" })
			helpers.assert_eq(records.views[1].scripts, 0,
				"retained cleanup ownership must not accept new page work")
		end)
	end)

	helpers.it("reports refusal and retries the same window before reopening (layer-editor-cleanup)", function()
		with_editor(function(editor, records, options)
			helpers.assert_true(editor.open(options))
			records.delete_throws = true
			helpers.assert_eq(editor.close(), false)
			helpers.assert_eq(records.deletes, 1)
			records.delete_throws = false
			helpers.assert_true(editor.close())
			helpers.assert_eq(records.deletes, 2)
			helpers.assert_true(records.views[1].deleted)
			helpers.assert_nil(records.bridges[1].callback)
			helpers.assert_true(editor.open(options))
			helpers.assert_eq(#records.views, 2)
			helpers.assert_true(editor.close())
		end)
	end)

	helpers.it("rejects replacement reentry while native deletion is unresolved (layer-editor-cleanup)", function()
		with_editor(function(editor, records, options)
			helpers.assert_true(editor.open(options))
			local reentered
			records.on_delete = function(view)
				view.options.on_close()
				reentered = editor.open(options)
			end
			records.delete_throws = true
			editor.close()
			helpers.assert_eq(reentered, false,
				"a native on_close notification must not surrender the deleting owner")
			helpers.assert_eq(#records.views, 1)
			helpers.assert_eq(records.deletes, 1)
		end)
	end)

	helpers.it("retries controller release without deleting a closed window again (layer-editor-cleanup)", function()
		with_editor(function(editor, records, options)
			helpers.assert_true(editor.open(options))
			records.release_throws = true
			helpers.assert_eq(editor.close(), false)
			helpers.assert_true(records.views[1].deleted)
			helpers.assert_eq(editor.open(options), false)
			helpers.assert_eq(#records.views, 1)
			helpers.assert_eq(records.deletes, 1)
			records.release_throws = false
			helpers.assert_true(editor.close())
			helpers.assert_nil(records.bridges[1].callback)
			helpers.assert_eq(records.deletes, 1)
			helpers.assert_true(editor.open(options))
			helpers.assert_eq(#records.views, 2)
		end)
	end)
end)
