--- tests/unit/ui/menu/menu_llm/settings/test_settings_transaction_shared_controls.lua

--- ==============================================================================
--- MODULE: Transactional LLM Settings Regression
--- DESCRIPTION:
--- Proves that every LLM setting action restores state, native settings, runtime,
--- durable preferences, and rendered menu state when any boundary refuses.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.settings.settings_transaction_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.settings.settings_transaction_fixture")
local clone_value = Fixture.clone_value
local find_item = Fixture.find_item
local indentation_item = Fixture.indentation_item
local token_streaming_corpus = Fixture.token_streaming_corpus
local with_fixture = Fixture.with_fixture





-- =====================================================
-- =====================================================
-- ======= 9/ Shared Automatic Temperature Check =======
-- =====================================================
-- =====================================================

--- Reads independent checkbox states and useful prediction counts.
--- @return table corpus
local function auto_raise_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/auto_raise_temperature.json", "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("LLM shared automatic temperature control", function()
	helpers.it("replays both states and prediction counts through the actual setting owner (shared-auto-raise)", function()
		local corpus = auto_raise_corpus()
		helpers.assert_eq(#corpus.states, 2)
		helpers.assert_eq(#corpus.prediction_counts, 2)
		for _, selected in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				with_fixture({auto_raise_state = selected, prediction_count = count}, function(fixture)
					local menu = fixture.temperature_menu()
					local row = assert(find_item(menu, corpus.row.i18n))
					helpers.assert_eq(row.checked or false, selected)
					helpers.assert_eq(row.disabled or false, count < 2)
					local result = row.fn()
					helpers.assert_eq(result, count >= 2)
					local expected = selected
					if count >= 2 then expected = not selected end
					helpers.assert_eq(fixture.state.llm_auto_raise_temp, expected)
					helpers.assert_eq(fixture.runtime.llm_auto_raise_temp, expected)
					helpers.assert_eq(fixture.persisted().llm_auto_raise_temp, expected)
					helpers.assert_eq(fixture.calls.save, count >= 2 and 1 or 0)
					helpers.assert_eq(fixture.calls.menu, count >= 2 and 1 or 0)
				end)
			end
		end
	end)

	helpers.it("follows the changed shared label and order without rewriting numeric controls (shared-auto-raise)", function()
		local corpus = auto_raise_corpus()
		with_fixture({auto_label = corpus.alternate_i18n, auto_first = true}, function(fixture)
			local menu = fixture.temperature_menu()
			helpers.assert_eq(menu[1].title, corpus.alternate_i18n)
			helpers.assert_true(menu[2].title:find("menu.llm.temperature_label", 1, true) ~= nil)
			helpers.assert_eq(find_item(menu, corpus.row.i18n), nil)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("refuses a delayed command after the actual prediction count becomes one (shared-auto-raise)", function()
		with_fixture({auto_raise_state = true, prediction_count = 2}, function(fixture)
			local row = assert(find_item(fixture.temperature_menu(), auto_raise_corpus().row.i18n))
			fixture.state.llm_num_predictions = 1
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.state.llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.runtime.llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.persisted().llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("keeps every publication after the existing writer refuses the command (shared-auto-raise)", function()
		with_fixture({auto_raise_state = true, failures = {{name = "save", mode = "false"}}}, function(fixture)
			local row = assert(find_item(fixture.temperature_menu(), auto_raise_corpus().row.i18n))
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.state.llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.runtime.llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.persisted().llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.rendered().llm_auto_raise_temp, true)
			helpers.assert_eq(fixture.calls.menu, 0)
		end)
	end)
end)





-- ==================================
-- ==================================
-- ======= 6/ Show-All Parity =======
-- ==================================
-- ==================================

--- Loads explicit historical display semantics independently of native policy.
--- @return table
local function show_all_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/show_all_control.json", "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("LLM shared Show-all check", function()
	helpers.it("replays both progressive polarities through acknowledged native publication (shared-show-all)", function()
		local corpus = show_all_corpus()
		helpers.assert_eq(#corpus.states, 2)
		for _, expected in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				with_fixture({progressive_state = expected.progressive, prediction_count = count}, function(fixture)
					local row = assert(find_item(fixture.streaming_menu(), corpus.row.i18n))
					helpers.assert_eq(row.checked, expected.show_all)
					helpers.assert_eq(row.disabled == true, count < 2)
					local changed = row.fn()
					helpers.assert_eq(changed, count >= 2)
					local value = expected.progressive
					if count >= 2 then value = not expected.progressive end
					helpers.assert_eq(fixture.state.llm_streaming_multi, value)
					helpers.assert_eq(fixture.runtime.llm_streaming_multi, value)
					helpers.assert_eq(fixture.persisted().llm_streaming_multi, value)
				end)
			end
		end
	end)

	helpers.it("consumes the common Show-all label and row order (shared-show-all)", function()
		local corpus = show_all_corpus()
		with_fixture({progressive_state = true, show_all_label = corpus.alternate_i18n, show_all_first = true}, function(fixture)
			local rows = fixture.streaming_menu()
			helpers.assert_eq(rows[1].title, corpus.alternate_i18n)
			helpers.assert_eq(rows[1].checked, false)
			helpers.assert_eq(rows[2].title, "menu.llm.show_info_bar")
			helpers.assert_eq(rows[#rows], indentation_item(rows), "moving Show-all never revives a native leading indentation policy")
		end)
	end)

	helpers.it("refuses delayed Show-all changes when the current count loses its second slot (shared-show-all)", function()
		local options = {progressive_state = true, prediction_count = 2}
		with_fixture(options, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), show_all_corpus().row.i18n))
			fixture.state.llm_num_predictions = 1
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.state.llm_streaming_multi, true)
			helpers.assert_eq(fixture.runtime.llm_streaming_multi, true)
			helpers.assert_eq(fixture.persisted().llm_streaming_multi, true)
			helpers.assert_eq(fixture.calls.save, 0)
			fixture.state.llm_num_predictions = 2
			options.paused = true
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, 0)
		end)
	end)

	helpers.it("keeps runtime, durable and rendered polarity after false, nil or throwing writers (shared-show-all)", function()
		for _, mode in ipairs({"false", "nil", "throw"}) do
			with_fixture({progressive_state = true, failures = {{name = "save", mode = mode}}}, function(fixture)
				local row = assert(find_item(fixture.streaming_menu(), show_all_corpus().row.i18n))
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(fixture.state.llm_streaming_multi, true)
				helpers.assert_eq(fixture.runtime.llm_streaming_multi, true)
				helpers.assert_eq(fixture.persisted().llm_streaming_multi, true)
				helpers.assert_eq(fixture.rendered().llm_streaming_multi, true)
				helpers.assert_eq(fixture.calls.menu, 0)
			end)
		end
	end)
end)






-- =============================================
-- =============================================
-- ======= 11/ Shared Automatic Triggers =======
-- =============================================
-- =============================================

--- Reads independent automatic-trigger states and declaration identity.
--- @return table corpus
local function trigger_corpus()
	local file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/automatic_trigger_controls.json", "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("LLM shared automatic trigger controls", function()
	helpers.it("replays every bool pair through actual durable setters independently of count (shared-automatic-triggers)", function()
		local corpus = trigger_corpus()
		helpers.assert_eq(#corpus.states, 4)
		for _, states in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				for index, expected in ipairs(corpus.rows) do
					with_fixture({trigger_states = states, prediction_count = count}, function(fixture)
						local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
						helpers.assert_eq(row.checked or false, states[index])
						helpers.assert_eq(row.disabled or false, false)
						helpers.assert_eq(row.fn(), true)
						helpers.assert_eq(fixture.state[expected.state], not states[index])
						helpers.assert_eq(fixture.runtime[expected.state], not states[index])
						helpers.assert_eq(fixture.persisted()[expected.state], not states[index])
						local neighbor = corpus.rows[index == 1 and 2 or 1]
						helpers.assert_eq(fixture.persisted()[neighbor.state], states[index == 1 and 2 or 1])
						helpers.assert_eq(fixture.calls.save, 1)
						helpers.assert_eq(fixture.calls.menu, 1)
					end)
				end
			end
		end
	end)

	helpers.it("honors declaration label and order without publishing sibling settings (shared-automatic-triggers)", function()
		local corpus = trigger_corpus()
		with_fixture({trigger_label = corpus.alternate_i18n, trigger_first = true}, function(fixture)
			local rows = fixture.trigger_menu()
			helpers.assert_eq(rows[1].title, corpus.alternate_i18n)
			helpers.assert_true(rows[2].title:find("menu.llm.debounce_label", 1, true) ~= nil)
			helpers.assert_eq(find_item(rows, corpus.rows[1].i18n), nil)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("rereads current values and refuses old callbacks after pause or master withdrawal (shared-automatic-triggers)", function()
		for _, expected in ipairs(trigger_corpus().rows) do
			local options = {trigger_states = {false, false}, prediction_count = 2}
			with_fixture(options, function(fixture)
				local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
				helpers.assert_eq(row.fn(), true)
				fixture.state.llm_num_predictions = 1
				helpers.assert_eq(row.fn(), true, "changing variant count does not revoke a trigger setting")
				helpers.assert_eq(fixture.state[expected.state], false)
				local saves, runtime_calls = fixture.calls.save, fixture.calls.runtime
				options.paused = true
				helpers.assert_eq(row.fn(), false)
				options.paused = false
				fixture.state.llm_enabled = false
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(fixture.calls.save, saves)
				helpers.assert_eq(fixture.calls.runtime, runtime_calls)
				helpers.assert_eq(fixture.persisted()[expected.state], false)
			end)
		end
	end)

	helpers.it("preserves all publication boundaries on false nil and throwing writers (shared-automatic-triggers)", function()
		for _, expected in ipairs(trigger_corpus().rows) do
			for _, mode in ipairs({"false", "nil", "throw"}) do
				with_fixture({failures = {{name = "save", mode = mode}}}, function(fixture)
					local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
					helpers.assert_eq(row.fn(), false)
					helpers.assert_eq(fixture.state[expected.state], false)
					helpers.assert_eq(fixture.runtime[expected.state], false)
					helpers.assert_eq(fixture.persisted()[expected.state], false)
					helpers.assert_eq(fixture.rendered()[expected.state], false)
					helpers.assert_eq(fixture.calls.menu, 0)
				end)
			end
		end
	end)
end)

--- Reads independent native capability and stale-command expectations.
--- @return table corpus

helpers.describe("shared token streaming policy", function()
	helpers.it("replays independent capability and admission vectors (shared-token-streaming)", function()
		local policy = require("llm.display_policy")
		local corpus = token_streaming_corpus()
		helpers.assert_eq(#corpus.capabilities, 9)
		helpers.assert_eq(#corpus.cases, 15)
		for _, vector in ipairs(corpus.capabilities) do
			helpers.assert_eq(policy.streaming_capable(vector.platform, vector.backend), vector.capable)
		end
		for _, vector in ipairs(corpus.cases) do
			local expected, current = {}, {}
			for key, value in pairs(corpus.base) do expected[key], current[key] = value, value end
			for key, value in pairs(vector.expected or {}) do expected[key] = value end
			for key, value in pairs(vector.current) do current[key] = value end
			local decision = policy.streaming_intent(expected, current)
			helpers.assert_eq(decision.admitted, vector.admitted, vector.id)
			if vector.admitted then helpers.assert_eq(decision.value, vector.value, vector.id) end
		end
	end)
end)

helpers.describe("native streaming checkbox admission", function()
	for _, condition in ipairs({ "paused", "off", "backend", "runtime disagreement", "retired owner" }) do
		helpers.it("refuses a retained checkbox after " .. condition .. " (shared-token-streaming)", function()
			local options = {}
			with_fixture(options, function(fixture)
				local row = assert(find_item(fixture.streaming_menu(), "menu.llm.show_streaming"))
				if condition == "paused" then options.paused = true end
				if condition == "off" then fixture.state.llm_enabled = false; fixture.runtime.llm_enabled = false end
				if condition == "backend" then fixture.state.llm_backend = "api"; fixture.runtime.llm_backend = "api" end
				if condition == "runtime disagreement" then fixture.runtime.llm_streaming = true end
				if condition == "retired owner" then fixture.retire_display() end
				local before = fixture.calls.save
				local result = row.fn()
				helpers.assert_eq(result, false)
				helpers.assert_eq(fixture.calls.save, before)
				helpers.assert_eq(fixture.state.llm_streaming, false)
				helpers.assert_eq(fixture.persisted().llm_streaming, false)
				helpers.assert_eq(fixture.rendered().llm_streaming, false)
			end)
		end)
	end
end)

helpers.describe("macOS acknowledged token streaming checkbox", function()
	for _, race in ipairs({"before menu construction", "before forward acknowledgement", "after forward acknowledgement", "between own acknowledgement and receipt admission"}) do
	helpers.it("preserves a real foreign master winner " .. race .. " through compensation and a fresh second click (shared-token-streaming)", function()
		local path = require("infra.config_paths").get("ConfigTomlPath")
		local initial = '[llm]\nenabled = true\n[llm.models]\nselected = "ollama"\n[llm.display]\nstreaming = false\nstreaming_multi = true\n[private]\nfuture = 42\n'
		local external = race == "before menu construction" and (initial .. '[llm.generation]\ntemperature = 0.9\n')
			or initial:gsub('enabled = true', 'enabled = false')
		local disk, attempts, unconditional, wrong_path = initial, 0, 0, false
		local previous_fs, previous_preferences = package.loaded["adapters.file_system"], package.loaded["infra.preferences"]
		package.loaded["adapters.file_system"] = {
			read_with_status = function(read_path)
				if read_path ~= path then wrong_path = true end
				return disk, "ok"
			end,
			write = function() unconditional = unconditional + 1; return false end,
			write_if_unchanged = function(write_path, content, source)
				if write_path ~= path then wrong_path = true end
				attempts = attempts + 1
				if attempts == 1 and race == "before forward acknowledgement" then disk = external end
				if source.status ~= "ok" or source.content ~= disk then return false, "source changed" end
				disk = content
				return true
			end,
		}
		package.loaded["infra.preferences"] = nil
		local preferences = require("infra.preferences")
		local ok, err = xpcall(function()
			local _, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			with_fixture({preferences = preferences, preference_source = path,
				failures = race ~= "before forward acknowledgement" and {{name = "menu", mode = "false"}} or {},
				after_save = function()
					if race == "between own acknowledgement and receipt admission" then disk = external end
				end,
				before_menu = function(occurrence)
					if occurrence == 1 and race == "after forward acknowledgement" then disk = external end
				end,
			}, function(fixture)
				local previous_temperature = fixture.state.llm_temperature
				if race == "before menu construction" then disk = external end
				local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
				if race == "before menu construction" then
					if row.fn then helpers.assert_eq(row.fn(), false) end
					helpers.assert_eq(disk, external, "stale compensation cannot overwrite the foreign temperature")
					helpers.assert_eq(row.disabled, true, "an already foreign full-document image is not action authority")
					helpers.assert_eq(attempts, 0)
					helpers.assert_eq(fixture.calls.save, 0)
					helpers.assert_eq(fixture.manager.scope_idle(), true)
					helpers.assert_eq(preferences.publication_receipt(path), {id = 0})
					helpers.assert_eq(preferences.source_snapshot(path), {status = "ok", content = initial})
					helpers.assert_eq(fixture.state.llm_temperature, previous_temperature)
					helpers.assert_eq(fixture.runtime.llm_temperature, previous_temperature)
					helpers.assert_eq(require("infra.toml.codec").decode(disk).llm.generation.temperature, 0.9)
					helpers.assert_eq(unconditional, 0)
					helpers.assert_eq(wrong_path, false)
					return
				end
				helpers.assert_eq(row.disabled == true, false)
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(disk, external, "compensation cannot turn the external master on")
				local receipt = preferences.publication_receipt(path)
				if race == "before forward acknowledgement" then
					helpers.assert_eq(receipt.id, 0)
					helpers.assert_eq(preferences.source_snapshot(path), {status = "ok", content = external})
				else
					helpers.assert_eq(receipt.id, 1, "only the true owned forward save issues authority")
					helpers.assert_eq(preferences.source_matches(receipt.source, {status = "ok", content = external}), false)
					local acknowledged = require("infra.toml.codec").decode(receipt.source.content)
					helpers.assert_eq(acknowledged.llm.enabled, true)
					helpers.assert_eq((acknowledged.llm.display or {}).streaming, nil, "acknowledged true follows the shared sparse default")
					helpers.assert_eq(preferences.source_snapshot(path), receipt.source)
				end
				helpers.assert_eq(attempts, 1, "compensation cannot borrow a foreign source")
				helpers.assert_eq(fixture.manager.scope_idle(), false, "refused compensation remains owned debt")
				helpers.assert_eq(fixture.state.llm_enabled, true)
				helpers.assert_eq(fixture.runtime.llm_enabled, true)
				local before = attempts
				local fresh = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
				helpers.assert_eq(fresh.disabled, true)
				if fresh.fn then helpers.assert_eq(fresh.fn(), false) end
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.apply_setting_transaction({
					key = "llm_streaming", value = false, runtime_fn = "set_llm_streaming", publish_setting = false,
				}), false, "a later action cannot borrow the foreign image to settle retained debt")
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.scope_idle(), false)
				helpers.assert_eq(disk, external)
				helpers.assert_eq(unconditional, 0)
				helpers.assert_eq(wrong_path, false)
			end)
		end, debug.traceback)
		package.loaded["adapters.file_system"], package.loaded["infra.preferences"] = previous_fs, previous_preferences
		if not ok then error(err, 0) end
	end)

	end

	helpers.it("refuses canonical master withdrawal independently of menu and runtime RAM (shared-token-streaming)", function()
		local canonical = {llm_enabled = true, llm_backend = "ollama", llm_streaming = false, llm_streaming_multi = true}
		with_fixture({preferences = {current_view = function() return clone_value(canonical), {status = "ok", content = tostring(canonical.llm_enabled)} end,
			source_snapshot = function() return {status = "ok", content = "true"} end,
			source_matches = function(expected, current) return expected.content == current.content end}}, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
			canonical.llm_enabled = false
			local before = fixture.calls.save
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, before)
			helpers.assert_eq(fixture.state.llm_enabled, true)
			helpers.assert_eq(fixture.runtime.llm_enabled, true)
			helpers.assert_eq(fixture.state.llm_streaming, false)
		end)
	end)

	helpers.it("retires a held callback after actual progressive off/on transactions (shared-token-streaming)", function()
		with_fixture({}, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
			for _, value in ipairs({false, true}) do
				helpers.assert_eq(fixture.manager.apply_setting_transaction({
					key = "llm_streaming_multi", value = value,
					runtime_fn = "set_llm_streaming_multi", publish_setting = false,
				}), true)
			end
			local before = fixture.calls.save
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, before)
			helpers.assert_eq(fixture.state.llm_streaming, false)
			helpers.assert_eq(fixture.persisted().llm_streaming, false)
		end)
	end)

	helpers.it("refuses actual progressive runtime disagreement (shared-token-streaming)", function()
		with_fixture({}, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
			fixture.runtime.llm_streaming_multi = false
			local before = fixture.calls.save
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, before)
			helpers.assert_eq(fixture.state.llm_streaming, false)
		end)
	end)

	helpers.it("retains native rollback after false, nil or throwing durable writers (shared-token-streaming)", function()
		for _, mode in ipairs({"false", "nil", "throw"}) do
			with_fixture({failures = {{name = "save", mode = mode}}}, function(fixture)
				local row = assert(find_item(fixture.streaming_menu(), token_streaming_corpus().row.i18n))
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(fixture.state.llm_streaming, false)
				helpers.assert_eq(fixture.runtime.llm_streaming, false)
				helpers.assert_eq(fixture.persisted().llm_streaming, false)
				helpers.assert_eq(fixture.rendered().llm_streaming, false)
				helpers.assert_eq(fixture.calls.menu, 0)
			end)
		end
	end)
end)





-- ============================================
-- ============================================
-- ======= 8/ Shared Indentation Choice =======
-- ============================================
-- ============================================

helpers.describe("macOS shared indentation choice", function()
	helpers.it("renders fifteen distinct signed translated choices with selected canonical caption (shared-indentation)", function()
		with_fixture({}, function(fixture)
			local rows = fixture.streaming_menu()
			local parent = indentation_item(rows)
			helpers.assert_eq(#parent.menu, 15)
			for index, value in ipairs({-7,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,7}) do
				local unit = value == 0 and "menu.llm.indent_none" or math.abs(value) == 1 and "menu.llm.indent_space" or "menu.llm.indent_spaces"
				local prefix = value == 0 and "" or (value > 0 and "+" or "") .. value .. " "
				helpers.assert_eq(parent.menu[index].title, prefix .. unit)
				helpers.assert_eq(parent.menu[index].checked or false, value == fixture.state.llm_pred_indent)
			end
			helpers.assert_eq(parent.title, "menu.llm.indent_label: +1 menu.llm.indent_space")
			helpers.assert_eq(rows[#rows], parent, "the canonical all-OS declaration owns the trailing position")
		end)
	end)

	for _, condition in ipairs({"paused", "off", "single", "runtime disagreement", "retired owner"}) do
		helpers.it("refuses a retained native choice after " .. condition .. " (shared-indentation)", function()
			local options = {}
			with_fixture(options, function(fixture)
				local command = assert(indentation_item(fixture.streaming_menu()).menu[1].fn)
				if condition == "paused" then options.paused = true end
				if condition == "off" then fixture.state.llm_enabled, fixture.runtime.llm_enabled = false, false end
				if condition == "single" then fixture.state.llm_num_predictions, fixture.runtime.llm_num_predictions = 1, 1 end
				if condition == "runtime disagreement" then fixture.runtime.llm_pred_indent = 2 end
				if condition == "retired owner" then fixture.retire_display() end
				local before = fixture.calls.save
				helpers.assert_eq(command(), false)
				helpers.assert_eq(fixture.calls.save, before)
				helpers.assert_eq(fixture.state.llm_pred_indent, 1)
				helpers.assert_eq(fixture.persisted().llm_pred_indent, 1)
				helpers.assert_eq(fixture.calls.menu, 0)
			end)
		end)
	end

	helpers.it("retains runtime and native settings rollback on false, nil and throwing canonical writers (shared-indentation)", function()
		for _, mode in ipairs({"false", "nil", "throw"}) do
			with_fixture({failures = {{name = "save", mode = mode}}}, function(fixture)
				local command = assert(indentation_item(fixture.streaming_menu()).menu[1].fn)
				helpers.assert_eq(command(), false)
				helpers.assert_eq(fixture.state.llm_pred_indent, 1)
				helpers.assert_eq(fixture.runtime.llm_pred_indent, 1)
				helpers.assert_eq(fixture.persisted().llm_pred_indent, 1)
				helpers.assert_eq(fixture.manager.scope_idle(), true)
				helpers.assert_true(fixture.calls.save >= 2, "native compensation must be acknowledged rather than skipped")
			end)
		end
	end)

	helpers.it("publishes negative, zero and positive numeric choices only once per current owner (shared-indentation)", function()
		for _, index in ipairs({1,8,15}) do
			with_fixture({}, function(fixture)
				local command = assert(indentation_item(fixture.streaming_menu()).menu[index].fn)
				local value = index - 8
				helpers.assert_eq(command(), true)
				helpers.assert_eq(fixture.state.llm_pred_indent, value)
				helpers.assert_eq(fixture.runtime.llm_pred_indent, value)
				helpers.assert_eq(fixture.persisted().llm_pred_indent, value)
				helpers.assert_eq(fixture.calls.save, 1)
				helpers.assert_eq(command(), false)
				helpers.assert_eq(fixture.calls.save, 1)
			end)
		end
	end)
end)
