--- tests/unit/modules/keymap/registry/test_registry_mutation_transactions_dynamic_category.lua

--- ==============================================================================
--- MODULE: Registry Mutation Transactions
--- DESCRIPTION:
--- Proves that public group/section mutators return an exact boolean commitment
--- and restore both runtime mappings and persistent section settings when a
--- loader or post-load hook fails after mutation has begun.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.keymap.registry.registry_mutation_transactions_fixture"] = nil
local Fixture = require("tests.support.modules.keymap.registry.registry_mutation_transactions_fixture")
local assert_dynamic_personal_scope = Fixture.assert_dynamic_personal_scope
local dynamic_personal_scope_fixture = Fixture.dynamic_personal_scope_fixture
local with_menu_diagnostics = Fixture.with_menu_diagnostics





--- Builds the real Dynamic registry, module façade and canonical conditional save.
--- @param enabled boolean Requested target, opposite of the initial live posture.
--- @param outcome string Save acknowledgement or actual publication refusal.
--- @param absent boolean|nil Preserve a genuinely absent menu-state module choice.
--- @return table fixture


--- Verifies complete selected scope and unrelated native authority outside callbacks.
--- @param f table Fixture.
--- @param desired boolean Expected selected runtime posture.


helpers.describe("Dynamic category admits its real personal-info module owner", function()
	for _, enabled in ipairs({ true, false }) do
		for _, outcome in ipairs({ "true", "false", "nil", "throw" }) do
			helpers.it("dynamic personal scope " .. tostring(enabled) .. "/" .. outcome, function()
				local f = dynamic_personal_scope_fixture(enabled, outcome)
				local accepted = f.action()
				local expected = outcome == "true"
				helpers.assert_eq(accepted, expected)
				helpers.assert_eq(f.observations, { { enabled, enabled, enabled } },
					"canonical save observes the complete module/menu/registry candidate")
				local wanted = not enabled
				if expected then wanted = enabled end
				assert_dynamic_personal_scope(f, wanted)
				helpers.assert_eq(f.ctx.state.personal_info, wanted)
				local starts, updates, saves = f.counts()
				helpers.assert_eq({ starts, updates, saves }, { 0, expected and 1 or 0, 1 })
				if expected then
					helpers.assert_eq(f.preferences.load("config").personal_info, enabled)
					local decoded = assert(require("toml_codec").decode(f.files.config))
					helpers.assert_eq(decoded.hotstrings.modules.future_module, { retained = 17 })
				else
					helpers.assert_eq(f.files.config, f.original, "refusal preserves exact canonical source bytes")
				end
			end)
		end
		for _, outcome in ipairs({ "false", "nil", "throw" }) do
			helpers.it("dynamic personal scope restores absent state after " .. outcome .. "/" .. tostring(enabled), function()
				local f = dynamic_personal_scope_fixture(enabled, outcome, true)
				helpers.assert_eq(f.action(), false)
				helpers.assert_nil(f.ctx.state.personal_info, "absence is restored rather than converted into a boolean")
				assert_dynamic_personal_scope(f, not enabled)
				helpers.assert_eq(f.files.config, f.original)
			end)
		end
	end

	helpers.it("dynamic personal scope refuses a stale source then retries its acknowledged owner", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		f.files.config = f.original .. "\n[future]\nexternal = 23\n"
		local external = f.files.config
		helpers.assert_eq(f.action(), false)
		assert_dynamic_personal_scope(f, false)
		helpers.assert_eq(f.files.config, external, "a stale save never overwrites the external writer")
		helpers.assert_eq(f.action(), true)
		assert_dynamic_personal_scope(f, true)
		helpers.assert_eq(assert(require("toml_codec").decode(f.files.config)).future.external, 23)
	end)
end)


helpers.describe("Dynamic module acknowledgement and selected-scope isolation", function()
	for _, enabled in ipairs({ true, false }) do
		for _, outcome in ipairs({ "false", "nil", "throw" }) do
			helpers.it("dynamic personal module inverse after " .. outcome .. "/" .. tostring(enabled), function()
				local f = dynamic_personal_scope_fixture(enabled, "true")
				local setter, calls = f.personal.set_enabled, 0
				f.personal.set_enabled = function(value)
					calls = calls + 1
					local acknowledged = setter(value)
					if calls > 1 then return acknowledged end
					if outcome == "throw" then error("owned module acknowledgement refusal") end
					if outcome == "nil" then return nil end
					return false
				end
				helpers.assert_eq(f.action(), false)
				assert_dynamic_personal_scope(f, not enabled)
				helpers.assert_eq(f.ctx.state.personal_info, not enabled)
				helpers.assert_eq(f.module_calls, { enabled, not enabled },
					"the partial native choice settles through its exact inverse")
				helpers.assert_eq(f.files.config, f.original)
				helpers.assert_eq({ f.counts() }, { 0, 0, 0 }, "refused module ownership reaches no canonical write")
			end)
		end
		helpers.it("dynamic personal conditional writer refusal then retry " .. tostring(enabled), function()
			local f = dynamic_personal_scope_fixture(enabled, "true")
			f.files.refuse = true
			helpers.assert_eq(f.action(), false)
			assert_dynamic_personal_scope(f, not enabled)
			helpers.assert_eq(f.files.config, f.original)
			f.files.refuse = false
			helpers.assert_eq(f.action(), true)
			assert_dynamic_personal_scope(f, enabled)
			helpers.assert_eq(f.preferences.load("config").personal_info, enabled)
		end)
	end

	helpers.it("dynamic personal scope refuses a missing actual module port before publication", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		f.ctx.personal_info = nil
		helpers.assert_eq(f.action(), false)
		assert_dynamic_personal_scope(f, false)
		helpers.assert_eq(f.files.config, f.original)
		helpers.assert_eq({ f.counts() }, { 0, 0, 0 })
	end)

	helpers.it("dynamic personal scope preserves unsupported declared future placeholders", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		local getter = f.registry.get_sections
		f.registry.get_sections = function(group)
			local rows = getter(group)
			if group ~= "dynamichotstrings" then return rows end
			local copy = {}
			for _, row in ipairs(rows) do copy[#copy + 1] = row end
			copy[#copy + 1] = { name = "future_section", is_module_placeholder = true }
			return copy
		end
		f.ctx.module_sections.dynamichotstrings.future_section = { mod_id = "future_owner" }
		f.ctx.state.future_owner = true
		local foreign_calls = 0
		f.ctx.future_owner = { is_enabled = function() return true end,
			set_enabled = function() foreign_calls = foreign_calls + 1; return true end }
		helpers.assert_eq(f.action(), false)
		assert_dynamic_personal_scope(f, false)
		helpers.assert_eq(f.ctx.state.future_owner, true)
		helpers.assert_eq(foreign_calls, 0, "unknown native module authority is never adopted")
		helpers.assert_eq(f.module_calls, {})
		helpers.assert_eq(f.files.config, f.original)
		helpers.assert_eq({ f.counts() }, { 0, 0, 0 })
	end)

	helpers.it("an unrelated category never acquires the personal module or changes its choice", function()
		local f = dynamic_personal_scope_fixture(false, "true")
		local Custom = require("ui.menu.menu_hotstrings_custom")
		helpers.assert_eq(Custom.category_scope_fn(f.ctx, { "spare" }, false)(), true)
		helpers.assert_eq(f.module_calls, {})
		helpers.assert_eq(f.personal.is_enabled(), true)
		helpers.assert_eq(f.ctx.state.personal_info, true)
		helpers.assert_eq(f.registry.is_group_enabled("dynamichotstrings"), true)
		for _, name in ipairs(f.names) do
			helpers.assert_eq(hs.settings.get("ergopti.hotstrings_section_dynamichotstrings_" .. name), true)
		end
		helpers.assert_eq(f.registry.is_group_enabled("spare"), false)
		helpers.assert_eq(f.ctx.state.keymap, false)
		helpers.assert_eq(f.ctx.paused, true)
		helpers.assert_eq(f.preferences.load("config").personal_info, true)
	end)
end)


helpers.describe("Dynamic module checkbox and untouched-runtime authority", function()
	helpers.it("the actual shared Dynamic checkbox includes its personal-info placeholder", function()
		local f = dynamic_personal_scope_fixture(false, "true")
		local Custom = require("ui.menu.menu_hotstrings_custom")
		f.personal.set_enabled(false)
		f.ctx.state.personal_info = false
		f.ctx.paused = false
		local row = Custom.all_sections_row(f.ctx, { "dynamichotstrings" }, function(value)
			return Custom.category_scope_fn(f.ctx, { "dynamichotstrings" }, value)
		end)
		helpers.assert_eq(row.checked, false, "six enabled registry sections cannot hide a disabled external module")
		helpers.assert_eq(row.action(), true)
		helpers.assert_eq(f.personal.is_enabled(), true)
		helpers.assert_eq(Custom.all_sections_on(f.ctx, { "dynamichotstrings" }), true)
		helpers.assert_eq(f.preferences.load("config").personal_info, true)
		helpers.assert_eq({ f.counts() }, { 0, 1, 1 })
	end)

	helpers.it("a refused real registry selection never acquires the untouched module runtime", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		local Custom = require("ui.menu.menu_hotstrings_custom")
		local action = Custom.category_scope_fn(f.ctx, { "dynamichotstrings", "missing" }, true)
		helpers.assert_eq(action(), false)
		helpers.assert_eq(f.module_calls, {}, "a refused planner never resets the native module's pending state")
		assert_dynamic_personal_scope(f, false)
		helpers.assert_nil(f.ctx.state.hotstrings.missing)
		helpers.assert_eq(f.files.config, f.original)
		helpers.assert_eq({ f.counts() }, { 0, 0, 0 })
	end)

	helpers.it("an already selected module keeps its runtime while its category is acknowledged", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		f.personal.set_enabled(true)
		f.ctx.state.personal_info = true
		for key in pairs(f.module_calls) do f.module_calls[key] = nil end
		helpers.assert_eq(f.action(), true)
		helpers.assert_eq(f.module_calls, {}, "an unchanged external interceptor is never restarted or reset")
		assert_dynamic_personal_scope(f, true)
		helpers.assert_eq(f.preferences.load("config").personal_info, true)
		helpers.assert_eq({ f.counts() }, { 0, 1, 1 })
	end)
end)


helpers.describe("Dynamic module acknowledged publication survives UI refresh refusal", function()
	helpers.it("a failed menu refresh cannot undo the acknowledged personal-info file and runtime choice", function()
		local f = dynamic_personal_scope_fixture(true, "true")
		f.ctx.updateMenu = function() error("owned refresh refusal after canonical acknowledgement") end
		helpers.assert_eq(f.action(), false)
		assert_dynamic_personal_scope(f, true)
		helpers.assert_eq(f.ctx.state.personal_info, true)
		helpers.assert_eq(f.preferences.load("config").personal_info, true)
		helpers.assert_eq(f.module_calls, { true }, "an acknowledged module is never compensated because repaint failed")
		helpers.assert_eq({ f.counts() }, { 0, 0, 1 })
	end)
end)

helpers.describe("registry-only personal menu diagnostics isolation", function()
	helpers.it("restores absent, false and captured boot catalogue caches after success and refusal", function()
		helpers.with_fresh_modules({ "infra.personal_hotstrings" }, function()
			local catalogue = { unavailable_directories = function() return { { label = "foreign" } } end }
			for _, previous in ipairs({ { value = nil }, { value = false }, { value = catalogue } }) do
				for _, refuse in ipairs({ false, true }) do
					package.loaded["infra.personal_hotstrings"] = previous.value
					local ok, result = pcall(with_menu_diagnostics, function()
						local port = require("infra.personal_hotstrings")
						helpers.assert_true(port ~= previous.value)
						helpers.assert_eq(port.unavailable_directories(), {})
						if refuse then error("injected menu fixture refusal", 0) end
						return "completed"
					end)
					helpers.assert_eq(ok, not refuse)
					if not refuse then helpers.assert_eq(result, "completed") end
					helpers.assert_true(package.loaded["infra.personal_hotstrings"] == previous.value,
						"the exact earlier boot catalogue identity must survive the scoped fixture")
				end
			end
		end)
	end)
end)
