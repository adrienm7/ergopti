--- tests/unit/modules/llm/test_scope_native_ack.lua

local helpers = require("tests.helpers")

local function isolated(names, body)
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local ok, err = pcall(body)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("LLM scope native acknowledgements", function()
	for _, kind in ipairs({ "api_ollama", "api_remote" }) do
		helpers.it("retains " .. kind .. " ownership when transport cancellation refuses", function()
			isolated({ "adapters.http_client", "modules.llm." .. kind }, function()
				local refused, cancellations, completions = true, 0, 0
				package.loaded["adapters.http_client"] = {
					post = function() return true end,
					postStream = function() return true end,
					cancel = function() cancellations = cancellations + 1; return not refused end,
				}
				local backend = require("modules.llm." .. kind)
				local target = kind == "api_ollama" and "http://127.0.0.1:11434"
					or { provider = "cerebras", token = "secret", model = "model", base_url = "" }
				backend.chat(target, "model", {{role = "user", content = "hello"}}, {}, nil,
					function() completions = completions + 1 end)
				helpers.assert_true(backend.is_active())
				helpers.assert_eq(backend.cancel(), false)
				helpers.assert_true(backend.is_active(), "unacknowledged transport remains owned")
				helpers.assert_eq(completions, 0)
				helpers.assert_eq(backend.chat(target, "other", {}, {}, nil, function() end), false,
					"a refused cancellation must not be replaced by another request")
				refused = false
				helpers.assert_true(backend.cancel())
				helpers.assert_eq(cancellations, 3)
				helpers.assert_eq(backend.is_active(), false)
			end)
		end)
	end

	helpers.it("retains an offer when its actual renderer refuses to hide", function()
		isolated({ "ui.tooltip.llm", "modules.llm.display_settings" }, function()
			package.loaded["modules.llm.display_settings"] = { get = function() return false end }
			local overlay = require("ui.tooltip.llm")
			local refused = true
			overlay.init({ style = {}, renderer = {
				show = function() return true end,
				hide = function() return not refused end,
			} })
			helpers.assert_true(overlay.show({{ to_type = "word" }}, {}))
			helpers.assert_eq(overlay.hide(), false)
			helpers.assert_true(overlay.is_showing())
			refused = false
			helpers.assert_true(overlay.hide())
			helpers.assert_eq(overlay.is_showing(), false)
		end)
	end)

	helpers.it("requires native GTK hide readback and retains a failed window for retry", function()
		isolated({ "adapters.graphics_renderer", "tooltip.layout", "tooltip.tint" }, function()
			package.loaded["tooltip.layout"] = { compute_position = function() return { x = 0, y = 0 } end }
			package.loaded["tooltip.tint"] = { mix = function() return {} end }
			local visible, refuse, raises = true, true, false
			local noop = function() end
			local window = setmetatable({
				get_screen = function() return { get_rgba_visual = function() return nil end } end,
				get_visible = function() return visible end,
				hide = function() if raises then error("GTK refusal") end; if not refuse then visible = false end end,
			}, { __index = function() return noop end })
			local renderer = require("adapters.graphics_renderer")
			renderer._set_binding_for_test({ Gtk = { Window = function() return window end },
				Pango = { FontDescription = { from_string = function() return { set_size = noop } end } },
				PangoCairo = { create_layout = function() return { set_font_description = noop,
					set_text = noop, get_pixel_size = function() return 10, 10 end } end },
				cairo = { Context = { create = noop }, ImageSurface = { create = noop }, Region = { create = noop } },
			})
			helpers.assert_true(renderer.show({{ text = "offer" }}, { style = {
				fonts = { main = "sans" }, sizes = { main = 12 },
				layout = { pad_x = 1, pad_y = 1, line_spacing = 1 },
				positioning = {}, tint = {}, colors = { bg = {} },
			} }))
			helpers.assert_eq(renderer.hide(), false, "a void hide call does not prove the window disappeared")
			helpers.assert_true(renderer.is_visible())
			raises = true
			helpers.assert_eq(renderer.hide(), false)
			raises, refuse = false, false
			helpers.assert_true(renderer.hide())
			helpers.assert_eq(renderer.is_visible(), false)
		end)
	end)
end)
