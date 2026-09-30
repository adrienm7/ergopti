--- tests/unit/infra/test_preferences_llm_units.lua

local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local FS = require("adapters.file_system")
local function fixture(initial)
	local content, writes = initial, 0
	package.loaded["adapters.file_system"] = {
		read_with_status = function() return content, "ok" end,
		write = function() error("conditional publication required") end,
		write_if_unchanged = function(_, candidate, expected)
			if expected.content ~= content then return false end
			content, writes = candidate, writes + 1
			return true
		end,
	}
	local prefs = helpers.load_with_stubs("infra.preferences")
	return prefs, function() return content, writes end
end
helpers.describe("canonical LLM debounce persistence", function()
	helpers.it("loads milliseconds as native seconds and round-trips through the real sparse writer", function()
		local prefs, observed = fixture('[llm.trigger]\ndebounce_ms = 350\nfuture = { keep = true }\n')
		local state, status = prefs.load("config")
		helpers.assert_eq(status, "ok")
		helpers.assert_eq(state.llm_debounce, 0.35)
		helpers.assert_eq(prefs.flat_key_for("llm.trigger.debounce_ms"), "llm_debounce")
		helpers.assert_eq(prefs.state_value_for("llm.trigger.debounce_ms", 125), 0.125)
		state.llm_debounce = 0.425
		helpers.assert_eq(prefs.save("config", state, {}, {}), true)
		local disk = Codec.decode(observed())
		helpers.assert_eq(disk.llm.trigger.debounce_ms, 425)
		helpers.assert_eq(disk.llm.trigger.debounce, nil)
		helpers.assert_eq(disk.llm.trigger.future.keep, true)
		helpers.assert_eq(prefs.load("config").llm_debounce, 0.425)
	end)
	helpers.it("deletes the canonical neutral value and does not claim or migrate the old spelling", function()
		local prefs, observed = fixture('[llm.trigger]\ndebounce_ms = 900\ndebounce = 4\n')
		local state = prefs.load("config")
		helpers.assert_eq(state.llm_debounce, 0.9)
		state.llm_debounce = 0.2
		helpers.assert_eq(prefs.save("config", state, {}, {}), true)
		local disk = Codec.decode(observed())
		helpers.assert_eq(disk.llm.trigger.debounce_ms, nil)
		helpers.assert_eq(disk.llm.trigger.debounce, 4)
		local marks = {}
		prefs.mark_config_reads({ llm = { trigger = { debounce_ms = 0, debounce = 1 } } },
			function(...) marks[table.concat({ ... }, ".")] = true end)
		helpers.assert_eq(marks["llm.trigger.debounce_ms"], true)
		helpers.assert_eq(marks["llm.trigger.debounce"], nil)
	end)
	helpers.it("keeps zero and fractional milliseconds while rejecting invalid units before publication", function()
		local prefs, observed = fixture('[llm.trigger]\ndebounce_ms = 0\n')
		local state = prefs.load("config")
		helpers.assert_eq(state.llm_debounce, 0)
		state.llm_debounce = 0.0005
		helpers.assert_eq(prefs.save("config", state, {}, {}), true)
		helpers.assert_eq(Codec.decode(observed()).llm.trigger.debounce_ms, 0.5)
		local prior, writes = observed()
		state.llm_debounce = "0.5"
		helpers.assert_eq(prefs.save("config", state, {}, {}), false)
		local after, next_writes = observed()
		helpers.assert_eq(after, prior)
		helpers.assert_eq(next_writes, writes)
	end)
	helpers.it("ignores one invalid persisted duration without discarding the file (config-outdated-units)", function()
		-- The unit conversion asserted inside the load: one bad leaf made the
		-- whole config.toml load as corrupt and every setting revert to defaults.
		local bad = fixture('[llm.trigger]\ndebounce_ms = "invalid"\n[llm.generation]\nmin_words = 3\n')
		local loaded, status = bad.load("config")
		helpers.assert_eq(status, "ok")
		helpers.assert_nil(loaded.llm_debounce)
		helpers.assert_eq(loaded.llm_min_words, 3)
	end)
end)
package.loaded["adapters.file_system"] = FS
package.loaded["infra.preferences"] = nil
