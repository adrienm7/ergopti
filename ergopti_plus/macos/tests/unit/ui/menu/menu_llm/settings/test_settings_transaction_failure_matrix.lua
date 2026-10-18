--- tests/unit/ui/menu/menu_llm/settings/test_settings_transaction_failure_matrix.lua

--- ==============================================================================
--- MODULE: Transactional LLM Settings Regression
--- DESCRIPTION:
--- Proves that every LLM setting action restores state, native settings, runtime,
--- durable preferences, and rendered menu state when any boundary refuses.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.settings.settings_transaction_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.settings.settings_transaction_fixture")
local ENTRY_SPECS = Fixture.ENTRY_SPECS
local FAILURE_SPECS = Fixture.FAILURE_SPECS
local SIBLING_FAILURES = Fixture.SIBLING_FAILURES
local SIBLING_ROUTES = Fixture.SIBLING_ROUTES
local clone_value = Fixture.clone_value
local find_item = Fixture.find_item
local indentation_item = Fixture.indentation_item
local info_bar_corpus = Fixture.info_bar_corpus
local with_fixture = Fixture.with_fixture





-- ==============================================
-- ==============================================
-- ======= 1/ Failure compensation matrix =======
-- ==============================================
-- ==============================================

helpers.describe("HS-026 LLM settings transaction", function()
	for _, entry in ipairs(ENTRY_SPECS) do
		for _, failure in ipairs(FAILURE_SPECS) do
			if not failure.settings_only or entry.publishes_setting then
				helpers.it(string.format("HS-026 restores %s after %s %s", entry.name,
					failure.name, failure.mode), function()
					with_fixture({failures = {{
						name = failure.name,
						mode = failure.mode,
					}}}, function(fixture)
						local old_value = clone_value(fixture.state[entry.key])
						local call_ok, result = xpcall(function()
							return entry.invoke(fixture)
						end, debug.traceback)

						helpers.assert_true(call_ok,
							"the setting owner must contain boundary exceptions")
						helpers.assert_eq(result, false)
						helpers.assert_eq(fixture.state[entry.key], old_value)
						helpers.assert_eq(fixture.runtime[entry.key], old_value)
						helpers.assert_eq(fixture.persisted()[entry.key], old_value)
						helpers.assert_eq(fixture.rendered()[entry.key], old_value)
						if entry.publishes_setting then
							helpers.assert_eq(fixture.settings_store[entry.key], old_value)
						end
						helpers.assert_true(#fixture.errors >= 1,
							"a refused setting boundary must be file-logged")
					end)
				end)
			end
		end
	end

	for _, entry in ipairs(ENTRY_SPECS) do
		helpers.it("HS-026 commits " .. entry.name .. " exactly once", function()
			with_fixture({}, function(fixture)
				helpers.assert_eq(entry.invoke(fixture), true)
				helpers.assert_eq(fixture.state[entry.key], entry.candidate)
				helpers.assert_eq(fixture.runtime[entry.key], entry.candidate)
				helpers.assert_eq(fixture.persisted()[entry.key], entry.candidate)
				helpers.assert_eq(fixture.rendered()[entry.key], entry.candidate)
				helpers.assert_eq(fixture.calls.runtime, 1)
				helpers.assert_eq(fixture.calls.save, 1)
				helpers.assert_eq(fixture.calls.menu, 1)
				helpers.assert_eq(fixture.calls.settings,
					entry.publishes_setting and 1 or 0)
			end)
		end)
	end

	helpers.it("HS-026 retains refused compensation and settles it before retry", function()
		with_fixture({failures = {
			{name = "save", occurrence = 1, mode = "false"},
			{name = "runtime", occurrence = 2, mode = "false", mutate = false},
		}}, function(fixture)
			local entry = ENTRY_SPECS[1]
			helpers.assert_eq(entry.invoke(fixture), false)
			helpers.assert_eq(fixture.state[entry.key], 0.2)
			helpers.assert_eq(fixture.runtime[entry.key], entry.candidate,
				"a refused runtime rollback must remain observable as debt")
			helpers.assert_true(#fixture.errors >= 1,
				"unsettled compensation must be file-logged")

			helpers.assert_eq(entry.invoke(fixture), true)
			helpers.assert_eq(fixture.histories.runtime, {
				{key = entry.key, value = entry.candidate},
				{key = entry.key, value = 0.2},
				{key = entry.key, value = 0.2},
				{key = entry.key, value = entry.candidate},
			})
			helpers.assert_eq(fixture.runtime[entry.key], entry.candidate)
			helpers.assert_eq(fixture.persisted()[entry.key], entry.candidate)
		end)
	end)

	helpers.it("HS-026 reasserts old state after the persistence owner refuses rollback", function()
		with_fixture({failures = {
			{name = "menu", occurrence = 1, mode = "false"},
			{
				name = "save",
				occurrence = 2,
				mode = "false",
				restore_committed = {llm_temperature = 0.75},
				restore_settings = {llm_temperature = 0.75},
			},
		}}, function(fixture)
			local entry = ENTRY_SPECS[1]
			helpers.assert_eq(entry.invoke(fixture), false)
			helpers.assert_eq(fixture.state[entry.key], 0.2,
				"an outer persistence rollback must not republish its newer snapshot")
			helpers.assert_eq(fixture.runtime[entry.key], 0.2)
			helpers.assert_eq(fixture.settings_store[entry.key], 0.2)
			helpers.assert_eq(fixture.rendered()[entry.key], 0.2)
			helpers.assert_eq(fixture.histories.settings, {
				{key = entry.key, value = entry.candidate},
				{key = entry.key, value = 0.2},
			})

			helpers.assert_eq(entry.invoke(fixture), true,
				"the retained persistence rollback must settle before retry")
			helpers.assert_eq(fixture.state[entry.key], entry.candidate)
			helpers.assert_eq(fixture.histories.settings, {
				{key = entry.key, value = entry.candidate},
				{key = entry.key, value = 0.2},
				{key = entry.key, value = 0.2},
				{key = entry.key, value = entry.candidate},
			}, "native plist restoration must remain debt until persistence settles")
		end)
	end)

	helpers.it("HS-026 clears a formerly absent native setting during rollback", function()
		with_fixture({
			setting_absent = "llm_temperature",
			failures = {{name = "menu", occurrence = 1, mode = "false"}},
		}, function(fixture)
			helpers.assert_eq(ENTRY_SPECS[1].invoke(fixture), false)
			helpers.assert_nil(fixture.settings_store.llm_temperature)
			helpers.assert_eq(fixture.calls.settings_clear, 1)
		end)
	end)

	helpers.it("HS-026 snapshots runtime independently from state and native settings", function()
		with_fixture({
			runtime_overrides = {llm_temperature = 0.4},
			setting_overrides = {llm_temperature = 0.6},
			failures = {{name = "menu", occurrence = 1, mode = "false"}},
		}, function(fixture)
			local entry = ENTRY_SPECS[1]
			helpers.assert_eq(entry.invoke(fixture), false)
			helpers.assert_eq(fixture.state[entry.key], 0.2)
			helpers.assert_eq(fixture.runtime[entry.key], 0.4,
				"runtime rollback must use the engine getter, not the state snapshot")
			helpers.assert_eq(fixture.settings_store[entry.key], 0.6,
				"native rollback must retain its independent plist snapshot")
			helpers.assert_eq(fixture.persisted()[entry.key], 0.2)
			helpers.assert_eq(fixture.rendered()[entry.key], 0.2)
			helpers.assert_eq(fixture.calls.runtime_get, 1)
			helpers.assert_eq(fixture.histories.runtime, {
				{key = entry.key, value = entry.candidate},
				{key = entry.key, value = 0.4},
			})
		end)
	end)

	for _, mode in ipairs({"false", "throw"}) do
		helpers.it("HS-026 refuses a " .. mode .. " runtime snapshot before mutation", function()
			with_fixture({failures = {{name = "runtime_get", mode = mode}}}, function(fixture)
				local entry = ENTRY_SPECS[1]
				helpers.assert_eq(entry.invoke(fixture), false)
				helpers.assert_eq(fixture.state[entry.key], 0.2)
				helpers.assert_eq(fixture.runtime[entry.key], 0.2)
				helpers.assert_eq(fixture.settings_store[entry.key], 0.2)
				helpers.assert_eq(fixture.calls.runtime, 0)
				helpers.assert_eq(fixture.calls.save, 0)
				helpers.assert_eq(fixture.calls.settings, 0)
				helpers.assert_eq(fixture.calls.menu, 0)
				helpers.assert_true(#fixture.errors >= 1)
			end)
		end)
	end
end)





-- ==============================================
-- ==============================================
-- ======= 2/ Finite Numeric Boundary ===========
-- ==============================================
-- ==============================================

helpers.describe("HS-055 LLM settings reject non-finite numbers", function()
	for _, case in ipairs({
		{name = "NaN", value = 0 / 0},
		{name = "positive infinity", value = math.huge},
		{name = "negative infinity", value = -math.huge},
	}) do
		helpers.it("refuses " .. case.name .. " before every mutation boundary", function()
			with_fixture({}, function(fixture)
				local result = fixture.manager.apply_setting_transaction({
					key = "llm_temperature",
					value = case.value,
					runtime_fn = "set_llm_temperature",
					publish_setting = true,
				})
				helpers.assert_eq(result, false)
				helpers.assert_eq(fixture.state.llm_temperature, 0.2)
				helpers.assert_eq(fixture.runtime.llm_temperature, 0.2)
				helpers.assert_eq(fixture.settings_store.llm_temperature, 0.2)
				helpers.assert_eq(fixture.persisted().llm_temperature, 0.2)
				helpers.assert_eq(fixture.rendered().llm_temperature, 0.2)
				helpers.assert_eq(fixture.calls.runtime_get, 0)
				helpers.assert_eq(fixture.calls.runtime, 0)
				helpers.assert_eq(fixture.calls.save, 0)
				helpers.assert_eq(fixture.calls.settings, 0)
				helpers.assert_eq(fixture.calls.menu, 0)
				helpers.assert_true(#fixture.errors >= 1,
					"the finite-value refusal must be visible in the file log")
			end)
		end)
	end

	helpers.it("rejects prompt overflow through the real debounce entry path", function()
		with_fixture({}, function(fixture)
			fixture.set_prompt("1e999")
			helpers.assert_eq(fixture.manager.set_debounce(), false)
			helpers.assert_eq(fixture.state.llm_debounce, 0.5)
			helpers.assert_eq(fixture.runtime.llm_debounce, 0.5)
			helpers.assert_eq(fixture.settings_store.llm_debounce, 0.5)
			helpers.assert_eq(fixture.calls.runtime_get, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.settings, 0)
			helpers.assert_eq(fixture.calls.menu, 0)
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 3/ Every production entry path =======
-- ==============================================
-- ==============================================

local ROUTES = {
	{name = "set debounce", key = "llm_debounce", invoke = function(f)
		f.set_prompt("900"); return f.manager.set_debounce()
	end},
	{name = "reset debounce", key = "llm_debounce", invoke = function(f)
		return f.manager.reset_debounce()
	end},
	{name = "set maximum words", key = "llm_max_words", invoke = function(f)
		f.set_prompt("8"); return f.manager.set_max_words()
	end},
	{name = "reset maximum words", key = "llm_max_words", invoke = function(f)
		return f.manager.reset_max_words()
	end},
	{name = "set minimum words", key = "llm_min_words", invoke = function(f)
		f.set_prompt("5"); return f.manager.set_min_words()
	end},
	{name = "reset minimum words", key = "llm_min_words", invoke = function(f)
		return f.manager.reset_min_words()
	end},
	{name = "set temperature", key = "llm_temperature", invoke = function(f)
		f.set_prompt("0.75"); return f.manager.set_temperature()
	end},
	{name = "reset temperature", key = "llm_temperature", invoke = function(f)
		return f.manager.reset_temperature()
	end},
	{name = "set context length", key = "llm_context_length", invoke = function(f)
		f.set_prompt("800"); return f.manager.set_context_length()
	end},
	{name = "reset context length", key = "llm_context_length", invoke = function(f)
		return f.manager.reset_context_length()
	end},
	{name = "set indentation", key = "llm_pred_indent", invoke = function(f)
		return indentation_item(f.streaming_menu()).menu[10].fn()
	end},
	{name = "set navigation modifiers", key = "llm_nav_modifiers", invoke = function(f)
		return find_item(f.manager.build_nav_modifier_menu(), "⇧ Shift").fn()
	end},
	{name = "set validation modifiers", key = "llm_val_modifiers", invoke = function(f)
		return find_item(f.manager.build_val_modifier_menu(), "⌘ Cmd").fn()
	end},
	{name = "toggle instant word end", key = "llm_instant_on_word_end", invoke = function(f)
		return find_item(f.trigger_menu(), "menu.llm.instant_on_word_end").fn()
	end},
	{name = "toggle after hotstring", key = "llm_after_hotstring", invoke = function(f)
		return find_item(f.trigger_menu(), "menu.llm.after_hotstring").fn()
	end},
	{name = "toggle URL filter", key = "llm_url_bar_filter_enabled", invoke = function(f)
		return find_item(f.trigger_menu(), "menu.llm.disable_url_bars").fn()
	end},
	{name = "toggle secure-field filter", key = "llm_secure_field_filter_enabled", invoke = function(f)
		return find_item(f.trigger_menu(), "menu.llm.disable_password_fields").fn()
	end},
	{name = "change disabled applications", key = "llm_disabled_apps", invoke = function(f)
		f.trigger_menu()
		return f.app_change({{name = "New", appPath = "/New.app"}})
	end},
}



helpers.describe("HS-026 all LLM setting entry paths share the owner", function()
	for _, route in ipairs(ROUTES) do
		helpers.it("HS-026 routes " .. route.name .. " through rollback", function()
			with_fixture({failures = {{name = "runtime", mode = "false"}}}, function(fixture)
				local old_value = clone_value(fixture.state[route.key])
				local call_ok, result = xpcall(function()
					return route.invoke(fixture)
				end, debug.traceback)
				helpers.assert_true(call_ok)
				helpers.assert_eq(result, false)
				helpers.assert_eq(fixture.state[route.key], old_value)
				helpers.assert_eq(fixture.runtime[route.key], old_value)
				helpers.assert_eq(fixture.persisted()[route.key], old_value)
				helpers.assert_eq(fixture.rendered()[route.key], old_value)
			end)
		end)
	end
end)





-- =======================================================
-- =======================================================
-- ======= 3/ Missed sibling callback transactions =======
-- =======================================================
-- =======================================================

helpers.describe("HS-026 missed LLM setting callbacks share the owner", function()
	for _, route in ipairs(SIBLING_ROUTES) do
		for _, failure in ipairs(SIBLING_FAILURES) do
			helpers.it(string.format("HS-026 restores %s after %s %s", route.name,
				failure.name, failure.mode), function()
				with_fixture({failures = {{
					name = failure.name,
					mode = failure.mode,
				}}}, function(fixture)
					local old_value = clone_value(fixture.state[route.key])
					local call_ok, result = xpcall(function()
						return route.invoke(fixture)
					end, debug.traceback)

					helpers.assert_true(call_ok,
						"the real menu callback must contain boundary exceptions")
					helpers.assert_eq(result, false)
					helpers.assert_eq(fixture.state[route.key], old_value)
					helpers.assert_eq(fixture.runtime[route.key], old_value)
					helpers.assert_eq(fixture.persisted()[route.key], old_value)
					helpers.assert_eq(fixture.rendered()[route.key], old_value)
					helpers.assert_eq(fixture.calls.runtime, failure.runtime)
					helpers.assert_eq(fixture.calls.save, failure.save)
					helpers.assert_eq(fixture.calls.menu, failure.menu)
					helpers.assert_eq(fixture.calls.settings, 0)
					helpers.assert_true(#fixture.errors >= 1,
						"the rejected callback must leave a contextual error")
				end)
			end)
		end

		helpers.it("HS-026 commits " .. route.name .. " exactly once", function()
			with_fixture({}, function(fixture)
				helpers.assert_eq(route.invoke(fixture), true)
				helpers.assert_eq(fixture.state[route.key], route.candidate)
				helpers.assert_eq(fixture.runtime[route.key], route.candidate)
				helpers.assert_eq(fixture.persisted()[route.key], route.candidate)
				helpers.assert_eq(fixture.rendered()[route.key], route.candidate)
				helpers.assert_eq(fixture.calls.runtime, 1)
				helpers.assert_eq(fixture.calls.save, 1)
				helpers.assert_eq(fixture.calls.menu, 1)
				helpers.assert_eq(fixture.calls.settings, 0)
			end)
		end)
	end

	helpers.it("HS-026 fences sibling callbacks behind retained rollback debt", function()
		with_fixture({failures = {
			{name = "save", occurrence = 1, mode = "false"},
			{name = "runtime", occurrence = 2, mode = "false", mutate = false},
		}}, function(fixture)
			local info_route = SIBLING_ROUTES[1]
			local streaming_route = SIBLING_ROUTES[2]
			helpers.assert_eq(info_route.invoke(fixture), false)
			helpers.assert_eq(fixture.state.llm_show_info_bar, true)
			helpers.assert_eq(fixture.runtime.llm_show_info_bar, false,
				"a refused compensation must remain owned as recovery debt")

			helpers.assert_eq(streaming_route.invoke(fixture), true)
			helpers.assert_eq(fixture.histories.runtime, {
				{key = "llm_show_info_bar", value = false},
				{key = "llm_show_info_bar", value = true},
				{key = "llm_show_info_bar", value = true},
				{key = "llm_streaming", value = true},
			})
			helpers.assert_eq(fixture.runtime.llm_show_info_bar, true)
			helpers.assert_eq(fixture.runtime.llm_streaming, true)
			helpers.assert_eq(fixture.persisted().llm_streaming, true)
			helpers.assert_eq(fixture.calls.runtime, 4)
			helpers.assert_eq(fixture.calls.save, 3)
			helpers.assert_eq(fixture.calls.menu, 1)
			helpers.assert_eq(fixture.calls.settings, 0)
		end)
	end)

	helpers.it("HS-026 rebuilds navigation labels from canonical state without runtime writes", function()
		with_fixture({}, function(fixture)
			local callbacks = fixture.top_level_callbacks()
			fixture.state.llm_nav_modifiers = {"ctrl"}
			fixture.state.llm_val_modifiers = {"shift"}
			fixture.runtime.llm_nav_modifiers = {"cmd"}
			fixture.runtime.llm_val_modifiers = {"alt"}
			fixture.settings_store.llm_nav_modifiers = {"alt"}
			fixture.settings_store.llm_val_modifiers = {"cmd"}

			local submenu = callbacks.rebuild()
			local navigation = find_item(submenu, "menu.llm.nav_menu_title")
			helpers.assert_true(navigation ~= nil, "the real navigation row must rebuild")
			helpers.assert_true(find_item(navigation.menu,
				"menu.llm.nav_label : ⌃ menu.llm.arrows") ~= nil,
				"navigation title must display the canonical state value")
			helpers.assert_true(find_item(navigation.menu,
				"menu.llm.val_label : ⇧ menu.llm.digits") ~= nil,
				"validation title must display the canonical state value")
			helpers.assert_eq(fixture.calls.runtime, 0,
				"a render-only rebuild must not invoke either runtime setter")
			helpers.assert_eq(fixture.runtime.llm_nav_modifiers, {"cmd"})
			helpers.assert_eq(fixture.runtime.llm_val_modifiers, {"alt"})
		end)
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 8/ Shared Info Bar Control =======
-- ==========================================
-- ==========================================

--- Reads the independently captured toggle states and shared label identity.
--- @return table corpus

helpers.describe("LLM shared Info Bar control", function()
	helpers.it("replays both checked states through the actual acknowledged setting owner", function()
		local corpus = info_bar_corpus()
		helpers.assert_eq(#corpus.states, 2)
		for _, selected in ipairs(corpus.states) do
			with_fixture({info_bar_state = selected}, function(fixture)
				local menu = fixture.streaming_menu()
				local row = assert(find_item(menu, corpus.row.i18n))
				helpers.assert_eq(menu[1], row, "the canonical Info Bar declaration is first on every OS")
				helpers.assert_eq(menu[#menu], indentation_item(menu), "the canonical indentation declaration owns the trailing position")
				helpers.assert_eq(row.checked or false, selected)
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(fixture.state.llm_show_info_bar, not selected)
				helpers.assert_eq(fixture.persisted().llm_show_info_bar, not selected)
				helpers.assert_eq(fixture.runtime.llm_show_info_bar, not selected)
				helpers.assert_eq(fixture.calls.save, 1)
				helpers.assert_eq(fixture.calls.menu, 1)
			end)
		end
	end)

	helpers.it("moves the real check after indentation when its shared declaration moves last", function()
		with_fixture({info_last = true}, function(fixture)
			local menu = fixture.streaming_menu()
			helpers.assert_eq(menu[1].title, "menu.llm.show_streaming")
			helpers.assert_eq(menu[#menu].title, info_bar_corpus().row.i18n)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.runtime, 0)
		end)
	end)

	helpers.it("uses the shared label while a refused writer preserves every publication", function()
		local corpus = info_bar_corpus()
		with_fixture({info_label = corpus.alternate_i18n, failures = {{name = "save", mode = "false"}}}, function(fixture)
			local menu = fixture.streaming_menu()
			local row = assert(find_item(menu, corpus.alternate_i18n), "the real native check must read the changed declaration")
			helpers.assert_eq(find_item(menu, corpus.row.i18n), nil, "no stale native label remains")
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.state.llm_show_info_bar, true)
			helpers.assert_eq(fixture.runtime.llm_show_info_bar, true)
			helpers.assert_eq(fixture.persisted().llm_show_info_bar, true)
			helpers.assert_eq(fixture.rendered().llm_show_info_bar, true)
			helpers.assert_eq(fixture.calls.menu, 0)
		end)
	end)
end)
