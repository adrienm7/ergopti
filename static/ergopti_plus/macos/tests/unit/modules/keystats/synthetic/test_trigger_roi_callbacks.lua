--- tests/unit/modules/keystats/synthetic/test_trigger_roi_callbacks.lua

--- ==============================================================================
--- MODULE: macOS Trigger ROI Callback Admission
--- DESCRIPTION:
--- Drives the production keystats eventtap, hotstring sink, maintenance callback
--- and shutdown. The outbox accepts immutable builders; tests execute them only
--- after input returns, including refusal and retry at the queue boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixtures = require("tests.support.keystats_provenance_fixture")
local PreferenceManifest = helpers.load_with_stubs("menu.engine.manifest_reader")

--- Starts the real engine with observable persistence and native callback boundaries.
local function fixture()
	local f = Fixtures.load_keystats()
	package.loaded["menu.engine.manifest_reader"] = PreferenceManifest
	package.loaded["settings.engine.preferences.preferences"] = nil
	f.hs.caffeinate = { watcher = { new = function()
		return { start = function(self) return self end, stop = function(self) return self end }
	end } }
	package.loaded["modules.keymap"] = { is_known_trigger = function(word) return word == "known" end }
	local control = { now = 1000, calls = 0, builders = {}, rows = {}, errors = {} }
	f.hs.timer.absoluteTime = function() return control.now * 1000000 end
	local log = package.loaded["modules.keystats.log_manager"]
	log.append_log = function() return true end
	log.defer_entry_builder = function(builder)
		control.calls = control.calls + 1
		if control.reject_at == control.calls then return false end
		control.builders[#control.builders + 1] = builder
		return true
	end
	package.loaded["core.logger.engine.logger"].error = function(_, message) control.errors[#control.errors + 1] = message end
	local source_path = os.tmpname()
	assert(os.remove(source_path))
	local _, source_status = require("settings.engine.preferences.preferences").load(source_path)
	helpers.assert_eq(source_status, "absent", "the plaintext fixture owns a real absent preference source")
	helpers.assert_true(require("modules.keystats.text_cipher").set_enabled(false))
	f.start()
	f.state.active_app_name, f.state.session_app_name = "Editor", "Editor"
	f.state.active_win_title, f.state.roi_window_id = "Document", 42
	function control.drain()
		local queued = control.builders
		control.builders = {}
		for _, builder in ipairs(queued) do control.rows[#control.rows + 1] = builder() end
	end
	function control.roi()
		control.drain()
		local rows = {}
		for _, row in ipairs(control.rows) do
			if row.type == "roi_snapshot" or row.type == "new_trigger_candidate" or row.type == "trigger_halflife" then
				rows[#rows + 1] = row
			end
		end
		return rows
	end
	function control.key(chars, keycode, event_type)
		local event = Fixtures.physical_key(f.hs, "a")
		function event:getType() return event_type or f.hs.eventtap.event.types.keyDown end
		function event:getKeyCode() return keycode or 0 end
		function event:getCharacters() return chars end
		function event:getFlags() return {} end
		f.dispatch(event)
	end
	function control.tick()
		local delay = require("core.timing.engine.timings").sec("keystats", "maintenance_interval_ms")
		for _, timer in ipairs(f.hs.timer.__timers) do
			if timer.running and timer.delay == delay then timer:fire() end
		end
	end
	return f, control
end

helpers.describe("macOS trigger ROI admission", function()
	helpers.it("publishes fifth manual words and excludes the admitted trigger registry", function()
		local f, c = fixture()
		for _ = 1, 5 do c.key("candidate known ") end
		local rows = c.roi()
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].word, "candidate")
		helpers.assert_eq(rows[1].occurrences, 5)
		helpers.assert_eq(rows[1].app, "Editor")
		helpers.assert_eq(type(rows[1].timestamp), "string")
		helpers.assert_eq(c.errors, {})
		helpers.assert_true(f.keystats.stop())
	end)

	helpers.it("never joins a fragment across synthetic, private, unknown or pointer boundaries", function()
		local f, c = fixture()
		for _, barrier in ipairs({
			function() f.keystats.notify_synthetic("output", "llm", 0) end,
			function()
				f.state.is_secure_field = true
				c.key("hidden")
				f.state.is_secure_field = false
			end,
			function()
				f.state.roi_window_id = nil
				c.key("hidden")
				f.state.roi_window_id = 42
			end,
			function() c.key("", 0, f.hs.eventtap.event.types.leftMouseDown) end,
			function() c.key("", 0, f.hs.eventtap.event.types.rightMouseDown) end,
			function() c.key("", 0, f.hs.eventtap.event.types.otherMouseDown) end,
			function() c.key("", 0, f.hs.eventtap.event.types.scrollWheel) end,
		}) do
			for _ = 1, 5 do c.key("secr"); barrier(); c.key("et ") end
		end
		helpers.assert_nil(f.state.trigger_roi.words.secret)
		helpers.assert_eq(#c.roi(), 0)
		helpers.assert_eq(c.errors, {})
		helpers.assert_true(f.keystats.stop())
	end)

	helpers.it("does not join a word across policy exclusion and readmission without a key", function()
		local f, c = fixture()
		f.state.active_app_bundle = "com.example.Editor"
		for _ = 1, 5 do
			c.key("secr")
			f.keystats.set_disabled_apps({ { bundleID = "com.example.Editor" } })
			helpers.assert_eq(f.keystats.may_persist(), false)
			f.keystats.set_disabled_apps({})
			helpers.assert_true(f.keystats.may_persist())
			c.key("et ")
		end
		helpers.assert_nil(f.state.trigger_roi.words.secret)
		helpers.assert_eq(#c.roi(), 0)
		helpers.assert_true(f.keystats.stop())
	end)

	helpers.it("counts only accepted hotstrings, keeps private savings numeric and retries ROI queue refusal", function()
		local f, c = fixture()
		c.reject_at = 1
		helpers.assert_eq(f.keystats.log_hotstring("no", "not accepted"), false)
		helpers.assert_eq(f.state.trigger_roi.fired, 0)
		c.reject_at = 12 -- ten public event builders precede the first ROI builder.
		for _ = 1, 10 do helpers.assert_true(f.keystats.log_hotstring("😀", "😀😀")) end
		helpers.assert_eq(#f.state.trigger_roi.pending, 1)
		c.reject_at = nil
		helpers.assert_true(f.keystats.log_private_hotstring("PRIVATE", "PRIVATE output"))
		local rows = c.roi()
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].session_saved, 20)
		helpers.assert_eq(rows[1].session_fired, 10)
		helpers.assert_nil(f.state.trigger_roi.last_use.private)
		helpers.assert_true(f.keystats.stop())
		rows = c.roi()
		helpers.assert_eq(#rows, 2)
		helpers.assert_eq(rows[2].session_fired, 11)
		helpers.assert_eq(rows[2].session_saved, 27)
		helpers.assert_true(f.keystats.stop())
		helpers.assert_eq(#c.roi(), 2, "idempotent shutdown emits no second final snapshot")
	end)

	helpers.it("uses the existing maintenance timer and denies private-context final snapshots", function()
		local f, c = fixture()
		helpers.assert_true(f.keystats.log_hotstring("PUBLIC", "replacement"))
		c.now = c.now + 30 * 24 * 60 * 60 * 1000
		c.tick()
		local rows = c.roi()
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].type, "trigger_halflife")
		helpers.assert_eq(rows[1].trigger, "public")
		f.state.is_private_window = true
		c.now = c.now + 3600000
		c.tick()
		helpers.assert_eq(#c.roi(), 1)
		helpers.assert_true(f.keystats.stop())
		helpers.assert_eq(#c.roi(), 1)
		helpers.assert_eq(c.errors, {})
	end)
	helpers.it("retires words on requested or unknown encryption even when the provider stays off", function()
		local f, c = fixture()
		local cipher = require("modules.keystats.text_cipher")
		local available = cipher.is_available
		cipher.is_available = function()
			helpers.assert_eq(next(f.state.trigger_roi.words), nil, "the requested transition revokes words before key lookup")
			helpers.assert_eq(f.state.trigger_roi.word, {})
			helpers.assert_eq(next(f.state.trigger_roi.last_use), nil)
			return false
		end
		local ok, reason = xpcall(function()
			for _ = 1, 4 do c.key("candidate ") end
			c.key("fragment")
			helpers.assert_true(f.keystats.log_hotstring("PUBLIC", "public replacement"))
			helpers.assert_true(f.keystats.set_options({ encrypt = true }))
			helpers.assert_eq(cipher.is_enabled(), false)
			helpers.assert_eq(f.state.trigger_roi.words, {})
			helpers.assert_eq(f.state.trigger_roi.last_use, {})
			helpers.assert_eq(f.state.trigger_roi.word, {})
			for _ = 1, 5 do c.key("candidate ") end
			helpers.assert_eq(#c.roi(), 0)
			for _ = 1, 9 do helpers.assert_true(f.keystats.log_private_hotstring("secret", "secret output")) end
			helpers.assert_eq(c.roi()[1].session_fired, 10)
			f.state.is_secure_field = true
			helpers.assert_eq(f.keystats.log_private_hotstring("secret", "secret output"), false)
			helpers.assert_eq(f.state.trigger_roi.fired, 10)
			f.state.is_secure_field = false
			helpers.assert_true(f.keystats.set_options({}))
			for _ = 1, 5 do c.key("unknown ") end
			helpers.assert_eq(f.state.trigger_roi.words, {})
			helpers.assert_true(f.keystats.set_options({ encrypt = false }))
			for _ = 1, 4 do c.key("candidate ") end
			helpers.assert_eq(#c.roi(), 1, "prior counts cannot revive after encryption is off")
			c.key("candidate ")
			helpers.assert_eq(c.roi()[2].word, "candidate")
		end, debug.traceback)
		cipher.is_available = available
		helpers.assert_true(f.keystats.stop())
		if not ok then error(reason, 0) end
	end)

	helpers.it("retires text before a scope activation is refused by an existing migration", function()
		local f, c = fixture()
		local candidate = f.keystats.configuration_snapshot()
		candidate.options.encrypt, candidate.cipher_enabled = true, true
		for _ = 1, 4 do c.key("candidate ") end
		c.key("fragment")
		local migration = require("modules.keystats.text_migration")
		local previous = migration.is_running
		migration.is_running = function()
			helpers.assert_eq(f.state.trigger_roi.words, {})
			helpers.assert_eq(f.state.trigger_roi.word, {})
			return true
		end
		local called, result = pcall(f.keystats.apply_configuration, candidate)
		migration.is_running = previous
		helpers.assert_true(called)
		helpers.assert_eq(result, false)
		helpers.assert_eq(f.state.options.encrypt, false)
		helpers.assert_true(require("modules.keystats.text_cipher").roi_text_enabled())
		for _ = 1, 4 do c.key("candidate ") end
		helpers.assert_eq(#c.roi(), 0, "a clean refusal cannot restore the discarded counts")
		c.key("candidate ")
		helpers.assert_eq(c.roi()[1].occurrences, 5)
		helpers.assert_true(f.keystats.stop())
	end)

	for _, source in ipairs({
		'[metrics]\nencrypt = "true"\n', '[metrics]\nencrypt = "false"\n',
		'[metrics]\nencrypt = [true]\n', '[[metrics.encrypt]]\nvalue = true\n',
		'[[metrics]]\nencrypt = false\n', 'metrics = []\n',
		'[metrics]\nencrypt = true\n', '[metrics]\nencrypt = { invalid = true }\n',
		'[metrics]\nencrypt = 1\n',
	}) do
		helpers.it("denies textual ROI from the actual non-OFF source " .. source:gsub("\n", " "), function()
			local f, c = fixture()
			local prefs = require("settings.engine.preferences.preferences")
			local cipher = require("modules.keystats.text_cipher")
			for _ = 1, 4 do c.key("candidate ") end
			c.key("fragment")
			local path = os.tmpname()
			local function write(contents)
				local file = assert(io.open(path, "wb")); assert(file:write(contents)); assert(file:close())
			end
			local called, failure = xpcall(function()
				write(source)
				local saved, status = prefs.load(path)
				helpers.assert_eq(status, "ok")
				local projected = { keystats_encrypt = false }
				prefs.merge_saved_data(projected, saved)
				-- The ordinary reader keeps its existing defaults; only the ROI
				-- gate needs the strict source verdict behind that projection.
				helpers.assert_eq(projected.keystats_encrypt, source:find("encrypt = true", 1, true) ~= nil)
				helpers.assert_eq(cipher.roi_text_enabled(), false)
				helpers.assert_eq(f.state.trigger_roi.words, {})
				helpers.assert_eq(f.state.trigger_roi.word, {})
				for _ = 1, 5 do c.key("candidate ") end
				helpers.assert_eq(#c.roi(), 0)
				write("[metrics]\nencrypt = false\n")
				helpers.assert_eq(select(2, prefs.load(path)), "ok")
				helpers.assert_true(f.keystats.set_options({ encrypt = false }))
				for _ = 1, 4 do c.key("candidate ") end
				helpers.assert_eq(#c.roi(), 0, "source recovery cannot resurrect pre-revocation words")
				c.key("candidate ")
				helpers.assert_eq(c.roi()[1].occurrences, 5)
			end, debug.traceback)
			assert(os.remove(path))
			helpers.assert_true(f.keystats.stop())
			if not called then error(failure, 0) end
		end)
	end

	helpers.it("revokes a refused reload before native I/O and keeps input free from reads and decoding", function()
		local f, c = fixture()
		local prefs = require("settings.engine.preferences.preferences")
		local cipher = require("modules.keystats.text_cipher")
		local path = os.tmpname()
		local file = assert(io.open(path, "wb")); assert(file:write("[metrics]\nencrypt = false\n")); assert(file:close())
		helpers.assert_eq(select(2, prefs.load(path)), "ok")
		helpers.assert_true(f.keystats.set_options({ encrypt = false }))
		c.key("fragment")
		local files = require("core.fs.adapters.file_system")
		local read = files.read_with_status
		files.read_with_status = function(name, ...)
			if name ~= path then return read(name, ...) end
			helpers.assert_eq(f.state.trigger_roi.word, {}, "the old OFF fragment is revoked before a native read can reenter")
			return nil, "error"
		end
		local called, saved, status = pcall(prefs.load, path)
		files.read_with_status = read
		helpers.assert_true(called)
		helpers.assert_eq(status, "corrupt")
		helpers.assert_eq(saved, {})
		helpers.assert_eq(cipher.roi_text_enabled(), false)
		local open = io.open
		local rows = require("core.text.engine.toml_codec.leaf_rows")
		local decode = rows.decode_source
		io.open = function() error("input cannot read preferences") end
		rows.decode_source = function() error("input cannot decode preferences") end
		local input_ok, input_error = pcall(function()
			for _ = 1, 5 do c.key("secret ") end
			helpers.assert_eq(#c.roi(), 0)
		end)
		io.open, rows.decode_source = open, decode
		if input_ok then
			helpers.assert_eq(select(2, prefs.load(path)), "ok")
			helpers.assert_true(f.keystats.set_options({ encrypt = false }))
			io.open = function() error("admitted input cannot read preferences") end
			rows.decode_source = function() error("admitted input cannot decode preferences") end
			input_ok, input_error = pcall(function()
				for _ = 1, 5 do c.key("fresh ") end
				helpers.assert_eq(c.roi()[1].word, "fresh")
			end)
			io.open, rows.decode_source = open, decode
		end
		assert(os.remove(path))
		helpers.assert_true(f.keystats.stop())
		if not input_ok then error(input_error, 0) end
	end)

	for _, source in ipairs({ '[metrics]\nencrypt = true\n', '[metrics]\nencrypt = "true"\n', '[metrics\n' }) do
		helpers.it("revokes a changed read-only source without adopting it " .. source:gsub("\n", " "), function()
			local f, c = fixture()
			local prefs = require("settings.engine.preferences.preferences")
			local cipher = require("modules.keystats.text_cipher")
			local path = os.tmpname()
			local function write(contents)
				local file = assert(io.open(path, "wb")); assert(file:write(contents)); assert(file:close())
			end
			local called, failure = xpcall(function()
				write("[metrics]\nencrypt = false\n")
				helpers.assert_eq(select(2, prefs.load(path)), "ok")
				helpers.assert_true(f.keystats.set_options({ encrypt = false }))
				local before = prefs.source_snapshot(path)
				c.key("fragment")
				write(source)
				prefs.current_view(path, true)
				helpers.assert_eq(cipher.roi_text_enabled(), false)
				helpers.assert_eq(f.state.trigger_roi.word, {})
				helpers.assert_eq(prefs.source_snapshot(path), before, "read-only views cannot grant overwrite authority")
				write("[metrics]\nencrypt = false\n")
				prefs.current_view(path, true)
				helpers.assert_true(cipher.set_enabled(false))
				helpers.assert_eq(cipher.roi_text_enabled(), false, "a read-only OFF view cannot reopen the retired source")
				helpers.assert_eq(select(2, prefs.load(path)), "ok")
				helpers.assert_true(f.keystats.set_options({ encrypt = false }))
				helpers.assert_true(cipher.roi_text_enabled())
			end, debug.traceback)
			assert(os.remove(path))
			helpers.assert_true(f.keystats.stop())
			if not called then error(failure, 0) end
		end)
	end

	helpers.it("keeps the exact source receipt when a reload is refused during an owned publication", function()
		local f, c = fixture()
		local prefs = require("settings.engine.preferences.preferences")
		local path = os.tmpname()
		local file = assert(io.open(path, "wb")); assert(file:write("[metrics]\nencrypt = false\n")); assert(file:close())
		helpers.assert_eq(select(2, prefs.load(path)), "ok")
		helpers.assert_true(f.keystats.set_options({ encrypt = false }))
		local before = prefs.source_snapshot(path)
		c.key("fragment")
		local writer = require("core.text.engine.toml_codec.writer")
		local previous = writer.batch_write
		writer.batch_write = function()
			local called, reason = pcall(prefs.load, path)
			helpers.assert_eq(called, false)
			helpers.assert_true(tostring(reason):find("publication is still active", 1, true) ~= nil)
			return false, "controlled publication refusal"
		end
		local called, published = pcall(prefs.publish_owned, path, {}, before)
		writer.batch_write = previous
		assert(os.remove(path))
		helpers.assert_true(called)
		helpers.assert_eq(published, false)
		helpers.assert_eq(prefs.source_snapshot(path), before, "refusing a reload cannot surrender the prior source receipt")
		helpers.assert_eq(require("modules.keystats.text_cipher").roi_text_enabled(), false)
		helpers.assert_eq(f.state.trigger_roi.word, {})
		helpers.assert_true(f.keystats.stop())
	end)

end)
