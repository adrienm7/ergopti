--- tests/unit/platform/remap/test_config_runtime_selector.lua

--- ==============================================================================
--- MODULE: Native Runtime Selector Persistence
--- DESCRIPTION:
--- Fixed populated source documents prove that native scalar selection owns only
--- its leaf, keeps typed source custody, and grants no installed runtime authority.
--- Uses the real codec and conditional file algorithm under portable native ports.
--- ==============================================================================

local helpers = require("tests.helpers")

local POPULATED = '[karabiner]\nruntime = "owned"\nintegration_enabled = false\nenabled = 1.0\n'
	.. '[karabiner.future]\nlist = []\nkind = 1.0\n'
	.. '[tap_holds]\nenabled = true\ntimeout_ms = 321\nsticky_timeout_ms = 654\n'
	.. '[tap_holds.config.tab]\ntap = "copy"\nhold = "ctrl"\n'
	.. '[mod_combos]\nenabled = false\nsimultaneous_threshold_ms = 87\nsymmetric = true\n'
	.. '[mod_combos.config.esc_tab]\ntap = "paste"\nhold = "shift"\ncombo = "copy"\n'
	.. '[future]\ninteger = 9_223_372_036_854_775_807\nempty = []\n'
	.. 'precise = 1.2345678901234567\nkind = 1.0\n'

local EXPECTED_NEIGHBORS = {
	karabiner = { integration_enabled = false, enabled = 1.0, future = { list = {}, kind = 1.0 } },
	tap_holds = { enabled = true, timeout_ms = 321, sticky_timeout_ms = 654,
		config = { tab = { tap = "copy", hold = "ctrl" } } },
	mod_combos = { enabled = false, simultaneous_threshold_ms = 87, symmetric = true,
		config = { esc_tab = { tap = "paste", hold = "shift", combo = "copy" } } },
	future = { integer = 9223372036854775807, empty = {}, precise = 1.2345678901234567, kind = 1.0 },
}

--- Exercises actual source admission and conditional publication on one private file.
--- @param source string|nil Fixed source bytes or absent.
--- @param body function Receives owner, actual file ports and narrow race controls.
local function with_file(source, body)
	helpers.with_stub_scope({ "platform.remap.config", "adapters.file_system", "infra.toml.codec", "toml_codec" }, function()
		local config = helpers.load_with_stubs("platform.remap.config")
		local files, codec = require("adapters.file_system"), require("infra.toml.codec")
		local path = os.tmpname()
		local function write(text)
			local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
		end
		local function read()
			local file = io.open(path, "rb")
			if not file then return nil end
			local text = assert(file:read("*a")); assert(file:close()); return text
		end
		if source == nil then os.remove(path) else write(source) end
		local native = files.write_if_unchanged
		local controls = { writes = 0 }
		files.write_if_unchanged = function(destination, candidate, expected)
			controls.writes = controls.writes + 1
			helpers.assert_eq(destination, path)
			helpers.assert_eq(expected, source == nil and { status = "absent" }
				or { status = "ok", content = source })
			if controls.before_publish then controls.before_publish() end
			return native(destination, candidate, expected)
		end
		local ok, err = pcall(body, { config = config, files = files, codec = codec, path = path,
			read = read, write = write, controls = controls,
			source = source == nil and { path = path, status = "absent" }
				or { path = path, status = "ok", content = source } })
		files.write_if_unchanged = native
		os.remove(path); os.remove(path .. ".tmp")
		if not ok then error(err, 0) end
	end)
end

--- Requires every fixed neighbor and its precise literal/array source kind.
--- @param f table Private file owner.
local function assert_neighbors(f)
	local stored = f.codec.decode(f.read())
	stored.karabiner.runtime = nil
	helpers.assert_eq(stored, EXPECTED_NEIGHBORS)
	for _, token in ipairs({ "enabled = 1.0", "integer = 9_223_372_036_854_775_807",
		"precise = 1.2345678901234567", "empty = []", "list = []", "kind = 1.0" }) do
		helpers.assert_contains(f.read(), token)
	end
end

helpers.describe("native runtime selector scalar owner", function()
	for _, source in ipairs({ "", '[karabiner]\nintegration_enabled = false\n' }) do
		helpers.it("missing runtime reads declared shared without rewriting " .. source:gsub("\n", " "), function()
			with_file(source, function(f)
				local state, status, receipt = f.config.load_user_config({}, {}, f.path)
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(state.runtime, "shared")
				helpers.assert_eq(receipt, f.source)
				helpers.assert_eq(f.read(), source)
				helpers.assert_eq(f.controls.writes, 0)
			end)
		end)
	end
	helpers.it("absent source and explicit recommended state retain shared default", function()
		with_file(nil, function(f)
			local state, status, receipt = f.config.load_user_config({}, {}, f.path)
			helpers.assert_eq(status, "absent")
			helpers.assert_eq(state.runtime, "shared")
			helpers.assert_eq(f.config.build_recommended_state({}, {}).runtime, "shared")
			helpers.assert_eq(receipt, f.source)
			helpers.assert_nil(f.read())
		end)
	end)
	helpers.it("owned remains requested and consent remains independent", function()
		with_file(POPULATED, function(f)
			local state, status = f.config.load_user_config({ { id = "tab" } }, { { id = "esc_tab" } }, f.path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.runtime, "owned")
			helpers.assert_eq(state.enabled, false)
			helpers.assert_eq(f.read(), POPULATED)
		end)
	end)
	for _, literal in ipairs({ '"future"', '""', '"SHARED"', "true", "7", "1.0", '[]', '{ future = true }' }) do
		helpers.it("unknown runtime refuses admission and preserves source " .. literal, function()
			local source = '[karabiner]\nruntime = ' .. literal .. '\n'
			with_file(source, function(f)
				local state, status = f.config.load_user_config({}, {}, f.path)
				helpers.assert_nil(state)
				helpers.assert_eq(status, "error")
				helpers.assert_eq(f.read(), source)
				helpers.assert_eq(f.controls.writes, 0)
			end)
		end)
	end
	for _, source in ipairs({ 'karabiner = "opaque"\n', 'karabiner = []\n', '[[karabiner]]\nruntime = "owned"\n' }) do
		helpers.it("typed parent refuses read and scalar write " .. source:gsub("\n", " "), function()
			with_file(source, function(f)
				local state, status = f.config.load_user_config({}, {}, f.path)
				helpers.assert_nil(state)
				helpers.assert_eq(status, "error")
				helpers.assert_eq(f.config.save_runtime("shared", f.path, f.source), false)
				helpers.assert_eq(f.read(), source)
				helpers.assert_eq(f.controls.writes, 0)
			end)
		end)
	end
	helpers.it("scalar shared publication omits only its default and preserves all neighbors", function()
		with_file(POPULATED, function(f)
			local saved, _, receipt = f.config.save_runtime("shared", f.path, f.source)
			helpers.assert_true(saved)
			helpers.assert_nil(f.codec.decode(f.read()).karabiner.runtime)
			assert_neighbors(f)
			helpers.assert_eq(receipt.path, f.path)
			helpers.assert_eq(receipt.source, { status = "ok", content = POPULATED })
			helpers.assert_eq(receipt.candidate, f.read())
			helpers.assert_eq(f.controls.writes, 1)
		end)
	end)
	helpers.it("scalar owned publication writes only its leaf on an absent source", function()
		with_file(nil, function(f)
			helpers.assert_true(f.config.save_runtime("owned", f.path, f.source))
			helpers.assert_eq(f.codec.decode(f.read()), { karabiner = { runtime = "owned" } })
		end)
	end)
	helpers.it("shared scalar from absent never seeds other settings", function()
		with_file(nil, function(f)
			helpers.assert_true(f.config.save_runtime("shared", f.path, f.source))
			helpers.assert_eq(f.codec.decode(f.read()), {})
		end)
	end)
	helpers.it("invalid selector candidates never repair or publish", function()
		with_file(POPULATED, function(f)
			for _, value in ipairs({ "future", "SHARED", 7, true, {} }) do
				helpers.assert_eq(f.config.save_runtime(value, f.path, f.source), false)
			end
			helpers.assert_eq(f.read(), POPULATED)
			helpers.assert_eq(f.controls.writes, 0)
		end)
	end)
	helpers.it("stale source and wrong destination receipt refuse before publication", function()
		with_file(POPULATED, function(f)
			helpers.assert_eq(f.config.save_runtime("shared", f.path, { path = f.path, status = "ok", content = "" }), false)
			helpers.assert_eq(f.config.save_runtime("shared", f.path, { path = f.path .. ".other", status = "ok", content = POPULATED }), false)
			helpers.assert_eq(f.config.save_runtime("shared", f.path), false)
			helpers.assert_eq(f.read(), POPULATED)
			helpers.assert_eq(f.controls.writes, 0)
		end)
	end)
	helpers.it("publication source race preserves the concurrent writer", function()
		with_file(POPULATED, function(f)
			local changed = '[karabiner]\nruntime = "owned"\n[future]\nrevision = 42\n'
			f.controls.before_publish = function() f.write(changed) end
			helpers.assert_eq(f.config.save_runtime("shared", f.path, f.source), false)
			helpers.assert_eq(f.read(), changed)
		end)
	end)
	helpers.it("absent source race never overwrites a newly created native file", function()
		with_file(nil, function(f)
			local changed = '[future]\nrevision = 42\n'
			f.controls.before_publish = function() f.write(changed) end
			helpers.assert_eq(f.config.save_runtime("owned", f.path, f.source), false)
			helpers.assert_eq(f.read(), changed)
		end)
	end)
	helpers.it("ambiguous native publication retains its exact cleanup and readback receipt", function()
		with_file(POPULATED, function(f)
			local original = f.files.write_if_unchanged
			local cleanup = function() return false, "controlled native custody remains" end
			f.files.write_if_unchanged = function(path, candidate, source)
				helpers.assert_true(original(path, candidate, source))
				return false, "controlled post-publication refusal", cleanup
			end
			local saved, reason, receipt = f.config.save_runtime("shared", f.path, f.source)
			helpers.assert_eq(saved, false)
			helpers.assert_eq(reason, "controlled post-publication refusal")
			helpers.assert_eq(receipt.publication_cleanup, cleanup)
			helpers.assert_eq(receipt.source, { status = "ok", content = POPULATED })
			helpers.assert_eq(receipt.candidate, f.read())
			helpers.assert_eq(receipt.verify_absence, true)
			assert_neighbors(f)
			local view = f.files.publication_receipt_view(receipt, f.path, receipt.source, receipt.candidate)
			helpers.assert_nil(view, "a config wrapper cannot impersonate an opaque native publication capability")
			helpers.assert_eq(f.files.read(f.path), receipt.candidate)
		end)
	end)
	for _, source in ipairs({ POPULATED, '[karabiner]\nruntime = "future"\nenabled = 1.0\n' }) do
		helpers.it("ordinary and recommended settings saves never acquire runtime " .. source:sub(1, 45), function()
			with_file(source, function(f)
				local desired = f.config.build_recommended_state({ { id = "tab" } }, {})
				desired.enabled = nil
				helpers.assert_true(f.config.save_user_config(desired, f.path))
				helpers.assert_eq(f.codec.decode(f.read()).karabiner.runtime, source == POPULATED and "owned" or "future")
				helpers.assert_contains(f.read(), "enabled = 1.0")
			end)
		end)
	end
	helpers.it("malformed source refuses scalar repair even with matching raw bytes", function()
		local source = '[karabiner\nruntime = "owned"\n'
		with_file(source, function(f)
			helpers.assert_eq(f.config.save_runtime("shared", f.path, f.source), false)
			helpers.assert_eq(f.read(), source)
			helpers.assert_eq(f.controls.writes, 0)
		end)
	end)
end)

return true
