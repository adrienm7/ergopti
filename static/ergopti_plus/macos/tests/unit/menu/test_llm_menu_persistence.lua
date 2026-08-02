--- tests/unit/menu/test_llm_menu_persistence.lua

--- ==============================================================================
--- MODULE: LLM Menu Persistence Tests (Hammerspoon)
--- DESCRIPTION:
--- Ensures every LLM menu setting mapped in infra/preferences.lua is written
--- to config.toml and read back. Contract: _shared/modules/llm/menu_persistence_contract.json
--- ==============================================================================

local helpers = require("tests.helpers")
local prefs   = helpers.load_with_stubs("infra.preferences")
local codec   = helpers.load_with_stubs("infra.toml.codec")

local function contract_path()
	return helpers.shared("modules/llm/menu_persistence_contract.json")
end

local function load_contract()
	local fh = io.open(contract_path(), "r")
	if not fh then
		error("menu_persistence_contract.json not found at " .. contract_path())
	end
	local raw = fh:read("*a")
	fh:close()
	local ok, data = pcall(hs.json.decode, raw)
	if not ok or type(data) ~= "table" or type(data.entries) ~= "table" then
		error("invalid menu_persistence_contract.json")
	end
	return data.entries
end

local function preferences_source()
	return helpers.driver_root() .. "infra/preferences.lua"
end

local function deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not deep_equal(v, b[k]) then return false end
	end
	for k, v in pairs(b) do
		if not deep_equal(v, a[k]) then return false end
	end
	return true
end

local function normalize_toml_array(v)
	if type(v) == "table" then
		local out = {}
		for i = 1, #v do
			if v[i] ~= nil then out[#out + 1] = tostring(v[i]) end
		end
		if #out > 0 then return out end
		for _, val in pairs(v) do
			out[#out + 1] = tostring(val)
		end
		table.sort(out)
		return out
	end
	if type(v) == "string" and v:match("^%[") then
		local inner = v:match("^%[(.*)%]$") or ""
		local out = {}
		for part in inner:gmatch("[^,]+") do
			part = part:gsub('^%s*"?', ""):gsub('"?%s*$', "")
			if part ~= "" then out[#out + 1] = part end
		end
		table.sort(out)
		return out
	end
	return v
end

local function array_signature(v)
	local arr = normalize_toml_array(v)
	if type(arr) ~= "table" then return tostring(arr) end
	return table.concat(arr, ",")
end

local function shortcut_signature(v)
	if type(v) ~= "table" then return tostring(v) end
	local mods = normalize_toml_array(v.mods or {})
	local key  = tostring(v.key or "")
	return table.concat(mods, "+") .. "|" .. key
end

local function values_equal(expected, actual, entry)
	if entry.toml_array then
		return array_signature(expected) == array_signature(actual)
	end
	if entry.id == "trigger_shortcut" then
		return shortcut_signature(expected) == shortcut_signature(actual)
	end
	if type(expected) == "number" and type(actual) == "number" then
		return math.abs(expected - actual) < 1e-6
	end
	return deep_equal(expected, actual)
end

--- Walk grouped TOML (decode output) to a leaf value.
local function grouped_get(grouped, hs)
	if hs.persist == "nested" and hs.nested_key then
		local t = grouped[hs.section]
		if type(t) ~= "table" then return nil end
		for part in hs.nested_key:gmatch("[^%.]+") do
			t = t and t[part]
		end
		return t
	end
	local sec = grouped[hs.section]
	if type(sec) ~= "table" then return nil end
	if hs.path then
		local sub = sec[hs.path]
		if type(sub) ~= "table" then return nil end
		return sub[hs.key]
	end
	return sec[hs.key]
end

helpers.describe("LLM menu persistence contract", function()
	helpers.it("loads the shared JSON contract", function()
		local entries = load_contract()
		helpers.assert_true(#entries >= 20, "expected a full menu contract")
	end)
end)

helpers.describe("LLM menu persistence — preferences.lua wiring", function()
	helpers.it("maps every HS contract flat_key through KEY_MAP or NESTED_KEY_MAP", function()
		local fh = io.open(preferences_source(), "r")
		helpers.assert_true(fh ~= nil, "preferences.lua not found")
		local body = fh:read("*a")
		fh:close()
		for _, entry in ipairs(load_contract()) do
			local hs = entry.hs
			if type(hs) ~= "table" or not hs.flat_key then
				goto continue
			end
			local fk = hs.flat_key
			helpers.assert_true(
				body:find('"' .. fk .. '"', 1, true) or body:find(fk .. " ", 1, true),
				"preferences.lua must reference " .. fk .. " (" .. entry.id .. ")"
			)
			::continue::
		end
	end)
end)

helpers.describe("LLM menu persistence — disk round-trip", function()
	for _, entry in ipairs(load_contract()) do
		local hs = entry.hs
		if type(hs) ~= "table" or not hs.flat_key then
			goto next_entry
		end

		local label = entry.id
		helpers.it("round-trips " .. label .. " through preferences.save/load", function()
			local tmp = helpers.fixtures_dir() .. "llm_persist_" .. label .. ".toml"
			os.remove(tmp)

			local state = {}
			state[hs.flat_key] = hs.sample

			prefs.save(tmp, state, {}, {})
			local flat = prefs.load(tmp)

			local got = flat[hs.flat_key]
			local flat_ok = values_equal(hs.sample, got, hs)
			if not flat_ok and got == nil and hs and hs.persist == "nested" then
				flat_ok = true
			end
			helpers.assert_true(
				flat_ok,
				label .. " flat load mismatch (got "
					.. tostring(got) .. ")"
			)

			local fh = io.open(tmp, "r")
			helpers.assert_true(fh ~= nil, label .. " config file missing")
			local content = fh:read("*a")
			fh:close()
			local ok, grouped = pcall(codec.decode, content)
			helpers.assert_true(ok, label .. " TOML decode failed")
			local on_disk = grouped_get(grouped, hs)
			if entry.id == "trigger_shortcut" and type(hs.sample) == "table" then
				local sc = grouped.llm and grouped.llm.trigger and grouped.llm.trigger.shortcut
				helpers.assert_true(type(sc) == "table", label .. " missing llm.trigger.shortcut table")
				on_disk = sc
			end
			helpers.assert_true(
				values_equal(hs.sample, on_disk, hs),
				label .. " grouped TOML mismatch"
			)

			os.remove(tmp)
		end)

		::next_entry::
	end
end)