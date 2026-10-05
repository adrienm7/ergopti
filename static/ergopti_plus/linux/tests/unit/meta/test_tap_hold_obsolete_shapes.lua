--- tests/unit/meta/test_tap_hold_obsolete_shapes.lua

--- ==============================================================================
--- MODULE: Tap-Hold Obsolete Source Preservation
--- DESCRIPTION:
--- Exercises the real file reader, native writer, shared codec and fresh loader.
--- Obsolete namespace records stay until manual repair; an ordinary menu action
--- or recommendation import must not erase them or acknowledge a discarded field.
--- ==============================================================================

local helpers = require("tests.helpers")
local Loader = require("platform.remap.tap_hold_loader")
local Codec = require("toml_codec")
local Outdated = require("config_outdated")
local Logger = require("logger.shim")
local LayerPreset = require("keymap.layer_preset")
local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")
local FUTURE = '\n[future]\nnote = "kept"\n'
local CASES = {
	{ name = "scalar root", text = 'tap_hold = "opaque"\n', path = "tap_hold" },
	{ name = "array root", text = 'tap_hold = []\n', path = "tap_hold" },
	{ name = "scalar keys", text = '[tap_hold]\nkeys = "opaque"\n', path = "tap_hold.keys" },
	{ name = "array keys", text = '[tap_hold]\nkeys = []\n', path = "tap_hold.keys" },
	{ name = "scalar binding", text = '[tap_hold.keys]\ncaps_lock = "opaque"\n', path = "tap_hold.keys.caps_lock" },
	{ name = "boolean binding", text = '[tap_hold.keys]\ncaps_lock = false\n', path = "tap_hold.keys.caps_lock" },
	{ name = "numeric binding", text = '[tap_hold.keys]\ncaps_lock = 7\n', path = "tap_hold.keys.caps_lock" },
	{ name = "nonempty array binding", text = '[tap_hold.keys]\ncaps_lock = [1, 2]\n', path = "tap_hold.keys.caps_lock" },
	{ name = "empty array binding", text = '[tap_hold.keys]\ncaps_lock = []\n', path = "tap_hold.keys.caps_lock" },
	{ name = "inline empty array binding", text = 'tap_hold = { keys = { caps_lock = [] } }\n', path = "tap_hold.keys.caps_lock" },
	{ name = "quoted dotted empty array binding", text = '"tap_hold"."keys"."caps_lock" = []\n', path = "tap_hold.keys.caps_lock" },
	{ name = "array of binding tables", text = '[[tap_hold.keys.caps_lock]]\ntap_action = "paste"\n', path = "tap_hold.keys.caps_lock" },
}

local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	return text
end

local function write(path, text)
	local file = assert(io.open(path, "wb"))
	assert(file:write(text))
	assert(file:close())
end

--- Binds actual owners to private real files, with an explicit reload receipt.
local function with_writer(text, body)
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute('mkdir "' .. dir .. '"')
	assert(made == true or made == 0)
	local path = dir .. "/tap_hold.toml"
	write(path, text)
	local state = { reloads = 0, receipt = true }
	local writer = helpers.load_module("platform.remap.tap_hold_writer")
	writer.init({ path = path,
		reload = function()
			state.reloads = state.reloads + 1
			if state.raises then error("controlled reload refusal") end
			return state.receipt
		end,
		is_tap_action = function(id) return id == "copy" or id == "paste" end,
		canonical_hold = function(kind, id)
			return require("tap_hold.hold_options").canonical(kind, id, Loader.load(DEFAULTS, nil).hold_picker)
		end,
		layers = { shared_root = require("infra.paths").shared_root(), config_dir = dir },
	})
	local ok, detail = pcall(body, writer, path, state, dir)
	-- Backups are private fixture state and never include a user's path.
	os.execute('rm -rf -- "' .. dir .. '"')
	if not ok then error(detail, 0) end
end

--- Observes native write/rename/layer-import boundaries without replacing them.
local function writes_during(body)
	local original_open, original_rename, original_import = io.open, os.rename, LayerPreset.import_if_absent
	local calls = { writes = 0, renames = 0, layers = 0 }
	io.open = function(path, mode, ...)
		if type(mode) == "string" and mode:find("[wa]") then calls.writes = calls.writes + 1 end
		return original_open(path, mode, ...)
	end
	os.rename = function(...)
		calls.renames = calls.renames + 1
		return original_rename(...)
	end
	LayerPreset.import_if_absent = function(...)
		calls.layers = calls.layers + 1
		return original_import(...)
	end
	local ok, detail = pcall(body, calls)
	io.open, os.rename, LayerPreset.import_if_absent = original_open, original_rename, original_import
	if not ok then error(detail, 0) end
end

helpers.describe("tap-hold obsolete source shapes", function()
	for _, case in ipairs(CASES) do
		helpers.it("refuses ordinary edits of " .. case.name .. " before native side effects and permits repaired retry", function()
			with_writer(case.text .. FUTURE, function(writer, path, state, dir)
				writes_during(function(calls)
					for _, action in ipairs({
						function() return writer.set_tap("caps_lock", "copy") end,
						function() return writer.set_native("caps_lock") end,
						function() return writer.set_threshold("caps_lock", 0.4) end,
						function() return writer.set_hold("caps_lock", "layer", "nav") end,
					}) do
						local called, accepted = pcall(action)
						helpers.assert_eq(called, true, "a known menu action must report its shape refusal")
						helpers.assert_eq(accepted, false, case.name .. " cannot be replaced or silently discarded")
						helpers.assert_eq(read(path), case.text .. FUTURE, "refusal retains complete handwritten source")
					end
					helpers.assert_eq(calls, { writes = 0, renames = 0, layers = 0 }, "admission precedes staging/import")
				end)
				helpers.assert_eq(state.reloads, 0)
				helpers.assert_nil(read(path .. ".tmp"))
				helpers.assert_nil(read(dir .. "/layers.toml"))
				write(path, '[tap_hold.keys.caps_lock]\nfuture = "keep"\n' .. FUTURE)
				helpers.assert_eq(writer.set_tap("caps_lock", "copy"), true, "same captured writer accepts explicit manual repair")
				helpers.assert_eq(state.reloads, 1)
				helpers.assert_eq(Loader.load(DEFAULTS, path).keys.caps_lock.tap_action, "copy")
				helpers.assert_eq(Codec.decode(read(path)).tap_hold.keys.caps_lock.future, "keep")
			end)
		end)
		helpers.it("warns once and reads " .. case.name .. " as absent through the actual loader", function()
			with_writer(case.text .. FUTURE, function(writer, path)
				local warnings, errors = {}, {}
				local original_warn, original_error = Logger.warn, Logger.error
				Logger.warn = function(_, format, ...) warnings[#warnings + 1] = string.format(format, ...) end
				Logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
				Outdated.reset_for_tests()
				local ok, detail = pcall(function()
					for _ = 1, 2 do
						local loaded = Loader.load(DEFAULTS, path)
						helpers.assert_nil(loaded.user_error)
						helpers.assert_nil(loaded.keys.caps_lock)
						helpers.assert_eq(loaded.enabled, false)
					end
					helpers.assert_eq(#warnings, 1, "one precise outdated record, including an empty array")
					helpers.assert_contains(warnings[1], "'" .. case.path .. "' in '" .. path .. "'")
					helpers.assert_contains(warnings[1], "repair the stored entry by hand")
					helpers.assert_eq(errors, {})
					helpers.assert_eq(writer.is_overridden("caps_lock"), false)
					helpers.assert_eq(Loader.key_report(DEFAULTS, path), { enabled = false, keys = {} })
					helpers.assert_eq(read(path), case.text .. FUTURE)
				end)
				Logger.warn, Logger.error = original_warn, original_error
				if not ok then error(detail, 0) end
			end)
		end)
		helpers.it("refuses whole recommendation import over " .. case.name .. " before backup or publication", function()
			with_writer(case.text .. FUTURE, function(writer, path, state)
				writes_during(function(calls)
					local called, accepted, reason, backup = pcall(writer.import_recommended, path,
						{ "left_shift", "caps_lock" }, Loader.preset_keys(DEFAULTS))
					helpers.assert_eq(called, true)
					helpers.assert_eq(accepted, false)
					helpers.assert_type(reason, "string")
					helpers.assert_contains(reason, case.path)
					helpers.assert_nil(backup)
					helpers.assert_eq(calls, { writes = 0, renames = 0, layers = 0 })
				end)
				helpers.assert_eq(read(path), case.text .. FUTURE)
				helpers.assert_eq(state.reloads, 0)
			end)
		end)
	end

	for _, literal in ipairs({ '"opaque"', 'false', '7', '1.23456789012345', '1.2345678901234567', '-1.23456789012345e-120', '9007199254740993', '9223372036854775807', '1.0', '1.2345678901234567e+42', '9_223_372_036_854_775_807', '[]', '[1, 2]', '[{ future = [] }]' }) do
		helpers.it("preserves untouched obsolete binding " .. literal .. " and future arrays during unrelated save", function()
			with_writer('[tap_hold.keys]\ncaps_lock = ' .. literal .. '\nretired_key = []\n'
				.. '[future]\nempty = []\nrecords = [{ empty = [], nested = [[], { note = "yes" }] }]\n', function(writer, path)
				helpers.assert_eq(writer.set_tap("left_shift", "copy"), true)
				local bytes = read(path)
				if literal:match("^[%d%-+]") then
					helpers.assert_true(bytes:find("caps_lock = " .. literal .. "\n", 1, true) ~= nil, "unchanged numeric source token keeps precision and TOML kind")
				end
				local model = Codec.decode(bytes)
				helpers.assert_eq(model.tap_hold.keys.caps_lock, Codec.decode('value = ' .. literal).value)
				helpers.assert_true(bytes:find("retired_key = []", 1, true) ~= nil, "empty foreign arrays retain physical identity")
				helpers.assert_true(bytes:find("empty = []", 1, true) ~= nil)
				helpers.assert_eq(model.future.records[1].nested[2].note, "yes", "array maps never lose named fields")
				helpers.assert_eq(Loader.load(DEFAULTS, path).keys.left_shift.tap_action, "copy")
			end)
		end)
	end

	for _, source in ipairs({ '[tap_hold.keys.caps_lock]\n', '[tap_hold.keys]\ncaps_lock = {}\n',
		'tap_hold = { keys = { caps_lock = {} } }\n' }) do
		helpers.it("admits a genuinely empty table without confusing it with an empty array: " .. source, function()
			with_writer(source .. FUTURE, function(writer, path)
				helpers.assert_eq(writer.set_tap("caps_lock", "copy"), true)
				helpers.assert_eq(Loader.load(DEFAULTS, path).keys.caps_lock.tap_action, "copy")
				helpers.assert_eq(Codec.decode(read(path)).future.note, "kept")
			end)
		end)
	end

	helpers.it("classifies wrong global Boolean leaves once and keeps them during an unrelated edit", function()
		local source = '[tap_hold]\nenabled = "old"\ninherit_defaults = 7\n' .. FUTURE
		with_writer(source, function(writer, path)
			local original_warn, warnings = Logger.warn, {}
			Logger.warn = function(_, format, ...) warnings[#warnings + 1] = string.format(format, ...) end
			Outdated.reset_for_tests()
			local ok, detail = pcall(function()
				Loader.load(DEFAULTS, path)
				helpers.assert_eq(writer.set_tap("left_shift", "copy"), true)
				local loaded = Loader.load(DEFAULTS, path)
				helpers.assert_eq(loaded.enabled, false)
				helpers.assert_eq(#warnings, 2)
				helpers.assert_contains(table.concat(warnings, "\n"), "tap_hold.enabled")
				helpers.assert_contains(table.concat(warnings, "\n"), "tap_hold.inherit_defaults")
				local stored = Codec.decode(read(path)).tap_hold
				helpers.assert_eq(stored.enabled, "old")
				helpers.assert_eq(stored.inherit_defaults, 7)
			end)
			Logger.warn = original_warn
			if not ok then error(detail, 0) end
		end)
	end)

	for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" },
		{ name = "number", value = 1 }, { name = "string", value = "yes" },
		{ name = "table", value = {} }, { name = "exception", raises = true } }) do
		helpers.it("reports persisted but unacknowledged reload " .. receipt.name .. " and retries the same writer", function()
			with_writer(FUTURE, function(writer, path, state)
				state.receipt, state.raises = receipt.value, receipt.raises
				local called, accepted = pcall(writer.set_tap, "caps_lock", "copy")
				helpers.assert_eq(called, true)
				helpers.assert_eq(accepted, false, "only exact true acknowledges native reload")
				helpers.assert_eq(state.reloads, 1)
				helpers.assert_eq(Loader.load(DEFAULTS, path).keys.caps_lock.tap_action, "copy", "saved is distinct from in force")
				state.receipt, state.raises = true, false
				helpers.assert_eq(writer.set_tap("caps_lock", "paste"), true)
				helpers.assert_eq(state.reloads, 2)
				helpers.assert_eq(Loader.load(DEFAULTS, path).keys.caps_lock.tap_action, "paste")
			end)
		end)
	end
end)

helpers.describe("tap-hold exact-source publication", function()
	for _, kind in ipairs({ "ordinary", "import" }) do
		helpers.it("preserves a native source edit after staging during " .. kind, function()
			local original = '[tap_hold.keys.caps_lock]\nfuture = "old"\n'
			with_writer(original, function(writer, path, state)
				local real_open, real_rename = io.open, os.rename
				local staged, publications = 0, 0
				local external = '# newer editor bytes\n[tap_hold.keys.caps_lock]\nfuture = "new"\n'
				io.open = function(candidate, mode, ...)
					local file = real_open(candidate, mode, ...)
					if candidate ~= path .. ".tmp" or mode ~= "w" or not file then return file end
					staged = staged + 1
					return {
						write = function(self, content) assert(file:write(content)); return self end,
						close = function()
							assert(file:close())
							local editor = assert(real_open(path, "wb"))
							assert(editor:write(external)); assert(editor:close())
							return true
						end,
					}
				end
				os.rename = function(...)
					publications = publications + 1
					return real_rename(...)
				end
				local called, accepted = pcall(function()
					if kind == "import" then
						return writer.import_recommended(path, { "caps_lock" }, Loader.preset_keys(DEFAULTS))
					end
					return writer.set_tap("caps_lock", "copy")
				end)
				io.open, os.rename = real_open, real_rename
				helpers.assert_eq(called, true)
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(staged, 1, "the race follows an actual staged candidate")
				helpers.assert_eq(publications, 0)
				helpers.assert_eq(read(path), external, "the later editor retains complete source ownership")
				helpers.assert_nil(read(path .. ".tmp"))
				helpers.assert_eq(state.reloads, 0)
				helpers.assert_eq(writer.set_tap("caps_lock", "copy"), true, "retry reads the current source")
				helpers.assert_eq(Codec.decode(read(path)).tap_hold.keys.caps_lock.future, "new")
			end)
		end)
	end

	helpers.it("imports a healthy target while carrying an unselected empty-array binding unchanged", function()
		local source = '[tap_hold.keys]\ncaps_lock = []\n' .. FUTURE
		with_writer(source, function(writer, path, state)
			local accepted, detail, backup = writer.import_recommended(path, { "left_shift" }, Loader.preset_keys(DEFAULTS))
			helpers.assert_eq(accepted, true, detail)
			helpers.assert_eq(read(backup), source)
			helpers.assert_eq(state.reloads, 0, "the wizard import still relies on its later daemon restart")
			helpers.assert_true(read(path):find("caps_lock = []", 1, true) ~= nil)
			local loaded = Loader.load(DEFAULTS, path)
			helpers.assert_nil(loaded.keys.caps_lock)
			helpers.assert_eq(loaded.keys.left_shift.tap_action, "copy")
			helpers.assert_eq(loaded.enabled, true)
		end)
	end)
end)

helpers.describe("tap-hold untouched numeric source values", function()
	for _, operation in ipairs({ "ordinary", "import" }) do
		helpers.it("retains high-precision scalar and nested numeric values during " .. operation, function()
			local source = '[tap_hold.keys]\ncaps_lock = 1.23456789012345\n'
				.. '[future]\nscalar = 1.2345678901234567\n'
				.. 'values = [0.12345678901234566, { small = -1.23456789012345e-120, integer = 9007199254740993, empty = [] }]\n'
			with_writer(source, function(writer, path, state)
				local original = Codec.decode(source)
				if operation == "ordinary" then
					helpers.assert_eq(writer.set_enabled(true), true)
				else
					local accepted, reason, backup = writer.import_recommended(path, { "left_shift" }, Loader.preset_keys(DEFAULTS))
					helpers.assert_eq(accepted, true, reason)
					helpers.assert_eq(read(backup), source)
				end
				local stored = Codec.decode(read(path))
				helpers.assert_eq(stored.tap_hold.keys.caps_lock, 1.23456789012345)
				helpers.assert_eq(stored.future.scalar, 1.2345678901234567)
				helpers.assert_eq(stored.future.values[1], 0.12345678901234566)
				helpers.assert_eq(stored.future.values[2].small, -1.23456789012345e-120)
				helpers.assert_eq(stored.future.values[2].integer, 9007199254740993)
				helpers.assert_eq(stored.future, original.future, "unrelated numeric model remains exact")
				helpers.assert_true(read(path):find("empty = []", 1, true) ~= nil)
				helpers.assert_nil(Loader.load(DEFAULTS, path).keys.caps_lock)
			end)
		end)
	end
end)
