--- tests/unit/platform/remap/test_runtime_publication_receipt.lua

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

helpers.describe("native runtime admission and inverse custody", function()
	helpers.it("replaced advertised publisher cannot acknowledge original native publication", function()
		with_file(POPULATED, function(f)
			local original = f.files.write_if_unchanged_admitted
			f.files.write_if_unchanged_admitted = function() return true end
			local saved = f.config.save_runtime("shared", f.path, f.source, function() return true end)
			f.files.write_if_unchanged_admitted = original
			helpers.assert_eq(saved, false)
			helpers.assert_eq(f.read(), POPULATED)
		end)
	end)
	helpers.it("late admission replacing publisher refuses before actual rename", function()
		with_file(POPULATED, function(f)
			local original = f.files.write_if_unchanged_admitted
			local saved = f.config.save_runtime("shared", f.path, f.source, function()
				f.files.write_if_unchanged_admitted = function() return true end
				return true
			end)
			f.files.write_if_unchanged_admitted = original
			helpers.assert_eq(saved, false)
			helpers.assert_eq(f.read(), POPULATED)
		end)
	end)
	helpers.it("actual settled publication retains exact inverse owner until rollback", function()
		with_file(POPULATED, function(f)
			local saved, _, owner = f.config.save_runtime("shared", f.path, f.source, function() return true end)
			helpers.assert_eq(saved, true)
			helpers.assert_true(owner.pending())
			helpers.assert_nil(f.codec.decode(f.read()).karabiner.runtime)
			assert_neighbors(f)
			helpers.assert_eq(owner.retry_restore(function() return true end), true)
			helpers.assert_eq(f.read(), POPULATED)
			helpers.assert_eq(owner.pending(), false)
		end)
	end)
	helpers.it("false inverse admission preserves candidate and retained debt", function()
		with_file(POPULATED, function(f)
			local saved, _, owner = f.config.save_runtime("shared", f.path, f.source, function() return true end)
			helpers.assert_eq(saved, true)
			local candidate = f.read()
			helpers.assert_eq(owner.retry_restore(function() return false end), false)
			helpers.assert_eq(f.read(), candidate)
			helpers.assert_true(owner.pending())
			helpers.assert_eq(owner.retry_restore(function() return true end), true)
			helpers.assert_eq(f.read(), POPULATED)
		end)
	end)
	helpers.it("rollback refuses a concurrent writer and retains exact owner", function()
		with_file(POPULATED, function(f)
			local saved, _, owner = f.config.save_runtime("shared", f.path, f.source, function() return true end)
			helpers.assert_eq(saved, true)
			local foreign = '[future]\nrevision = 42\n'
			f.write(foreign)
			helpers.assert_eq(owner.retry_restore(function() return true end), false)
			helpers.assert_eq(f.read(), foreign)
			helpers.assert_true(owner.pending())
		end)
	end)
	helpers.it("foreign published adapter refuses rollback without invoking fake port", function()
		with_file(POPULATED, function(f)
			local saved, _, owner = f.config.save_runtime("shared", f.path, f.source, function() return true end)
			helpers.assert_eq(saved, true)
			local candidate, original, calls = f.read(), package.loaded["adapters.file_system"], 0
			package.loaded["adapters.file_system"] = { write_if_unchanged_admitted = function() calls = calls + 1; return true end }
			local restored = owner.retry_restore(function() return true end)
			package.loaded["adapters.file_system"] = original
			helpers.assert_eq(restored, false)
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(f.read(), candidate)
			helpers.assert_true(owner.pending())
		end)
	end)
	helpers.it("public receipt mutation cannot replace hidden candidate or inverse bytes", function()
		with_file(POPULATED, function(f)
			local saved, _, owner = f.config.save_runtime("shared", f.path, f.source, function() return true end)
			helpers.assert_eq(saved, true)
			local original_inverse = owner.retry_restore
			local candidate_status, candidate_error = pcall(function() owner.candidate = "foreign" end)
			helpers.assert_eq(candidate_status, false)
			helpers.assert_eq(type(candidate_error), "string")
			helpers.assert_eq(candidate_error:match(":%d+: (.*)$"), "runtime publication receipts are immutable")
			helpers.assert_nil(owner.candidate)
			helpers.assert_eq(owner.retry_restore, original_inverse)
			local inverse_status, inverse_error = pcall(function() owner.retry_restore = function() return true end end)
			helpers.assert_eq(inverse_status, false)
			helpers.assert_eq(type(inverse_error), "string")
			helpers.assert_eq(inverse_error:match(":%d+: (.*)$"), "runtime publication receipts are immutable")
			helpers.assert_eq(owner.retry_restore, original_inverse)
			helpers.assert_nil(owner.source)
			helpers.assert_eq(owner.retry_restore(function() return true end), true)
			helpers.assert_eq(f.read(), POPULATED)
		end)
	end)
	helpers.it("published absence inverse removes only its own exact candidate", function()
		with_file(nil, function(f)
			local saved, _, owner = f.config.save_runtime("owned", f.path, f.source, function() return true end)
			helpers.assert_eq(saved, true)
			helpers.assert_eq(owner.retry_restore(function() return false end), false)
			helpers.assert_true(f.read() ~= nil)
			helpers.assert_eq(owner.retry_restore(function() return true end), true)
			helpers.assert_nil(f.read())
			helpers.assert_eq(owner.pending(), false)
		end)
	end)
end)
return true
