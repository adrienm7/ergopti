--- tests/unit/ui/menu/menu_llm/settings/test_settings_transaction_real_sources.lua

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
local info_bar_corpus = Fixture.info_bar_corpus
local privacy_corpus = Fixture.privacy_corpus
local with_fixture = Fixture.with_fixture





helpers.describe("macOS real-source indentation compensation", function()
	for _, race in ipairs({"before menu construction", "before forward acknowledgement", "after forward acknowledgement", "between own acknowledgement and receipt admission"}) do
	helpers.it("preserves a real foreign master winner " .. race .. " through compensation and a fresh second click for indentation (shared-indentation)", function()
		local path = require("infra.config_paths").get("ConfigTomlPath")
		local initial = '[llm]\nenabled = true\n[llm.models]\nselected = "ollama"\n[llm.display]\npred_indent = 1\nstreaming = false\nstreaming_multi = true\n[llm.profiles]\nnum_predictions = 3\n[private]\nfuture = 42\n'
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
				local parent = indentation_item(fixture.streaming_menu())
				local row = parent.menu[1]
				if race == "before menu construction" then
					if row.fn then helpers.assert_eq(row.fn(), false) end
					helpers.assert_eq(disk, external, "stale compensation cannot overwrite the foreign temperature")
					helpers.assert_eq(parent.disabled, true, "an already foreign full-document image is not action authority")
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
				helpers.assert_eq(parent.disabled == true, false)
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
					helpers.assert_eq((acknowledged.llm.display or {}).pred_indent, -7, "only the requested signed offset belongs to the acknowledged source")
					helpers.assert_eq(preferences.source_snapshot(path), receipt.source)
				end
				helpers.assert_eq(attempts, 1, "compensation cannot borrow a foreign source")
				helpers.assert_eq(fixture.manager.scope_idle(), false, "refused compensation remains owned debt")
				helpers.assert_eq(fixture.state.llm_enabled, true)
				helpers.assert_eq(fixture.runtime.llm_enabled, true)
				local before = attempts
				local fresh = indentation_item(fixture.streaming_menu())
				helpers.assert_eq(fresh.disabled, true)
				if fresh.menu[1].fn then helpers.assert_eq(fresh.menu[1].fn(), false) end
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.apply_setting_transaction({
					key = "llm_pred_indent", value = 1, runtime_fn = "set_llm_pred_indent", publish_setting = true,
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
end)

helpers.describe("macOS retained Info Bar source admission", function()
	for _, condition in ipairs({"paused", "master", "runtime value", "retired owner"}) do
		helpers.it("refuses a retained actual checkbox after " .. condition .. " (shared-info-bar)", function()
			local options = {prediction_count = 1, progressive_state = false}
			with_fixture(options, function(fixture)
				local row = assert(find_item(fixture.streaming_menu(), info_bar_corpus().row.i18n))
				helpers.assert_eq(row.disabled == true, false)
				if condition == "paused" then options.paused = true end
				if condition == "master" then fixture.state.llm_enabled, fixture.runtime.llm_enabled = false, false end
				if condition == "runtime value" then fixture.runtime.llm_show_info_bar = false end
				if condition == "retired owner" then fixture.retire_display() end
				local before = fixture.calls.save
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(fixture.calls.save, before)
				helpers.assert_eq(fixture.state.llm_show_info_bar, true)
				helpers.assert_eq(fixture.persisted().llm_show_info_bar, true)
				helpers.assert_eq(fixture.calls.menu, 0)
			end)
		end)
	end

	helpers.it("retires an acknowledged checkbox without restricting single predictions (shared-info-bar)", function()
		with_fixture({prediction_count = 1, progressive_state = false}, function(fixture)
			local row = assert(find_item(fixture.streaming_menu(), info_bar_corpus().row.i18n))
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.calls.save, 1)
			helpers.assert_eq(fixture.state.llm_show_info_bar, false)
			helpers.assert_eq(fixture.runtime.llm_show_info_bar, false)
			helpers.assert_eq(fixture.persisted().llm_show_info_bar, false)
		end)
	end)
end)

helpers.describe("macOS real-source Info Bar compensation", function()
	for _, race in ipairs({"before menu construction", "before forward acknowledgement", "after forward acknowledgement", "between own acknowledgement and receipt admission"}) do
	helpers.it("preserves a real foreign master winner " .. race .. " through compensation and a fresh second click for Info Bar (shared-info-bar)", function()
		local path = require("infra.config_paths").get("ConfigTomlPath")
		local initial = '[llm]\nenabled = true\n[llm.models]\nselected = "ollama"\n[llm.display]\npred_indent = 1\nshow_info_bar = true\nstreaming = false\nstreaming_multi = true\n[llm.profiles]\nnum_predictions = 3\n[private]\nfuture = 42\n'
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
				local parent = assert(find_item(fixture.streaming_menu(), info_bar_corpus().row.i18n))
				local row = parent
				if race == "before menu construction" then
					if row.fn then helpers.assert_eq(row.fn(), false) end
					helpers.assert_eq(disk, external, "stale compensation cannot overwrite the foreign temperature")
					helpers.assert_eq(parent.disabled, true, "an already foreign full-document image is not action authority")
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
				helpers.assert_eq(parent.disabled == true, false)
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
					helpers.assert_eq((acknowledged.llm.display or {}).show_info_bar, false, "only the requested checkbox value belongs to the acknowledged source")
					helpers.assert_eq(preferences.source_snapshot(path), receipt.source)
				end
				helpers.assert_eq(attempts, 1, "compensation cannot borrow a foreign source")
				helpers.assert_eq(fixture.manager.scope_idle(), false, "refused compensation remains owned debt")
				helpers.assert_eq(fixture.state.llm_enabled, true)
				helpers.assert_eq(fixture.runtime.llm_enabled, true)
				local before = attempts
				local fresh = assert(find_item(fixture.streaming_menu(), info_bar_corpus().row.i18n))
				helpers.assert_eq(fresh.disabled, true)
				if fresh.fn then helpers.assert_eq(fresh.fn(), false) end
				helpers.assert_eq(attempts, before)
				helpers.assert_eq(fixture.manager.apply_setting_transaction({
					key = "llm_show_info_bar", value = true, runtime_fn = "set_llm_show_info_bar", publish_setting = false,
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
end)



--- Reads independent privacy rows and complete boolean states.
--- @return table corpus

helpers.describe("Shared privacy trigger checks", function()
	helpers.it("publishes every independent bool pair through existing owners and refuses repeat held clicks (shared-privacy-triggers)", function()
		local corpus = privacy_corpus()
		helpers.assert_eq(#corpus.states, 4)
		for _, states in ipairs(corpus.states) do
			for _, count in ipairs(corpus.prediction_counts) do
				for index, expected in ipairs(corpus.rows) do
					with_fixture({privacy_states = states, prediction_count = count}, function(fixture)
						local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
						helpers.assert_eq(row.checked or false, states[index])
						helpers.assert_eq(row.disabled or false, false)
						helpers.assert_eq(row.fn(), true)
						helpers.assert_eq(fixture.state[expected.hs], not states[index])
						helpers.assert_eq(fixture.runtime[expected.hs], not states[index])
						helpers.assert_eq(fixture.persisted()[expected.hs], not states[index])
						local neighbor = corpus.rows[index == 1 and 2 or 1]
						helpers.assert_eq(fixture.persisted()[neighbor.hs], states[index == 1 and 2 or 1])
						helpers.assert_eq(fixture.calls.save, 1)
						helpers.assert_eq(row.fn(), false)
						helpers.assert_eq(fixture.calls.save, 1)
					end)
				end
			end
		end
	end)

	for _, condition in ipairs({"paused", "master withdrawn", "runtime disagreement", "retired runtime"}) do
		helpers.it("refuses a held privacy callback after " .. condition .. " (shared-privacy-triggers)", function()
			for _, expected in ipairs(privacy_corpus().rows) do
				local options = {}
				with_fixture(options, function(fixture)
					local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
					if condition == "paused" then options.paused = true end
					if condition == "master withdrawn" then
						fixture.state.llm_enabled, fixture.runtime.llm_enabled = false, false
					end
					if condition == "runtime disagreement" then fixture.runtime[expected.hs] = not fixture.runtime[expected.hs] end
					if condition == "retired runtime" then fixture.runtime[expected.hs] = nil end
					helpers.assert_eq(row.fn(), false)
					helpers.assert_eq(fixture.calls.save, 0)
					helpers.assert_eq(fixture.calls.runtime, 0)
				end)
			end
		end)
	end
end)


helpers.describe("Privacy native publication source ownership", function()
	for _, race in ipairs({"before menu construction", "after menu construction",
		"before forward acknowledgement", "after forward acknowledgement", "between own acknowledgement and receipt admission"}) do
		helpers.it("retains foreign bytes and acknowledged source debt " .. race .. " (shared-privacy-triggers)", function()
			for _, expected in ipairs(privacy_corpus().rows) do
				local path = require("infra.config_paths").get("ConfigTomlPath")
				local initial = '[llm]\nenabled = true\n[llm.models]\nselected = "ollama"\n[llm.trigger]\nurl_bar_filter_enabled = false\nsecure_filter_enabled = false\n[private]\nfuture = 42\n'
				local external = initial:gsub('enabled = true', 'enabled = false'):gsub('future = 42', 'future = 73')
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
						failures = {{name = "menu", mode = "false"}},
						after_save = function()
							if race == "between own acknowledgement and receipt admission" then disk = external end
						end,
						before_menu = function(occurrence)
							if occurrence == 1 and race == "after forward acknowledgement" then disk = external end
						end,
					}, function(fixture)
						if race == "before menu construction" then disk = external end
						local row = assert(find_item(fixture.trigger_menu(), expected.i18n))
						if race == "after menu construction" then disk = external end
						if row.fn then helpers.assert_eq(row.fn(), false) end
						helpers.assert_eq(disk, external)
						helpers.assert_eq(fixture.state[expected.hs], false)
						helpers.assert_eq(fixture.runtime[expected.hs], false)
						helpers.assert_eq(unconditional, 0)
						helpers.assert_eq(wrong_path, false)
						if race == "before menu construction" or race == "after menu construction" then
							helpers.assert_eq(attempts, 0)
							helpers.assert_eq(fixture.calls.runtime, 0)
							helpers.assert_eq(preferences.publication_receipt(path).id, 0)
							return
						end
						helpers.assert_eq(attempts, 1)
						helpers.assert_eq(fixture.manager.scope_idle(), false)
						local receipt = preferences.publication_receipt(path)
						helpers.assert_eq(receipt.id, race == "before forward acknowledgement" and 0 or 1)
						if receipt.id == 1 then
							helpers.assert_eq(preferences.source_matches(receipt.source, {status = "ok", content = external}), false)
							local own = require("infra.toml.codec").decode(receipt.source.content)
							helpers.assert_eq(own.llm.enabled, true)
							local owned_value = own.llm.trigger[expected.linux]
							if expected.neutral == true then
								helpers.assert_eq(owned_value, nil, "the acknowledged default is stored as owned absence")
								owned_value = expected.neutral
							end
							helpers.assert_eq(owned_value, true)
						end
						local fresh = assert(find_item(fixture.trigger_menu(), expected.i18n))
						helpers.assert_eq(fresh.disabled, true)
						if fresh.fn then helpers.assert_eq(fresh.fn(), false) end
						helpers.assert_eq(fixture.manager.apply_setting_transaction({key = expected.hs,
							value = true, runtime_fn = "set_" .. expected.hs, publish_setting = false}), false)
						helpers.assert_eq(attempts, 1)
						helpers.assert_eq(disk, external)
					end)
				end, debug.traceback)
				package.loaded["adapters.file_system"], package.loaded["infra.preferences"] = previous_fs, previous_preferences
				if not ok then error(err, 0) end
			end
		end)
	end
end)


helpers.describe("Shared privacy intent policy", function()
	helpers.it("replays independent strict snapshot types and exact identities (shared-privacy-triggers)", function()
		local corpus, policy = privacy_corpus(), require("llm.trigger_policy")
		for _, vector in ipairs(corpus.vectors) do
			local expected = clone_value(corpus.snapshot)
			expected.owner = {}
			local current = clone_value(corpus.snapshot)
			current.owner = expected.owner
			for key, value in pairs(vector.current or {}) do current[key] = value end
			for _, key in ipairs(vector.missing or {}) do current[key] = nil end
			if vector.new_owner then current.owner = {} end
			local actual = policy.intent(expected, current)
			helpers.assert_eq(actual.admitted, vector.admitted, vector.name)
			helpers.assert_eq(actual.value, vector.value, vector.name)
			if not policy.ready(current) then helpers.assert_eq(policy.intent(current, expected).admitted, false) end
		end
	end)
end)


helpers.describe("LLM navigation: shared native child declarations", function()
	helpers.it("(llm-nav-shared) consumes actual reordered labels and missing declarations", function()
		with_fixture({ navigation_reverse = true, navigation_label = "button.cancel" }, function(fixture)
			local parent = find_item(fixture.top_level_callbacks().rebuild(), "menu.llm.nav_menu_title")
			helpers.assert_eq(#parent.menu, 2)
			helpers.assert_true(parent.menu[1].title:find("button.cancel", 1, true) == 1)
			helpers.assert_true(parent.menu[2].title:find("menu.llm.nav_label", 1, true) == 1)
			helpers.assert_eq(type(parent.menu[1].menu), "table", "the actual validation picker remains a whole subtree")
			helpers.assert_eq(type(parent.menu[2].menu), "table", "the actual navigation picker remains a whole subtree")
			helpers.assert_eq(fixture.calls.runtime, 0)
			helpers.assert_eq(fixture.calls.save, 0)
		end)
		with_fixture({ navigation_absent = true }, function(fixture)
			local parent = find_item(fixture.top_level_callbacks().rebuild(), "menu.llm.nav_menu_title")
			helpers.assert_eq(#parent.menu, 0, "absent shared children never acquire native fallback rows")
			helpers.assert_eq(fixture.calls.save, 0)
		end)
		with_fixture({ navigation_invalid = true }, function(fixture)
			local parent = find_item(fixture.top_level_callbacks().rebuild(), "menu.llm.nav_menu_title")
			helpers.assert_eq(#parent.menu, 1, "a malformed label is refused before native rendering")
			helpers.assert_true(parent.menu[1].title:find("menu.llm.val_label", 1, true) == 1)
		end)
	end)

	helpers.it("(llm-nav-shared) preserves all twenty-one actual captions and native ranges", function()
		local Json = require("json")
		local root = helpers.driver_root() .. "../_shared/"
		local file = assert(io.open(root .. "data/locale_order.json", "r"))
		local locales = assert(Json.decode(file:read("*a"))).order; file:close()
		helpers.assert_eq(#locales, 21)
		local manifest_file = assert(io.open(helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json", "r"))
		local definitions = assert(Json.decode(manifest_file:read("*a"))).llm_navigation_rows; manifest_file:close()
		local corpus_file = assert(io.open(helpers.driver_root() .. "../_shared/tests/corpus/menus/llm_navigation_rows.json", "r"))
		local expected = assert(Json.decode(corpus_file:read("*a"))).rows; corpus_file:close()
		helpers.assert_eq(#definitions, 2, "both actual declared modifier providers must be present")
		helpers.assert_eq(#expected, 2, "the independent navigation corpus must be nonempty and complete")
		for index, definition in ipairs(definitions) do
			helpers.assert_eq({ definition.id, definition.type, definition.i18n },
				{ expected[index].id, expected[index].type, expected[index].i18n })
		end
		for _, locale in ipairs(locales) do
			local input = assert(io.open(root .. "data/locales/" .. locale .. ".json", "r"))
			local catalogue = assert(Json.decode(input:read("*a"))); input:close()
			local matched_paths = {}
			local function translated(key)
				local direct = catalogue[key]
				local value = catalogue
				local matched = 0
				for segment in key:gmatch("[^.]+") do
					matched = matched + 1
					value = type(value) == "table" and value[segment] or nil
				end
				matched_paths[#matched_paths + 1] = matched
				if direct ~= nil then return direct end
				return value or key
			end
			with_fixture({ translate = translated, navigation_only = true }, function(fixture)
				for _, count in ipairs({ 1, 2, 10 }) do
					fixture.state.llm_num_predictions = count
					fixture.state.llm_nav_modifiers, fixture.state.llm_val_modifiers = {}, {}
					local parent = find_item(fixture.top_level_callbacks().rebuild(), translated("menu.llm.nav_menu_title"))
					helpers.assert_eq(#parent.menu, 2)
					helpers.assert_true(parent.menu[1].title:find(translated("menu.llm.nav_label"), 1, true) == 1)
					helpers.assert_true(parent.menu[2].title:find(string.format(translated("menu.llm.val_label"), count == 10 and "1-0" or "1-" .. count), 1, true) == 1)
					helpers.assert_eq(parent.menu[1].disabled == true, count < 2)
					helpers.assert_eq(parent.menu[2].disabled == true, count < 2)
					helpers.assert_eq(type(parent.menu[1].menu[1].fn), "function", "the real modifier owner stays callable")
					helpers.assert_eq(fixture.calls.save, 0)
				end
			end)
			helpers.assert_true(#matched_paths > 0, "real locale lookups must execute")
			for _, matched in ipairs(matched_paths) do
				helpers.assert_true(matched > 0, "every actual locale lookup matches a nonempty key path")
			end
		end
	end)
end)


helpers.describe("LLM fixed parents: actual shared group topology", function()
	local parents = {
		{ id = "llm_trigger", key = "menu.llm.trigger_menu_title" },
		{ id = "llm_display", key = "menu.llm.display_menu_title" },
		{ id = "llm_navigation", key = "menu.llm.nav_menu_title" },
	}
	for _, parent in ipairs(parents) do
		helpers.it("shared group owns the real " .. parent.id .. " caption and child hierarchy", function()
			with_fixture({parent_only = true, parent_id = parent.id, parent_label = "button.cancel"}, function(fixture)
				local rows = fixture.top_level_callbacks().rebuild()
				local row = assert(find_item(rows, "button.cancel"), "current group caption must reach the actual parent")
				helpers.assert_nil(find_item(rows, parent.key), "the retired literal does not construct a second parent")
				helpers.assert_true(type(row.menu) == "table" and #row.menu > 0)
				helpers.assert_nil(row.fn, "a group parent has no competing click action")
				helpers.assert_eq(fixture.calls.save, 0)
				helpers.assert_eq(fixture.calls.runtime, 0)
				helpers.assert_eq(fixture.calls.settings, 0)
			end)
		end)
		helpers.it("withdrawn or wrong-type " .. parent.id .. " declaration cannot publish a fallback parent", function()
			for _, variant in ipairs({{parent_absent = true}, {parent_type = "dynamic"}}) do
				variant.parent_only, variant.parent_id = true, parent.id
				with_fixture(variant, function(fixture)
					local rows = fixture.top_level_callbacks().rebuild()
					helpers.assert_nil(find_item(rows, parent.key))
					helpers.assert_true(find_item(rows, "menu.llm.generation_menu_title") ~= nil, "the genuine unrelated generation owner remains present")
					helpers.assert_eq(fixture.calls.save, 0)
					helpers.assert_eq(fixture.calls.runtime, 0)
				end)
			end
		end)
	end
	helpers.it("the canonical group position owns the final parent and preserves all child callbacks", function()
		with_fixture({parent_only = true, parent_id = "llm_navigation", parent_first = true}, function(fixture)
			local rows = fixture.top_level_callbacks().rebuild()
			helpers.assert_eq(rows[1].title, "menu.llm.nav_menu_title")
			helpers.assert_eq(#rows[1].menu, 2)
			helpers.assert_true(type(rows[1].menu[1].menu[2].fn) == "function")
			helpers.assert_true(type(rows[1].menu[2].menu[2].fn) == "function")
			helpers.assert_eq(fixture.calls.runtime, 0, "drawing never synchronizes runtime")
		end)
	end)
	for _, condition in ipairs({{enabled = false}, {paused = true}}) do
		helpers.it("retains all three native parent gates while " .. (condition.paused and "paused" or "off"), function()
			condition.parent_only = true
			with_fixture(condition, function(fixture)
				local rows = fixture.top_level_callbacks().rebuild()
				for _, parent in ipairs(parents) do
					local row = assert(find_item(rows, parent.key))
					helpers.assert_eq(row.disabled, true)
					helpers.assert_true(type(row.menu) == "table", "gating retains the genuine child tree")
				end
			end)
		end)
	end
end)

helpers.describe("LLM fixed parents: independent original full physical hierarchy", function()
	helpers.it("retains every original native child, flag and callback through the real outer renderer", function()
		local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/llm_parent_groups.json"), "rb"))
		local corpus = assert(require("json").decode(file:read("*a"))); assert(file:close())
		with_fixture({parent_only = true}, function(fixture)
			local rows = fixture.top_level_callbacks().rebuild()
			local parents = {}
			for _, expected in ipairs(corpus.parents) do
				parents[#parents + 1] = assert(find_item(rows, expected.i18n))
			end
			helpers.assert_eq(#parents, 3, "the independent complete parent set is nonempty")
			helpers.assert_eq(require("test.menu_native_child_rows").hierarchy(parents), corpus.macos)
			helpers.assert_eq(fixture.calls.runtime, 0)
			helpers.assert_eq(fixture.calls.save, 0)
			helpers.assert_eq(fixture.calls.settings, 0)
		end)
	end)
end)

helpers.describe("LLM fixed parents: complete actual native child admission", function()
	for _, shape in ipairs({"named", "sparse", "cycle"}) do
		helpers.it("refuses the entire real Trigger child after " .. shape .. " corruption before parent publication", function()
			with_fixture({parent_only = true, corrupt_trigger_child = shape}, function(fixture)
				local rows = fixture.top_level_callbacks().rebuild()
				helpers.assert_nil(find_item(rows, "menu.llm.trigger_menu_title"))
				helpers.assert_true(find_item(rows, "menu.llm.display_menu_title") ~= nil)
				helpers.assert_true(find_item(rows, "menu.llm.nav_menu_title") ~= nil)
				helpers.assert_eq(fixture.calls.runtime, 0)
				helpers.assert_eq(fixture.calls.save, 0)
				helpers.assert_eq(fixture.calls.settings, 0)
			end)
		end)
	end
end)
