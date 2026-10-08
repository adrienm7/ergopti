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

local SOURCE_A = '[karabiner]\nruntime = "shared"\n[future]\nrevision = 1\n'
local SOURCE_B = '[karabiner]\nruntime = "shared"\n[future]\nrevision = 2\n'
local function actual_publication(f)
    local wrapped = f.files.write_if_unchanged
    local native
    for i = 1, 20 do
        local name, value = debug.getupvalue(wrapped, i)
        if not name then break end
        if name == "native" then native = value end
    end
    helpers.assert_eq(type(native), "function", "retain genuine conditional publication body")
    local calls = 0
    f.files.write_if_unchanged = function(...)
        calls = calls + 1
        return native(...)
    end
    return function() return calls end
end
helpers.describe("Independent frozen runtime input custody", function()
    helpers.it("healthy actual receipt publishes owned only", function()
        with_file(SOURCE_A, function(f)
            actual_publication(f)
            local _, _, receipt = f.config._load_toml_file(f.path)
            helpers.assert_true(f.config.save_runtime("owned", f.path, receipt))
            helpers.assert_eq(f.codec.decode(f.read()).karabiner.runtime, "owned")
            helpers.assert_eq(f.codec.decode(f.read()).future.revision, 1)
        end)
    end)
    for _, cut in ipairs({ "declaration", "read" }) do
        helpers.it("holds actual displayed source before reentrant " .. cut, function()
            with_file(SOURCE_A, function(f)
                local calls = actual_publication(f)
                local _, _, receipt = f.config._load_toml_file(f.path)
                local paths = require("infra.paths")
                local shared, read = paths.shared, f.files.read_with_status
                local changed = false
                local function replace()
                    if changed then return end
                    changed = true
                    f.write(SOURCE_B)
                    receipt.content = SOURCE_B
                end
                if cut == "declaration" then
                    paths.shared = function(relative)
                        if relative == "platform/remap/runtime_setting.json" then replace() end
                        return shared(relative)
                    end
                else
                    f.files.read_with_status = function(path)
                        if path == f.path then replace() end
                        return read(path)
                    end
                end
                local saved = f.config.save_runtime("owned", f.path, receipt)
                paths.shared, f.files.read_with_status = shared, read
                print("CAUSAL RECEIPT " .. cut .. " saved=" .. tostring(saved) .. " native_calls=" .. tostring(calls()) .. " actual_bytes=" .. f.read():gsub("\n", "|"))
                helpers.assert_true(changed, "real reentrant seam executed")
                helpers.assert_eq(saved, false, "source admission must hold the actual original receipt before ports")
                helpers.assert_eq(f.read(), SOURCE_B, "real successor must survive unchanged")
                helpers.assert_eq(calls(), 0, "stale intent must not invoke publication")
            end)
        end)
    end
    helpers.it("holds admitted declaration scalars before later read callback", function()
        with_file(SOURCE_A, function(f)
            actual_publication(f)
            local _, _, receipt = f.config._load_toml_file(f.path)
            local json = require("adapters.json_codec")
            local decode, read = json.decode, f.files.read_with_status
            local admitted
            json.decode = function(raw, ...)
                local value, err = decode(raw, ...)
                if type(value) == "table" and value.path == "karabiner.runtime" then admitted = value end
                return value, err
            end
            f.files.read_with_status = function(path)
                if path == f.path and admitted then admitted.default = "owned" end
                return read(path)
            end
            local saved = f.config.save_runtime("owned", f.path, receipt)
            json.decode, f.files.read_with_status = decode, read
            helpers.assert_eq(type(admitted), "table", "genuine declaration decoded")
            helpers.assert_eq(admitted.default, "owned", "actual borrowed-table mutation executed")
            print("CAUSAL DECLARATION saved=" .. tostring(saved) .. " actual_bytes=" .. f.read():gsub("\n", "|"))
            if saved then
                helpers.assert_eq((f.codec.decode(f.read()).karabiner or {}).runtime, "owned", "originally admitted default shared must not become owned during ports")
            else helpers.assert_eq(f.read(), SOURCE_A) end
        end)
    end)
end)
return true
