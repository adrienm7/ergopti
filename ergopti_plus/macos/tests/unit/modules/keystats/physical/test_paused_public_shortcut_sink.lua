--- tests/unit/modules/keystats/physical/test_paused_public_shortcut_sink.lua

--- ==============================================================================
--- MODULE: Paused Keystats Public-Sink Regression
--- DESCRIPTION:
--- Starts the real keystats with a live pause predicate and drives its exported
--- shortcut sink directly. Public writers must share the physical event path's
--- pause fence rather than relying only on enabled and context filters.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_module = require("tests.support.keystats_provenance_fixture")

helpers.describe("audit pause fence: keystats public shortcut sink", function()
	helpers.it("audit pause fence: every public persistence sink is silent while paused", function()
		local fixture = fixture_module.load_keystats()
		local writes = 0
		local log_manager = package.loaded["modules.keystats.log_manager"]
		local function record_write()
			writes = writes + 1
		end
		log_manager.flush_buffer = record_write
		log_manager.append_log = record_write
		log_manager.increment_manifest_stat = record_write
		log_manager.log_shortcut = record_write

		fixture.hs.caffeinate = {
			watcher = {
				new = function()
					return {
						start = function(self) return self end,
						stop = function(self) return self end,
					}
				end,
			},
		}

		local paused = true
		fixture.start({ is_paused = function() return paused end })
		fixture.keystats.notify_synthetic("synthetic", "hotstring", 1, nil, "synthetic", false)
		fixture.keystats.log_hotstring("btw", "by the way", "star")
		fixture.keystats.log_llm("context", { { to_type = "prediction" } }, "TextEdit", {})
		fixture.keystats.log_llm_failed("context", "TextEdit", { failure_reason = "test" })
		fixture.keystats.log_shortcut("Alt+Backspace", "TextEdit")
		fixture.keystats.log_hotstring_suggested("TextEdit", "btw", "by the way", "star")
		fixture.keystats.log_hotstring_dismissed("TextEdit", "btw", "by the way", "star")
		fixture.keystats.log_llm_suggested("TextEdit", 1)
		fixture.keystats.log_llm_dismissed("TextEdit", { "prediction" })
		fixture.keystats.log_llm_accepted("prediction", "TextEdit", { "prediction" }, 1, 0, "")
		local writes_while_paused = writes

		paused = false
		fixture.keystats.log_shortcut("Cmd+C", "TextEdit")

		helpers.assert_eq(writes_while_paused, 0,
			"an exported keystats writer must persist nothing during pause")
		helpers.assert_eq(writes, 1,
			"the identical public sink must persist again after resume")
	end)
end)
