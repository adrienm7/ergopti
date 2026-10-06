--- tests/unit/ui/menu/test_program_provider_picker.lua

--- Actual public Hammerspoon picker sessions; native page receipts are controlled.
--- These cases do not claim SDK, uv process-group or physical WebView qualification.
local helpers = require("tests.helpers")
local SCALAR = '{"version":1,"executable":"/private/tool","arguments":["two words",""]}'

local function fixture(body)
	local saved, old_hs = {}, _G.hs
	for key, value in pairs(package.loaded) do saved[key] = value end
	local f = { pages = {}, owners = {}, calls = {}, delete_throws = false }
	local ok, failure = xpcall(function()
		package.loaded.program_provider_picker = nil
		package.loaded["ui.action_picker"] = nil
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.paths"] = { shared = function() return "/controlled/shared" end }
		package.loaded["adapters.program_providers"] = { create = function()
			local owner = { resolutions = 0, invalidations = 0, retired = false }
			owner.discover = function() return { choices = { { key = "opaque-choice", label = "Reviewed provider" } } } end
			owner.resolve = function(key)
				owner.resolutions = owner.resolutions + 1
				if owner.retired or key ~= "opaque-choice" then return nil end
				return SCALAR
			end
			owner.invalidate = function() owner.invalidations = owner.invalidations + 1; owner.retired = true; return true end
			f.owners[#f.owners + 1] = owner
			return owner
		end }
		_G.hs = { webview = { usercontent = { new = function()
			local content = {}
			function content:setCallback(callback) self.callback = callback end
			f.content = content
			return content
		end } }, json = { encode = function(payload) f.payload = payload; return "{}" end } }
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return { width = 600, height = 500 } end,
			get_centered_frame = function() return {} end,
			show_webview = function(options)
				local page = { options = options, content = options.usercontent, scripts = {}, deletes = 0 }
				function page:evaluateJavaScript(script) self.scripts[#self.scripts + 1] = script end
				function page:delete()
					self.deletes = self.deletes + 1
					options.on_close()
					if f.delete_throws then error("controlled native deletion refusal") end
				end
				f.pages[#f.pages + 1] = page
				return page
			end,
		}
		f.picker = require("ui.action_picker")
		function f.open(callback)
			return f.picker.open({ items = {} }, callback or function(id, parameter)
				f.calls[#f.calls + 1] = { id, parameter }; return true
			end)
		end
		function f.message(page, body)
			page.content.callback({ body = body })
		end
		function f.confirm(page, key)
			f.message(page, { action = "confirm", id = "run_program", providerKey = key or "opaque-choice", programArguments = {} })
		end
		body(f)
	end, debug.traceback)
	_G.hs = old_hs
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	if not ok then error(failure, 0) end
end

helpers.describe("Production macOS program provider picker sessions", function()
	helpers.it("projects only public choices and delivers the resolved scalar through the existing callback", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			f.message(f.pages[1], { action = "ready" })
			helpers.assert_eq(f.payload.programProviders, { choices = { { key = "opaque-choice", label = "Reviewed provider" } } })
			f.confirm(f.pages[1])
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
			helpers.assert_true(f.owners[1].retired)
		end)
	end)
	helpers.it("stale old-page choices cannot resolve or confirm a replacement binding", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			local old = f.pages[1]
			helpers.assert_true(f.open())
			f.confirm(old)
			helpers.assert_eq(f.owners[1].resolutions, 0)
			helpers.assert_eq(f.owners[2].resolutions, 0)
			helpers.assert_eq(#f.calls, 0)
			f.confirm(f.pages[2])
			helpers.assert_eq(#f.calls, 1)
		end)
	end)
	helpers.it("resolver-driven replacement cannot publish the previous binding", function()
		fixture(function(f)
			local old, replacement = 0, 0
			helpers.assert_true(f.open(function() old = old + 1; return true end))
			f.owners[1].resolve = function()
				helpers.assert_true(f.open(function() replacement = replacement + 1; return true end))
				return SCALAR
			end
			f.confirm(f.pages[1])
			helpers.assert_eq(old, 0)
			helpers.assert_eq(replacement, 0)
			f.confirm(f.pages[2])
			helpers.assert_eq(replacement, 1)
		end)
	end)
	helpers.it("recursive resolution cannot invoke the durable callback twice", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			local page, resolutions = f.pages[1], 0
			f.owners[1].resolve = function()
				resolutions = resolutions + 1
				if resolutions == 1 then f.confirm(page) end
				return SCALAR
			end
			f.confirm(page)
			helpers.assert_eq(resolutions, 1)
			helpers.assert_eq(#f.calls, 1)
		end)
	end)
	helpers.it("retains the provider after synchronous on-close followed by native delete throw", function()
		fixture(function(f)
			helpers.assert_true(f.open(function() return false end))
			local page, provider = f.pages[1], f.owners[1]
			f.delete_throws = true
			helpers.assert_eq(f.picker.close(), false)
			helpers.assert_eq(provider.invalidations, 0, "ambiguous public native close cannot revoke discovery")
			helpers.assert_eq(f.open(), false)
			helpers.assert_eq(#f.owners, 1)
			f.confirm(page)
			helpers.assert_eq(provider.resolutions, 1, "same captured provider remains retryable")
			f.delete_throws = false
			helpers.assert_true(f.picker.close())
			helpers.assert_eq(provider.invalidations, 1)
		end)
	end)
	helpers.it("a genuine public user-close invalidates choices without affecting its successor", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			local old = f.pages[1]
			old.options.on_close()
			helpers.assert_true(f.owners[1].retired)
			helpers.assert_true(f.open())
			old.options.on_close()
			f.confirm(old)
			helpers.assert_eq(f.owners[2].invalidations, 0)
			helpers.assert_eq(#f.calls, 0)
			f.confirm(f.pages[2])
			helpers.assert_eq(#f.calls, 1)
		end)
	end)
	for _, invalid in ipairs({ true, 0, "", "foreign-choice" }) do
		helpers.it("refuses malformed or foreign opaque choices: " .. tostring(invalid), function()
			fixture(function(f)
				helpers.assert_true(f.open())
				local page = f.pages[1]
				f.message(page, { action = "confirm", id = "run_program", providerKey = invalid })
				helpers.assert_eq(#f.calls, 0)
				helpers.assert_eq(page.deletes, 0)
				helpers.assert_eq(page.scripts[#page.scripts], "programProviderRefused()")
			end)
		end)
	end
	helpers.it("refused persistence keeps the same discovery retryable and manual fallback available", function()
		fixture(function(f)
			local calls = 0
			helpers.assert_true(f.open(function(_, parameter)
				calls = calls + 1
				helpers.assert_eq(parameter, SCALAR)
				return calls > 1
			end))
			f.confirm(f.pages[1])
			helpers.assert_eq(f.owners[1].invalidations, 0)
			f.message(f.pages[1], { action = "confirm", id = "run_program", parameter = SCALAR })
			helpers.assert_eq(calls, 2)
			helpers.assert_true(f.owners[1].retired)
		end)
	end)
end)
