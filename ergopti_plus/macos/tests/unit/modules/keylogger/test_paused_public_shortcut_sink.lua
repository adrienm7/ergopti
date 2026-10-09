--- tests/unit/modules/keylogger/test_paused_public_shortcut_sink.lua

--- ==============================================================================
--- MODULE: Paused Keylogger Public-Sink Regression
--- DESCRIPTION:
--- Starts the real keylogger with a live pause predicate and drives its exported
--- shortcut sink directly. Public writers must share the physical event path's
--- pause fence rather than relying only on enabled and context filters.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_module = require("tests.support.keylogger_provenance_fixture")

helpers.describe("audit pause fence: keylogger public shortcut sink", function()
	helpers.it("audit pause fence: every public persistence sink is silent while paused", function()
		local fixture = fixture_module.load_keylogger()
		local writes = 0
		local log_manager = package.loaded["modules.keylogger.log_manager"]
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
		fixture.keylogger.notify_synthetic("synthetic", "hotstring", 1, nil, "synthetic", false)
		fixture.keylogger.log_hotstring("btw", "by the way", "star")
		fixture.keylogger.log_llm("context", { { to_type = "prediction" } }, "TextEdit", {})
		fixture.keylogger.log_llm_failed("context", "TextEdit", { failure_reason = "test" })
		fixture.keylogger.log_shortcut("Alt+Backspace", "TextEdit")
		fixture.keylogger.log_hotstring_suggested("TextEdit", "btw", "by the way", "star")
		fixture.keylogger.log_hotstring_dismissed("TextEdit", "btw", "by the way", "star")
		fixture.keylogger.log_llm_suggested("TextEdit", 1)
		fixture.keylogger.log_llm_dismissed("TextEdit", { "prediction" })
		fixture.keylogger.log_llm_accepted("prediction", "TextEdit", { "prediction" }, 1, 0, "")
		local writes_while_paused = writes

		paused = false
		fixture.keylogger.log_shortcut("Cmd+C", "TextEdit")

		helpers.assert_eq(writes_while_paused, 0,
			"an exported keylogger writer must persist nothing during pause")
		helpers.assert_eq(writes, 1,
			"the identical public sink must persist again after resume")
	end)
end)
