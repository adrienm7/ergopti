--- tests/unit/modules/llm/runtime/test_scope_native_ack.lua

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
			local visible, refuse, raises, on_hide, on_show, refuse_show = true, true, false, nil, nil, false
			local noop = function() end
			local window = setmetatable({
				get_screen = function() return { get_rgba_visual = function() return nil end } end,
				get_visible = function() return visible end,
				show_all = function() if on_show then on_show() end; visible = true; if refuse_show then return false end end,
				hide = function()
					if raises then error("GTK refusal") end
					if not refuse then if on_hide then on_hide() end; visible = false end
				end,
			}, { __index = function() return noop end })
			local renderer = require("adapters.graphics_renderer")
			renderer._set_binding_for_test({ Gtk = { Window = function() return window end },
				Pango = { FontDescription = { from_string = function() return { set_size = noop } end } },
				PangoCairo = { create_layout = function() return { set_font_description = noop,
					set_text = noop, get_pixel_size = function() return 10, 10 end } end },
				cairo = { Context = { create = noop }, ImageSurface = { create = noop }, Region = { create = noop } },
			})
			local options = { style = {
				fonts = { main = "sans" }, sizes = { main = 12 },
				-- Every key the shipped config requires (ui/tooltip/config.lua), the
				-- shortcut column's two included.
				layout = { pad_x = 1, pad_y = 1, line_spacing = 1, label_gap = 1, llm_max_content_width = 100 },
				positioning = {}, tint = {}, colors = { bg = {} },
			} }
			helpers.assert_true(renderer.show({{ text = "offer" }}, options))
			local during_show
			on_show = function() during_show = { renderer.destroy(), renderer.hide() } end
			helpers.assert_true(renderer.show({{ text = "offer" }}, options))
			helpers.assert_eq(during_show, { false, false }, "a draw must retain its native window until it finishes")
			on_show = function() error("draw failed") end
			local called = pcall(renderer.show, { { text = "offer" } }, options)
			helpers.assert_eq(called, false)
			on_show = nil
			refuse_show = true
			helpers.assert_eq(renderer.show({ { text = "offer" } }, options), false,
				"an explicit native refusal must not acknowledge a completed draw")
			refuse_show = false
			for _, method in ipairs({ "resize", "move", "queue_draw" }) do
				local original = window[method]
				window[method] = function() return false end
				helpers.assert_eq(renderer.show({ { text = "offer" } }, options), false, method .. " refusal must propagate")
				window[method] = original
			end
			helpers.assert_true(renderer.show({ { text = "offer" } }, options), "draw ownership is released after exceptions")
			helpers.assert_eq(renderer.hide(), false, "a void hide call does not prove the window disappeared")
			helpers.assert_true(renderer.is_visible())
			raises = true
			helpers.assert_eq(renderer.hide(), false)
			raises, refuse = false, false
			local nested
			on_hide = function() nested = { renderer.destroy(), renderer.show({ { text = "new" } }, options), renderer.hide() } end
			helpers.assert_true(renderer.hide())
			helpers.assert_eq(nested, { false, false, false }, "a hide callback cannot replace or retire the native window")
			helpers.assert_eq(renderer.is_visible(), false)
			local destroy_calls = 0
			nested = nil
			window.destroy = function()
				destroy_calls = destroy_calls + 1
				if destroy_calls == 1 then return false end
				if destroy_calls == 2 then error("GTK destroy refused") end
				nested = { renderer.hide(), renderer.show({}, {}), renderer.destroy() }
			end
			helpers.assert_eq(renderer.destroy(), false, "a refused destroy keeps the native owner for retry")
			helpers.assert_eq(renderer.destroy(), false, "a throwing destroy keeps the native owner for retry")
			helpers.assert_true(renderer.destroy())
			helpers.assert_eq(destroy_calls, 3)
			helpers.assert_eq(nested, { false, false, false }, "destroy owns the window through reentrant callbacks")
		end)
	end)
end)
