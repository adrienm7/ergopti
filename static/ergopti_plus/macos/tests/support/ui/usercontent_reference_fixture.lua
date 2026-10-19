--- tests/support/ui/usercontent_reference_fixture.lua

--- ==============================================================================
--- MODULE: Usercontent Native Reference Fixture
--- DESCRIPTION:
--- Runs the real picker with independent native-shaped UCC userdata and callback
--- registries. Window disposal is a factory boundary, not a WebKit GC model.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs one isolated picker without replacing its business receiver or pool.
--- @param scenario function Receives the real picker and native observations.
local function with_picker(scenario)
	return helpers.with_stub_scope({
		"ui.action_picker", "ui.webview_controller_pool", "ui.ui_builder", "infra.logger",
		"infra.i18n", "infra.paths", "json", "program_provider_picker",
		"adapters.program_providers", "adapters.apple_shortcuts_native",
	}, function()
		local h = { controllers = {}, userdata_refs = {}, callback_refs = {}, views = {}, errors = {}, nil_calls = 0 }
		local Json = require("json")
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...) h.errors[#h.errors + 1] = string.format(message, ...) end
		logger.callback = function(_, _, callback, ...) return pcall(callback, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.paths"] = { shared = function(relative) return "/virtual/" .. relative end }
		package.loaded["adapters.program_providers"] = {}
		package.loaded["adapters.apple_shortcuts_native"] = {}
		local function new_controller(name)
			local controller = { name = name }
			function controller:setCallback(callback)
				if callback == nil then
					h.nil_calls = h.nil_calls + 1
					if h.on_detach then h.on_detach() end
				end
				h.callback_refs[self] = callback
				if callback == nil and h.detach_throws then error("native detach applied before wrapper exception") end
				if callback == nil and h.detach_result == "false" then return false end
				if callback == nil and h.detach_result == "nil" then return nil end
				if callback == nil and h.detach_result == "true" then return true end
				if callback == nil and h.detach_result == "foreign" then return {} end
				if callback ~= nil and h.bind_throws then error("native bind applied before wrapper exception") end
				return self
			end
			h.controllers[#h.controllers + 1] = controller
			h.userdata_refs[controller] = true -- UCC toLua pins its own udRef, independent of callback nil.
			return controller
		end
		h.native_new = new_controller
		_G.hs = { webview = { usercontent = { new = new_controller } }, json = { encode = Json.encode } }
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return { width = 600, height = 400 } end,
			get_centered_frame = function(width, height) return { x = 0, y = 0, w = width, h = height } end,
			show_webview = function(options)
				if h.factory_refuses then return nil end
				local view = { options = options, deleted = false, evaluations = {} }
				function view:evaluateJavaScript(script)
					assert(not self.deleted, "retired window cannot receive JavaScript")
					self.evaluations[#self.evaluations + 1] = script
					return self
				end
				function view:delete()
					if self.deleted then return end
					self.deleted = true
					if options.on_close then options.on_close() end
					-- Disposal releases window callbacks, independently of UCC roots.
					options.on_close, options.on_navigation = nil, nil
				end
				h.views[#h.views + 1] = view
				return view
			end,
		}
		local picker = require("ui.action_picker")
		function h.open(callback)
			return picker.open({ title = "UCC retention pilot", items = {} }, callback or function() return true end)
		end
		function h.post(controller, view, body)
			local callback = h.callback_refs[controller]
			if callback then callback({ name = controller.name, webView = view, body = body }) end
		end
		function h.count(registry)
			local count = 0
			for _ in pairs(registry) do count = count + 1 end
			return count
		end
		scenario(picker, h)
	end)
end

return with_picker
