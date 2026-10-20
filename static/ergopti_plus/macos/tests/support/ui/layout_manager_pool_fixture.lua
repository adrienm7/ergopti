--- tests/support/ui/layout_manager_pool_fixture.lua

--- ==============================================================================
--- MODULE: Layout Manager Pinned Controller Fixture
--- DESCRIPTION:
--- Reuses the picker's independent native userdata/callback registries for the
--- actual layout host and shared bridge. Factory/native boundaries are controlled;
--- these portable cases never qualify Cocoa or native controller collection.
--- ==============================================================================

local helpers = require("tests.helpers")
local References = require("tests.support.ui.usercontent_reference_fixture")

--- Runs one canonical layout module through successive window leases.
--- @param scenario function Receives the real host and pinned native observations.
local function with_layout(scenario)
	return helpers.with_fresh_modules({ "ui.layout_manager", "layouts.manager_bridge", "infra.deferred_work",
		"adapters.file_system", "modules.keymap.layout_registry" }, function()
		return References(function(_, h)
			local builder = package.loaded["ui.ui_builder"]
			local create = builder.show_webview
			h.refreshes, h.focuses, h.deferred = 0, 0, {}
			package.loaded["adapters.file_system"] = { read = function() return '{"keys":[]}' end }
			package.loaded["infra.deferred_work"] = { after = function(_, callback)
				h.deferred[#h.deferred + 1] = callback; return true
			end }
			package.loaded["modules.keymap.layout_registry"] = {
				snapshot = function() return { platform = "macos", installed = {} } end,
				refresh = function(callback) h.refreshes = h.refreshes + 1; callback() end,
			}
			hs.webview.windowMasks = { titled = 1, closable = 2, resizable = 8 }
			builder.force_focus = function() h.focuses = h.focuses + 1; return true end
			builder.show_webview = function(options)
				local view = create(options)
				if view == nil then return nil end
				view.delete_calls = 0
				local delete = view.delete
				function view:delete()
					self.delete_calls = self.delete_calls + 1
					if h.on_delete then h.on_delete(self) end
					if h.delete_refuses == "throw" then error("native delete refused") end
					if h.delete_refuses == "false" then return false end
					return delete(self)
				end
				assert(options.on_webview_created(view) == true, "actual host rejected the owned candidate")
				if h.on_created then h.on_created(view) end
				if h.reject_created then return nil end
				return view
			end
			local host = require("ui.layout_manager")
			function h.current() return h.views[#h.views], h.controllers[#h.controllers] end
			function h.close()
				local view, controller = h.current()
				h.post(controller, view, { action = "close" })
			end
			function h.user_close()
				local view = h.current()
				view.deleted = true
				view.options.on_close()
			end
			scenario(host, h)
		end)
	end)
end

return with_layout
