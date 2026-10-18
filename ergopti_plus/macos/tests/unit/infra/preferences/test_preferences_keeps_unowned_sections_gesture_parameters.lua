--- tests/unit/infra/preferences/test_preferences_keeps_unowned_sections_gesture_parameters.lua

--- ==============================================================================
--- MODULE: Preferences Keep Sections They Do Not Own
--- DESCRIPTION:
--- Preferences.save serialised only its own sections and replaced config.toml
--- wholesale, so [_meta] (the schema version the boot migration stamps), the
--- expert [script] and [features] overrides config_overrides reads, and any
--- other top-level table vanished at the first menu change. The next boot then
--- took the file for an unstamped one and migrated it again. These tests pin
--- that a save keeps every top-level table outside the sections it owns, that
--- the sections it owns still come from the state, and that a file it can no
--- longer decode is never replaced by the owned sections alone.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.infra.preferences.preferences_keeps_unowned_sections_fixture"] = nil
local Fixture = require("tests.support.infra.preferences.preferences_keeps_unowned_sections_fixture")
local TomlCodec = Fixture.TomlCodec





helpers.describe("Published gesture parameter identity source preservation", function()
	local LeafRows = require("toml_codec.leaf_rows")
	local Outdated = require("config_outdated")
	local source = table.concat({
		"# Independent user comments survive the admission scan.",
		"[_meta]", "schema_version = 3", "",
		"[gestures.action_parameters]",
		'removed_gesture_slot__open_url = "https://obsolete.example" # cleanup owns this row',
		'tap_3__open_url = "https://valid.example"',
		'swipe_3_horiz__open_url = "https://axis.example"',
		'keyboard__cmd_k__open_url = "https://keyboard.example"',
		'tap_key__a__open_url = "https://tap.example"',
		'script__reload__open_url = "https://script.example"',
		'', '[future]', 'keep = "independent"', '',
	}, "\n")

	local function read_file(path)
		local file = assert(io.open(path, "rb"))
		local bytes = assert(file:read("*a")); assert(file:close())
		return bytes
	end

	local function with_file(published, body)
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim",
			"modules.gestures", "modules.gestures.actions" }, function()
			package.loaded["modules.gestures"], package.loaded["modules.gestures.actions"] = nil, nil
			local gestures
			if published then gestures = helpers.load_with_stubs("modules.gestures")
			else helpers.load_with_stubs("modules.gestures.actions") end
			local warnings, errors = {}, {}
			local logger = helpers.make_logger_stub()
			logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			Outdated.reset_for_tests()
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local ok, err = xpcall(function() body(preferences, gestures, path, warnings, errors) end, debug.traceback)
			os.remove(path)
			if not ok then error(err, 0) end
		end)
	end

	local function marks_for(preferences)
		local decoded, shapes = LeafRows.decode_source(source)
		local marks = {}
		preferences.mark_config_reads(decoded, function(...)
			marks[require("toml_codec.key_path").render({ ... })] = true
		end, shapes)
		return marks
	end

	helpers.it("ignores a retired binding, leaves it unconsumed, warns once and keeps exact bytes", function()
		with_file(true, function(preferences, _, path, warnings, errors)
			local state, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_nil(state.gesture_action_parameters.removed_gesture_slot__open_url)
			helpers.assert_eq(state.gesture_action_parameters.tap_3__open_url, "https://valid.example")
			helpers.assert_eq(state.gesture_action_parameters.swipe_3_horiz__open_url, "https://axis.example")
			helpers.assert_eq(state.gesture_action_parameters.keyboard__cmd_k__open_url, "https://keyboard.example")
			helpers.assert_eq(state.gesture_action_parameters.tap_key__a__open_url, "https://tap.example")
			helpers.assert_eq(state.gesture_action_parameters.script__reload__open_url, "https://script.example")
			local marks = marks_for(preferences)
			helpers.assert_nil(marks["gestures.action_parameters.removed_gesture_slot__open_url"])
			helpers.assert_eq(marks["gestures.action_parameters.tap_3__open_url"], true)
			helpers.assert_eq(marks["gestures.action_parameters.keyboard__cmd_k__open_url"], true)
			preferences.load(path)
			helpers.assert_eq(#warnings, 1, "read and cleanup agree on one deduplicated warning")
			helpers.assert_contains(warnings[1], "gestures.action_parameters.removed_gesture_slot__open_url")
			helpers.assert_contains(warnings[1], "no gesture slot of this build has this name")
			helpers.assert_eq(#errors, 0)
			helpers.assert_eq(read_file(path), source, "admission and marking do not rewrite the user file")
		end)
	end)

	helpers.it("preserves the obsolete row across a complete save and an ordinary current-binding edit", function()
		with_file(true, function(preferences, gestures, path, warnings, errors)
			local state = preferences.load(path)
			for key, value in pairs(state.gesture_action_parameters) do
				local binding, action = gestures.split_action_parameter_key(key)
				helpers.assert_eq(gestures.set_action_parameter(binding, action, value), true, key)
			end
			helpers.assert_eq(gestures.set_action_parameter("tap_3", "open_url", "https://changed.example"), true)
			helpers.assert_eq(gestures.set_action_parameter("removed_gesture_slot", "open_url", "https://must-not-publish.example"), false)
			helpers.assert_eq(preferences.save(path, state, {}, { gestures = gestures }), true)
			local saved = read_file(path)
			helpers.assert_contains(saved, 'removed_gesture_slot__open_url = "https://obsolete.example" # cleanup owns this row')
			helpers.assert_contains(saved, "# Independent user comments survive the admission scan.")
			local expected = {
				removed_gesture_slot__open_url = "https://obsolete.example", tap_3__open_url = "https://changed.example",
				swipe_3_horiz__open_url = "https://axis.example", keyboard__cmd_k__open_url = "https://keyboard.example",
				tap_key__a__open_url = "https://tap.example", script__reload__open_url = "https://script.example",
			}
			helpers.assert_eq(TomlCodec.decode(saved).gestures.action_parameters, expected, "complete handwritten preserved parameter model")
			helpers.assert_eq(TomlCodec.decode(saved).future, { keep = "independent" })
			helpers.assert_eq(#warnings, 1)
			helpers.assert_eq(#errors, 0)
		end)
	end)

	helpers.it("keeps unavailable-catalogue entries without guessing their retirement", function()
		with_file(false, function(preferences, _, path, warnings, errors)
			local state = preferences.load(path)
			helpers.assert_eq(state.gesture_action_parameters.removed_gesture_slot__open_url, "https://obsolete.example")
			helpers.assert_eq(marks_for(preferences)["gestures.action_parameters.removed_gesture_slot__open_url"], true)
			helpers.assert_eq(#warnings, 0)
			helpers.assert_eq(#errors, 0)
			helpers.assert_eq(read_file(path), source)
		end)
	end)
end)

helpers.describe("macOS real preference root dotted scalar publication", function()
	local vectors = {
		{ name = "header", source = '[llm]\nagent_mode="auto"\nfuture=9007199254740993\n', owned = '[llm]\nagent_mode = "action"\nfuture=9007199254740993\n', accepted = true },
		{ name = "root dotted", source = 'llm.agent_mode="auto"\nfuture.keep=9007199254740993\n', owned = 'llm.agent_mode = "action"\nfuture.keep=9007199254740993\n', accepted = true },
		{ name = "root inline", source = 'llm={agent_mode="auto",future=9007199254740993}\n', owned = 'llm={agent_mode="action",future=9007199254740993}\n', accepted = true },
		{ name = "obsolete scalar", source = 'llm="obsolete"\nfuture.keep=9007199254740993\n', accepted = false },
	}
	for _, vector in ipairs(vectors) do
		helpers.it("uses the actual conditional preference publisher for " .. vector.name, function()
			helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
				local logger = helpers.make_logger_stub()
				package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
				package.loaded["adapters.file_system"] = nil
				local preferences = helpers.load_with_stubs("infra.preferences")
				local path = os.tmpname()
				local file = assert(io.open(path, "wb")); assert(file:write(vector.source)); assert(file:close())
				local okay, detail = xpcall(function()
					local state, status = preferences.load(path)
					helpers.assert_eq(status, "ok")
					helpers.assert_eq(preferences.save(path, { llm_agent_mode = "action" }, {}, {}), vector.accepted)
					local current = assert(io.open(path, "rb")); local bytes = assert(current:read("*a")); assert(current:close())
					local expected = vector.owned and vector.owned .. '\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n' or vector.source
					helpers.assert_eq(bytes, expected, "complete independently handwritten native source image")
					package.loaded["infra.preferences"] = nil
					local restarted, restart_status = helpers.load_with_stubs("infra.preferences").load(path)
					helpers.assert_eq(restart_status, "ok")
					if vector.accepted then helpers.assert_eq(restarted.llm_agent_mode, "action")
					elseif vector.name == "root inline" then helpers.assert_eq(restarted.llm_agent_mode, "auto")
					else helpers.assert_nil(restarted.llm_agent_mode) end
				end, debug.traceback)
				os.remove(path)
				if not okay then error(detail, 0) end
			end)
		end)
	end
end)

helpers.describe("macOS real root dotted numeric admission", function()
	helpers.it("acknowledges the exact requested finite temperature through the conditional publisher", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger = helpers.make_logger_stub()
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write('llm.generation.temperature=0.25\nfuture.keep=9007199254740993\n')); assert(file:close())
			local okay, detail = xpcall(function()
				local requested = 0.12345678901234567
				local _, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_true(preferences.save(path, { llm_temperature = requested }, {}, {}))
				local current = assert(io.open(path, "rb")); local bytes = assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes, 'llm.generation.temperature = 0.12345678901234566\nfuture.keep=9007199254740993\n\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
				package.loaded["infra.preferences"] = nil
				local restarted, restart_status = helpers.load_with_stubs("infra.preferences").load(path)
				helpers.assert_eq(restart_status, "ok")
				helpers.assert_eq(restarted.llm_temperature, requested)
			end, debug.traceback)
			os.remove(path)
			if not okay then error(detail, 0) end
		end)
	end)
end)

helpers.describe("macOS real finite header numeric admission", function()
	helpers.it("reloads an acknowledged exact temperature from its actual conditional source publisher", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger = helpers.make_logger_stub()
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write('[llm.generation]\ntemperature=0.25\nfuture=9007199254740993\n')); assert(file:close())
			local okay, detail = xpcall(function()
				local requested = 0.12345678901234567
				local _, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_true(preferences.save(path, { llm_temperature = requested }, {}, {}))
				local current = assert(io.open(path, "rb")); local bytes = assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes, '[llm.generation]\ntemperature = 0.12345678901234566\nfuture=9007199254740993\n\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
				package.loaded["infra.preferences"] = nil
				local restarted, restart_status = helpers.load_with_stubs("infra.preferences").load(path)
				helpers.assert_eq(restart_status, "ok")
				helpers.assert_eq(restarted.llm_temperature, requested)
			end, debug.traceback)
			os.remove(path)
			if not okay then error(detail, 0) end
		end)
	end)

	helpers.it("retains acknowledged negative zero through actual conditional preference restart", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger = helpers.make_logger_stub()
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write('[llm.generation]\ntemperature=0.25\nfuture=9007199254740993\n')); assert(file:close())
			local okay, detail = xpcall(function()
				local _, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_true(preferences.save(path, { llm_temperature = -0.0 }, {}, {}))
				local current = assert(io.open(path, "rb")); local bytes = assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes, '[llm.generation]\ntemperature = -0.0\nfuture=9007199254740993\n\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
				package.loaded["infra.preferences"] = nil
				local restarted, restart_status = helpers.load_with_stubs("infra.preferences").load(path)
				helpers.assert_eq(restart_status, "ok")
				helpers.assert_eq(1 / restarted.llm_temperature, -math.huge)
			end, debug.traceback)
			os.remove(path)
			if not okay then error(detail, 0) end
		end)
	end)

	helpers.it("retains the actual source on wrong numeric admission and permits an explicit repaired retry", function()
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger = helpers.make_logger_stub()
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			local preferences = helpers.load_with_stubs("infra.preferences")
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			local source = '[llm.generation]\ntemperature=0.25\nfuture=9007199254740993\n'
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local okay, detail = xpcall(function()
				local _, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				LeafRows.value_literal = function(value)
					if type(value) == "number" then return "0.12345678901235" end
					return original(value)
				end
				local called, accepted = pcall(preferences.save, path, { llm_temperature = 0.12345678901234567 }, {}, {})
				LeafRows.value_literal = original
				helpers.assert_eq(called, true)
				helpers.assert_eq(accepted, false)
				local current = assert(io.open(path, "rb")); local bytes = assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes, source)
				helpers.assert_true(preferences.save(path, { llm_temperature = 0.12345678901234567 }, {}, {}))
				current = assert(io.open(path, "rb")); bytes = assert(current:read("*a")); assert(current:close())
				helpers.assert_eq(bytes, '[llm.generation]\ntemperature = 0.12345678901234566\nfuture=9007199254740993\n\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n')
			end, debug.traceback)
			LeafRows.value_literal = original
			os.remove(path)
			if not okay then error(detail, 0) end
		end)
	end)
end)

helpers.describe("Mac real root inline scalar publication", function()
	local source = 'llm = { generation = { temperature=0.25, future=9007199254740993 }, private="untouched" } # exact trailer\n'
	local owned_tail = '\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n'
	local function actual_file(body)
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger = helpers.make_logger_stub()
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local okay, detail = xpcall(function()
				local _, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				local function bytes()
					local current = assert(io.open(path, "rb")); local content = assert(current:read("*a")); assert(current:close())
					return content
				end
				local function restart()
					package.loaded["infra.preferences"] = nil
					local state, read_status = helpers.load_with_stubs("infra.preferences").load(path)
					helpers.assert_eq(read_status, "ok")
					return state
				end
				body(preferences, path, bytes, restart)
			end, debug.traceback)
			os.remove(path)
			if not okay then error(detail, 0) end
		end)
	end
	helpers.it("acknowledges precise inline temperature and restarts the actual preferences owner", function()
		actual_file(function(preferences, path, bytes, restart)
			local wanted = 0.12345678901234567
			helpers.assert_true(preferences.save(path, { llm_temperature = wanted }, {}, {}))
			helpers.assert_eq(bytes(), 'llm = { generation = { temperature=0.12345678901234566, future=9007199254740993 }, private="untouched" } # exact trailer\n' .. owned_tail)
			helpers.assert_eq(restart().llm_temperature, wanted)
		end)
	end)
	helpers.it("retains acknowledged inline negative zero and foreign bytes through restart", function()
		actual_file(function(preferences, path, bytes, restart)
			helpers.assert_true(preferences.save(path, { llm_temperature = -0.0 }, {}, {}))
			helpers.assert_eq(bytes(), 'llm = { generation = { temperature=-0.0, future=9007199254740993 }, private="untouched" } # exact trailer\n' .. owned_tail)
			helpers.assert_eq(1 / restart().llm_temperature, -math.huge)
		end)
	end)
	helpers.it("resets only the explicit inline leaf and reloads its actual absence", function()
		actual_file(function(preferences, path, bytes, restart)
			local default = require("infra.manifest_reader").default_for("llm.generation.temperature")
			helpers.assert_true(preferences.save(path, { llm_temperature = default }, {}, {}))
			helpers.assert_eq(bytes(), 'llm = { generation = { future=9007199254740993 }, private="untouched" } # exact trailer\n' .. owned_tail)
			helpers.assert_nil(restart().llm_temperature, "the actual preferences reader owns absence after explicit reset")
		end)
	end)
	helpers.it("refuses an inexact optional literal without native publication then accepts repaired intent", function()
		actual_file(function(preferences, path, bytes, restart)
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			LeafRows.value_literal = function(value)
				if type(value) == "number" then return "0.12345678901235" end
				return original(value)
			end
			local called, accepted = pcall(preferences.save, path, { llm_temperature = 0.12345678901234567 }, {}, {})
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(bytes(), source)
			helpers.assert_true(preferences.save(path, { llm_temperature = 0.12345678901234567 }, {}, {}))
			helpers.assert_eq(bytes(), 'llm = { generation = { temperature=0.12345678901234566, future=9007199254740993 }, private="untouched" } # exact trailer\n' .. owned_tail)
			helpers.assert_eq(restart().llm_temperature, 0.12345678901234567)
		end)
	end)
	helpers.it("preserves an actual external inline source on stale save and permits reviewed fresh retry", function()
		actual_file(function(preferences, path, bytes, restart)
			local successor = source .. '# external successor\n'
			local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
			helpers.assert_eq(preferences.save(path, { llm_temperature = 0.75 }, {}, {}), false)
			helpers.assert_eq(bytes(), successor)
			helpers.assert_true(preferences.save(path, { llm_temperature = 0.75 }, {}, {}))
			helpers.assert_eq(bytes(), 'llm = { generation = { temperature=0.75, future=9007199254740993 }, private="untouched" } # exact trailer\n# external successor\n' .. owned_tail)
			helpers.assert_eq(restart().llm_temperature, 0.75)
		end)
	end)
end)

helpers.describe("Mac real section-relative dotted scalar publication", function()
	local source = '[llm] # exact header\ngeneration.temperature=0.25 # owned scalar\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n'
	local owned_tail = '\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n'
	local function actual_file(body)
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger = helpers.make_logger_stub()
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local okay, detail = xpcall(function()
				local _, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				local function bytes()
					local current = assert(io.open(path, "rb")); local content = assert(current:read("*a")); assert(current:close())
					return content
				end
				local function restart()
					package.loaded["infra.preferences"] = nil
					local state, read_status = helpers.load_with_stubs("infra.preferences").load(path)
					helpers.assert_eq(read_status, "ok")
					return state
				end
				body(preferences, path, bytes, restart)
			end, debug.traceback)
			os.remove(path)
			if not okay then error(detail, 0) end
		end)
	end
	helpers.it("acknowledges precise section-relative dotted temperature and restarts the actual preferences owner", function()
		actual_file(function(preferences, path, bytes, restart)
			local wanted = 0.12345678901234567
			helpers.assert_true(preferences.save(path, { llm_temperature = wanted }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration.temperature = 0.12345678901234566\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n' .. owned_tail)
			helpers.assert_eq(restart().llm_temperature, wanted)
		end)
	end)
	helpers.it("retains acknowledged section-relative dotted negative zero and foreign bytes through restart", function()
		actual_file(function(preferences, path, bytes, restart)
			helpers.assert_true(preferences.save(path, { llm_temperature = -0.0 }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration.temperature = -0.0\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n' .. owned_tail)
			helpers.assert_eq(1 / restart().llm_temperature, -math.huge)
		end)
	end)
	helpers.it("resets only the explicit section-relative dotted leaf and reloads its actual absence", function()
		actual_file(function(preferences, path, bytes, restart)
			local default = require("infra.manifest_reader").default_for("llm.generation.temperature")
			helpers.assert_true(preferences.save(path, { llm_temperature = default }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n' .. owned_tail)
			helpers.assert_nil(restart().llm_temperature, "the actual preferences reader owns absence after explicit reset")
		end)
	end)
	helpers.it("refuses an inexact optional literal without native publication then accepts repaired intent", function()
		actual_file(function(preferences, path, bytes, restart)
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			LeafRows.value_literal = function(value)
				if type(value) == "number" then return "0.12345678901235" end
				return original(value)
			end
			local called, accepted = pcall(preferences.save, path, { llm_temperature = 0.12345678901234567 }, {}, {})
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(bytes(), source)
			helpers.assert_true(preferences.save(path, { llm_temperature = 0.12345678901234567 }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration.temperature = 0.12345678901234566\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n' .. owned_tail)
			helpers.assert_eq(restart().llm_temperature, 0.12345678901234567)
		end)
	end)
	helpers.it("preserves an actual external section-relative dotted source on stale save and permits reviewed fresh retry", function()
		actual_file(function(preferences, path, bytes, restart)
			local successor = source .. '# external successor\n'
			local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
			helpers.assert_eq(preferences.save(path, { llm_temperature = 0.75 }, {}, {}), false)
			helpers.assert_eq(bytes(), successor)
			helpers.assert_true(preferences.save(path, { llm_temperature = 0.75 }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration.temperature = 0.75\ngeneration.future=9007199254740993 # foreign\nprivate="untouched"\n# external successor\n' .. owned_tail)
			helpers.assert_eq(restart().llm_temperature, 0.75)
		end)
	end)
end)

helpers.describe("Mac real section-relative inline scalar publication", function()
	local source = '[llm] # exact header\ngeneration = { temperature=0.25, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n'
	local owned_tail = '\n[hotstrings]\nmodules = {  }\n\n[shortcuts]\nkeys = {  }\n'
	local function actual_file(body)
		helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim" }, function()
			local logger = helpers.make_logger_stub()
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			package.loaded["adapters.file_system"] = nil
			local preferences = helpers.load_with_stubs("infra.preferences")
			local path = os.tmpname()
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			local okay, detail = xpcall(function()
				local _, status = preferences.load(path)
				helpers.assert_eq(status, "ok")
				local function bytes()
					local current = assert(io.open(path, "rb")); local content = assert(current:read("*a")); assert(current:close())
					return content
				end
				local function restart()
					package.loaded["infra.preferences"] = nil
					local state, read_status = helpers.load_with_stubs("infra.preferences").load(path)
					helpers.assert_eq(read_status, "ok")
					return state
				end
				body(preferences, path, bytes, restart)
			end, debug.traceback)
			os.remove(path)
			if not okay then error(detail, 0) end
		end)
	end
	helpers.it("acknowledges precise section-relative inline temperature and restarts the actual preferences owner", function()
		actual_file(function(preferences, path, bytes, restart)
			local wanted = 0.12345678901234567
			helpers.assert_true(preferences.save(path, { llm_temperature = wanted }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration = { temperature=0.12345678901234566, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n' .. owned_tail)
			helpers.assert_eq(restart().llm_temperature, wanted)
		end)
	end)
	helpers.it("retains acknowledged section-relative inline negative zero and foreign bytes through restart", function()
		actual_file(function(preferences, path, bytes, restart)
			helpers.assert_true(preferences.save(path, { llm_temperature = -0.0 }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration = { temperature=-0.0, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n' .. owned_tail)
			helpers.assert_eq(1 / restart().llm_temperature, -math.huge)
		end)
	end)
	helpers.it("resets only the explicit section-relative inline leaf and reloads its actual absence", function()
		actual_file(function(preferences, path, bytes, restart)
			local default = require("infra.manifest_reader").default_for("llm.generation.temperature")
			helpers.assert_true(preferences.save(path, { llm_temperature = default }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration = { future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n' .. owned_tail)
			helpers.assert_nil(restart().llm_temperature, "the actual preferences reader owns absence after explicit reset")
		end)
	end)
	helpers.it("refuses an inexact optional literal without native publication then accepts repaired intent", function()
		actual_file(function(preferences, path, bytes, restart)
			local LeafRows = require("toml_codec.leaf_rows")
			local original = LeafRows.value_literal
			LeafRows.value_literal = function(value)
				if type(value) == "number" then return "0.12345678901235" end
				return original(value)
			end
			local called, accepted = pcall(preferences.save, path, { llm_temperature = 0.12345678901234567 }, {}, {})
			LeafRows.value_literal = original
			helpers.assert_eq(called, true)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(bytes(), source)
			helpers.assert_true(preferences.save(path, { llm_temperature = 0.12345678901234567 }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration = { temperature=0.12345678901234566, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n' .. owned_tail)
			helpers.assert_eq(restart().llm_temperature, 0.12345678901234567)
		end)
	end)
	helpers.it("preserves an actual external section-relative inline source on stale save and permits reviewed fresh retry", function()
		actual_file(function(preferences, path, bytes, restart)
			local successor = source .. '# external successor\n'
			local file = assert(io.open(path, "wb")); assert(file:write(successor)); assert(file:close())
			helpers.assert_eq(preferences.save(path, { llm_temperature = 0.75 }, {}, {}), false)
			helpers.assert_eq(bytes(), successor)
			helpers.assert_true(preferences.save(path, { llm_temperature = 0.75 }, {}, {}))
			helpers.assert_eq(bytes(), '[llm] # exact header\ngeneration = { temperature=0.75, future=9007199254740993, empty=[], map={} } # exact outer trailer\nprivate="untouched"\n# external successor\n' .. owned_tail)
			helpers.assert_eq(restart().llm_temperature, 0.75)
		end)
	end)
end)
