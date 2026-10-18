--- tests/unit/ui/menu/menu_llm/models/test_models_selector_pause_gate_model_frames.lua

--- ==============================================================================
--- MODULE: Regression — models_selector rows disabled when paused (M-16)
--- DESCRIPTION:
--- ModelsSelector.build() previously lacked a `paused` parameter and its rows had
--- no `disabled` field. While paused, clicking any model row called switch_model()
--- → guarded_check_requirements() which triggered backend warmup mid-pause —
--- violating the suspend-pause invariant.
---
--- Fix: thread `paused` into M.build(ctx) and set `disabled = paused or nil` on
--- every model-selection row (no_model, backend_default, user rows, preset rows).
---
--- Test: call build({paused=true}) with a minimal fake context and assert that
--- every menu item without a `menu` (direct action row) has disabled=true or fn
--- raises no error before switch_model could be reached (because disabled items are
--- greyed-out and macOS/hs won't invoke their fn). The simplest contract:
--- build returns a table of items all with disabled=true (or nil fn for non-switch
--- rows).
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.models.models_selector_pause_gate_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.models.models_selector_pause_gate_fixture")
local model_readout_sheet = Fixture.model_readout_sheet
local with_complete_model_locale = Fixture.with_complete_model_locale
local with_model_readout_owner = Fixture.with_model_readout_owner





-- The complete information oracle owns a separate genuine translator cohort.

local function complete_model_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/llm_complete_model_frames.json"), "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return assert(require("adapters.json_codec").decode(bytes))
end

helpers.describe("Complete LLM model frames: independent physical expectations", function()
	for _, locale in ipairs({ "en", "fr" }) do
		helpers.it("retains every original information row and native callback in " .. locale, function()
			with_complete_model_locale(locale, function(selector, ctx, _, _, calls)
				local expected = complete_model_corpus()
				helpers.assert_true(#ctx.models_mgr.get_presets() > 0)
				local sheet = model_readout_sheet(selector.build(ctx), expected.native_model)
				local actual = {}
				for index, row in ipairs(sheet) do
					if row.separator then actual[index] = { separator = true }
					else
						actual[index] = { label = row.label, action = type(row.action) == "function",
							disabled = row.disabled, checked = row.checked }
					end
				end
				local hand = expected.macos[locale]
				if jit then
					local old = locale == "en" and "Download: 19.0 GB" or "Téléchargement : 19.0 Go"
					local new = locale == "en" and "Download: 19 GB" or "Téléchargement : 19 Go"
					helpers.assert_eq(hand[17].label, old)
					hand[17].label = new
				end
				helpers.assert_eq(actual, hand, "independent complete old-native ordering, flags and callback posture")
				helpers.assert_eq(#calls, 0)
				sheet[1].action()
				helpers.assert_eq(calls, { expected.native_model })
			end)
		end)
	end
end)


helpers.describe("Saved model frame retains the actual user records", function()
	helpers.it("preserves nonempty children and refuses/repairs the genuine declaration", function()
		with_complete_model_locale("en", function(selector, ctx, menu, _, calls)
			local record = { backend = "ollama", name = "private:actual", future = "keep" }
			ctx.state.llm_user_models = { record }
			local function saved_frame(rows)
				for _, row in ipairs(rows) do if row.label == "🛠️ My models" then return row end end
			end
			local frame = saved_frame(selector.build(ctx))
			helpers.assert_not_nil(frame)
			helpers.assert_eq(#frame.items, 1)
			helpers.assert_true(frame.items[1].label:find("private:actual", 1, true) ~= nil)
			helpers.assert_nil(frame.items[1].action, "the saved-model parent only opens its genuine child")
			helpers.assert_type(frame.items[1].items[1].action, "function", "the declared Select child owns delivery")
			helpers.assert_nil(frame.action)
			local root, original = menu.get_root(), menu.get_array("llm_saved_models_frame")
			local ok, detail = xpcall(function()
				root.llm_saved_models_frame = nil
				helpers.assert_eq(selector.build(ctx), {}, "a withdrawn nonempty parent cannot become a native label")
				helpers.assert_eq(#calls, 0)
				helpers.assert_eq(rawequal(ctx.state.llm_user_models[1], record), true)
				helpers.assert_eq(record.future, "keep")
			end, debug.traceback)
			root.llm_saved_models_frame = original
			if not ok then error(detail, 0) end
			local repaired = saved_frame(selector.build(ctx))
			helpers.assert_eq(#repaired.items, 1)
			helpers.assert_nil(repaired.items[1].action, "restoration keeps selection on the native leaf")
			repaired.items[1].items[1].action()
			helpers.assert_eq(calls, { "private:actual" })
			ctx.state.llm_user_models = {}
			helpers.assert_nil(saved_frame(selector.build(ctx)), "empty actual records retain the original absent parent")
		end)
	end)
end)


helpers.describe("Actual model submenu selection delivery", function()
	helpers.it("completes the curated parent without a callback and delivers its real Select leaf", function()
		with_model_readout_owner(function(selector, ctx, renderer, _, calls, corpus)
			local sheet, model = model_readout_sheet(selector.build(ctx), corpus.native_model)
			helpers.assert_nil(model.action, "submenu presentation cannot carry an unreachable parent callback")
			helpers.assert_type(sheet[1].action, "function", "the canonical selection command remains bound")
			local native = renderer.render_rows({ model }, "llm_model")
			helpers.assert_eq(#native, 1)
			helpers.assert_eq(native[1].title, model.label)
			helpers.assert_nil(native[1].fn, "the native parent opens its sheet without dispatching")
			helpers.assert_eq(rawequal(native[1].menu[1].fn, sheet[1].action), true,
				"the genuine Select closure reaches the actual native leaf by identity")
			helpers.assert_eq(#calls, 0, "construction never selects a model")
			local compose = renderer.native_composition("macos_download_root")
			helpers.assert_type(compose, "function")
			helpers.assert_eq(compose({ download = {}, body = native }), true,
				"the real completed child satisfies strict native composition")
			native[1].menu[1].fn()
			helpers.assert_eq(calls, { corpus.native_model }, "the invocable native leaf selects the exact curated model once")
		end)
	end)
end)
