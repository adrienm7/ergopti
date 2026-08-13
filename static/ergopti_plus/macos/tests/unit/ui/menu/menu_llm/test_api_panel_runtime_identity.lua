--- tests/unit/ui/menu/menu_llm/test_api_panel_runtime_identity.lua

--- =============================================================================
--- MODULE: Regression — remote menu identity is a full runtime transition
--- DESCRIPTION:
--- Selecting another remote entry, or No Model, used to mutate ApiRemote while
--- leaving prediction_engine's visible pool and tooltip alive. ApiRemote could
--- fence a later HTTP callback, but already-published pixels still described the
--- previous paid/model identity. This drives the real menu actions and requires
--- engine reset to commit before the remote identity is changed.
--- =============================================================================

local helpers = require("tests.helpers")




helpers.describe("API panel runtime identity transaction", function()
	helpers.it("(api-panel-runtime-identity) (no-model-runtime) (remote-identity-generation) resets visible predictions before changing entry identity", function()
		local module_names = {
			"modules.llm", "infra.i18n", "infra.logger", "infra.dialog_util",
			"infra.notifications", "infra.manifest_menu", "ui.menu.menu_llm.api_panel",
		}
		local saved_modules = {}
		for _, name in ipairs(module_names) do saved_modules[name] = package.loaded[name] end
		local events = {}
		local entries = {
			{ id = "entry-a", provider = "openai", model = "model-a", label = "Entry A" },
			{ id = "entry-b", provider = "openai", model = "model-b", label = "Entry B" },
		}
		local active_id = "entry-a"
		local reset_commits = true
		local warmups = 0

		local api_remote = {
			PROVIDERS = { openai = { label = "OpenAI" } },
			get_entries = function() return entries end,
			get_active_entry_id = function() return active_id end,
			set_active_entry_id = function(id)
				active_id = id
				events[#events + 1] = "set:" .. id
			end,
		}
		package.loaded["modules.llm"] = {
			api_remote = api_remote,
			persist_api_entries = function() events[#events + 1] = "persist" end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end,
			warn = function() end, error = function() end,
		}
		package.loaded["infra.dialog_util"] = {}
		package.loaded["infra.notifications"] = {}
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
		}
		package.loaded["ui.menu.menu_llm.api_panel"] = nil

		local ok, err = xpcall(function()
			local ApiPanel = require("ui.menu.menu_llm.api_panel")
			local state = { llm_backend = "api", llm_model = "model-a" }
			local context = {
				state = state,
				paused = false,
				keymap = {
					reset_predictions = function()
						events[#events + 1] = "reset"
						return reset_commits
					end,
				},
				WarmupCtrl = {
					warmup = function()
						warmups = warmups + 1
						events[#events + 1] = "warmup"
					end,
				},
				update_menu = function() events[#events + 1] = "update" end,
			}

			local rows = ApiPanel.build_model_picker(context)
			helpers.assert_eq(rows[1].action(), true)
			helpers.assert_eq(events, { "reset", "set:", "persist", "update" },
				"No Model must revoke the old tooltip before clearing remote identity")
			helpers.assert_eq(active_id, "")
			helpers.assert_eq(state.llm_model, "")
			helpers.assert_eq(warmups, 0,
				"an explicit No Model identity has nothing to warm")

			events = {}
			rows = ApiPanel.build_model_picker(context)
			local entry_b_action
			for _, row in ipairs(rows) do
				if type(row.label) == "string" and row.label:find("Entry B", 1, true) then
					entry_b_action = row.action
				end
			end
			helpers.assert_type(entry_b_action, "function")
			helpers.assert_eq(entry_b_action(), true)
			helpers.assert_eq(events,
				{ "reset", "set:entry-b", "persist", "warmup", "update" },
				"entry B cannot publish until entry A's visible/request identity is revoked")
			helpers.assert_eq(active_id, "entry-b")
			helpers.assert_eq(state.llm_model, "model-b")

			reset_commits = false
			events = {}
			rows = ApiPanel.build_model_picker(context)
			local entry_a_action
			for _, row in ipairs(rows) do
				if type(row.label) == "string" and row.label:find("Entry A", 1, true) then
					entry_a_action = row.action
				end
			end
			helpers.assert_eq(entry_a_action(), false)
			helpers.assert_eq(events, { "reset" },
				"failed old-identity teardown must abort persistence, warmup and selection")
			helpers.assert_eq(active_id, "entry-b")
		end, debug.traceback)

		for _, name in ipairs(module_names) do package.loaded[name] = saved_modules[name] end
		if not ok then error(err) end
	end)
end)
