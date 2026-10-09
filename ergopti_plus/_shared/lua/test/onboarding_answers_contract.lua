--- _shared/lua/test/onboarding_answers_contract.lua

--- ==============================================================================
--- MODULE: Onboarding Answers Contract
--- DESCRIPTION:
--- What every Lua host of the first-run wizard must keep, registered once per
--- driver suite so the macOS runner (Lua 5.4) and the Linux runner (LuaJIT in
--- CI) both prove it against their own generated manifest: the catalogue names
--- only this driver's configuration paths and tap-hold keys, the finish payload
--- becomes manifest rows and keys to import or is refused whole, and the commit
--- writes one versioned batch.
---
--- USAGE (one call per driver suite):
---   require("test.onboarding_answers_contract").register(helpers, { driver = "macos" })
--- ==============================================================================

local M = {}

local Answers    = require("onboarding_answers")
local TomlCodec  = require("toml_codec")
local TomlWriter = require("toml_codec.writer")

local _sequence = 0

-- The tap-hold catalogue column of each Lua host.
local TAP_HOLD_PLATFORM = { macos = "hs", linux = "linux" }





-- ===============================
-- ===============================
-- ======= 1/ Fixtures ===========
-- ===============================
-- ===============================

--- The generated catalogue text, read through the driver's own path owner.
--- @return string
local function catalogue_text()
	local path = require("infra.paths").shared(Answers.CATALOGUE_PATH)
	local fh = assert(io.open(path, "r"), "the onboarding catalogue is missing: " .. tostring(path))
	local text = fh:read("*a")
	fh:close()
	return text
end

--- A fresh absolute config path inside the host's scratch directory.
--- @return string
local function new_config_path()
	local base = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
	base = base:gsub("\\", "/"):gsub("/+$", "")
	_sequence = _sequence + 1
	return string.format("%s/ergopti_onboarding_%d_%d_%d.toml", base, os.time(),
		math.random(100000, 999999), _sequence)
end

local function read_bytes(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Every page of the index with the given id.
--- @param index table
--- @param id string
--- @return table
local function page(index, id)
	for _, candidate in ipairs(index.pages) do
		if candidate.id == id then return candidate end
	end
	error("no onboarding page " .. id)
end

--- The first checklist item of a page.
--- @param described table
--- @return table
local function first_item(described)
	local function walk(groups)
		for _, group in ipairs(groups or {}) do
			if group.items and group.items[1] then return group.items[1] end
			local found = walk(group.groups)
			if found then return found end
		end
	end
	return assert(walk(described.groups), "page " .. described.id .. " lists no item")
end

--- The row the writer receives for a path.
--- @param rows table
--- @param path string
--- @return table|nil
local function row_for(rows, path)
	local section, key = path:match("^(.*)%.([^%.]+)$")
	for _, row in ipairs(rows) do
		if row.section == section and row.key == key then return row end
	end
	return nil
end





-- ===============================
-- ===============================
-- ======= 2/ Contract ===========
-- ===============================
-- ===============================

--- Registers the contract with a driver suite.
--- @param helpers table The suite's helpers.
--- @param opts table `{ driver = "macos" | "linux" }`.
function M.register(helpers, opts)
	local driver = assert(opts and opts.driver, "the contract needs the driver name")
	local Manifest = require("infra.manifest_reader")
	local index = Answers.load(catalogue_text(), driver)
	-- The catalogue offers the trigger choice only where config.toml owns it.
	local trigger = index.entries["hotstrings.trigger_char"] and "hotstrings.trigger_char" or nil

	helpers.describe("onboarding answers (" .. driver .. ")", function()
		helpers.it("names only this driver's configuration paths, with their neutral values", function()
			local count = 0
			for path, entry in pairs(index.entries) do
				count = count + 1
				-- A tap-hold key is no configuration path: the next case pins it.
				if entry.kind ~= "tap_hold_key" then
					helpers.assert_true(Manifest.has_default(path), path .. " is declared for " .. driver)
					local neutral = Manifest.default_for(path)
					helpers.assert_eq(entry.default, neutral, path .. " keeps the manifest's neutral value")
					if entry.kind == "choice" then
						helpers.assert_eq(type(entry.value), type(neutral), path .. " imports a value of its type")
					end
				end
			end
			helpers.assert_true(count > 20, "the catalogue lists this driver's wizard paths")
			helpers.assert_eq(#index.pages, 7, "one page per configuration scope")
		end)

		helpers.it("names this engine's tap-hold keys, never as configuration paths", function()
			local catalogue = require("tap_hold.key_catalog").load(
				require("infra.paths").shared("tap_hold/defaults.toml"), TAP_HOLD_PLATFORM[driver])
			local engine_keys = {}
			for _, key in ipairs(catalogue) do engine_keys[key.id] = true end
			local count = 0
			for path, entry in pairs(index.entries) do
				if entry.kind == "tap_hold_key" then
					count = count + 1
					helpers.assert_eq(path, "tap_holds.keys." .. entry.key)
					helpers.assert_true(engine_keys[entry.key] == true, entry.key .. " is a key of this engine")
					helpers.assert_true(not Manifest.has_default(path), path .. " must never read as config.toml")
					helpers.assert_eq(entry.value, true)
					helpers.assert_eq(entry.default, false)
					helpers.assert_eq(entry.customised, "customised")
				end
			end
			helpers.assert_true(count >= 7, "the Tap-Holds page lists the recommended keys")
			helpers.assert_eq(index.tap_hold_state, { path = "tap_holds.enabled", default = false },
				"the page starts from the switch this host keeps in its own file")
		end)

		-- The Windows Shortcuts page writes the key-combinations switch its master
		-- no longer reaches; a Lua host must accept the same catalogue shape.
		helpers.it("claims a page's sub-switch as a switch the answer writes", function()
			local synthetic = Answers.load('{"schema_version":1,"platforms":{"' .. driver .. '":{"pages":['
				.. '{"id":"llm","master":{"path":"llm.enabled","default":false},'
				.. '"sub_switch":{"path":"gestures.enabled","default":false,"items":[]},"groups":[]}]}}}', driver)
			helpers.assert_eq(synthetic.entries["gestures.enabled"].kind, "switch")
			local rows = assert(Answers.rows(synthetic, { { path = "gestures.enabled", value = true } }, Manifest))
			helpers.assert_eq(rows[1].value, true)
			local refused, why = Answers.rows(synthetic, { { path = "gestures.enabled", value = "on" } }, Manifest)
			helpers.assert_nil(refused)
			helpers.assert_contains(tostring(why), "true or false")
		end)

		helpers.it("routes a checked tap-hold key to the tap-hold writer, never to config.toml", function()
			local tap_holds = page(index, "tap_holds")
			local first, second = tap_holds.groups[1].items[1], tap_holds.groups[1].items[2]
			local master = page(index, "gestures").master.path
			local operations = {
				{ path = first.path, value = true },
				{ path = master, value = true },
				{ path = second.path, value = false },
			}
			local rows = assert(Answers.rows(index, operations, Manifest))
			helpers.assert_eq(#rows, 1, "only the configuration answer is a row")
			helpers.assert_eq(row_for(rows, master).value, true)
			helpers.assert_eq(assert(Answers.tap_hold_keys(index, operations, Manifest)), { first.tap_hold_key },
				"a checked key is imported, an unchecked one is not written at all")
			helpers.assert_eq(assert(Answers.tap_hold_keys(index, { { path = master, value = false } }, Manifest)), {},
				"a payload without the page imports nothing")
			local keys, why = Answers.tap_hold_keys(index, { { path = first.path, value = "yes" } }, Manifest)
			helpers.assert_nil(keys, "a key takes its recommendation or its neutral value")
			helpers.assert_contains(tostring(why), "recommendation")
			keys, why = Answers.tap_hold_keys(index,
				{ { path = first.path, value = true }, { path = "script.log_level", value = "DEBUG" } }, Manifest)
			helpers.assert_nil(keys, "a refused payload imports no key either")
			helpers.assert_contains(tostring(why), "no wizard path")
			local values = Answers.current_values(index, { tap_holds = { keys = { [first.tap_hold_key] = true } } })
			helpers.assert_nil(values[first.path], "a tap-hold key is never read back from config.toml")
			local refused = Answers.rows(index, { { path = first.path, value = first.customised_value } }, Manifest)
			helpers.assert_nil(refused, "the customised marker is shown, never answered")
		end)

		-- A re-run answered Yes imported over the user's own keys: the page only
		-- keeps them if the host says which keys are configured, and how.
		helpers.it("reports the tap-hold keys and switch the tap-hold owner reads", function()
			local items = {}
			for _, group in ipairs(page(index, "tap_holds").groups) do
				for _, item in ipairs(group.items) do items[#items + 1] = item end
			end
			local imported, customised = items[1], items[2]
			local values = Answers.tap_hold_values(index, { enabled = true, keys = {
				[imported.tap_hold_key] = "recommended", [customised.tap_hold_key] = "customised",
			} })
			helpers.assert_eq(values, {
				[imported.path] = true,
				[customised.path] = "customised",
				["tap_holds.enabled"] = true,
			}, "an imported key reads as on, a customised one as kept, the switch as in force")
			helpers.assert_eq(Answers.tap_hold_values(index, { enabled = false, keys = {} }), {},
				"a folder without tap-holds reports nothing, as a neutral page")
			helpers.assert_throws(function()
				Answers.tap_hold_values(index, { keys = { [imported.tap_hold_key] = "half" } })
			end)
		end)

		helpers.it("turns declined and accepted answers into sparse manifest rows", function()
			local gestures = page(index, "gestures")
			local item = first_item(page(index, "shortcuts"))
			local rows = assert(Answers.rows(index, {
				{ path = gestures.master.path, value = false },
				{ path = item.path, value = item.value },
			}, Manifest))
			helpers.assert_eq(#rows, 2)
			helpers.assert_eq(row_for(rows, gestures.master.path).delete, true,
				"declining a category removes its switch")
			local imported = row_for(rows, item.path)
			helpers.assert_eq(imported.value, item.value, "an accepted item writes its recommendation")
			helpers.assert_eq(imported.delete, nil)
			local enabled = assert(Answers.rows(index, { { path = gestures.master.path, value = true } }, Manifest))
			helpers.assert_eq(enabled[1].value, true)
		end)

		helpers.it("refuses the whole batch on any answer outside the catalogue", function()
			local master = page(index, "gestures").master.path
			local item = first_item(page(index, "shortcuts"))
			local cases = {
				{ nil, "no operations" },
				{ { { path = "script.log_level", value = "DEBUG" } }, "no wizard path" },
				{ { { path = master, value = "yes" } }, "true or false" },
				{ { { path = master, value = true }, { path = master, value = false } }, "twice" },
				{ { { path = item.path, value = "surprise" } }, "recommendation" },
				{ { [2] = { path = master, value = true } }, "not a list" },
				{ { "gestures.enabled" }, "not a table" },
			}
			if trigger then
				cases[#cases + 1] = { { { path = trigger, value = "" } }, "visible text" }
				cases[#cases + 1] = { { { path = trigger, value = "ab" } }, "at most 1" }
				cases[#cases + 1] = { { { path = trigger, value = "a\nb" } }, "visible text" }
			else
				cases[#cases + 1] = { { { path = "hotstrings.trigger_char", value = "§" } }, "no wizard path" }
			end
			for _, case in ipairs(cases) do
				local rows, why = Answers.rows(index, case[1], Manifest)
				helpers.assert_nil(rows, case[2])
				helpers.assert_contains(tostring(why), case[2])
			end
			if trigger then
				local star = assert(Answers.rows(index, { { path = trigger, value = "§" } }, Manifest))
				helpers.assert_eq(star[1].value, "§", "a multi-byte trigger character is one character")
			end
		end)


		for _, case in ipairs({
			{ name = "overlong zero", value = string.char(0xE0, 0x80, 0x80) },
			{ name = "UTF-16 surrogate", value = string.char(0xED, 0xA0, 0x80) },
			{ name = "above Unicode limit", value = string.char(0xF4, 0x90, 0x80, 0x80) },
		}) do
			helpers.it("refuses malformed trigger scalar " .. case.name .. " before publication", function()
				local prepared, written = 0, 0
				local operations = { { path = "hotstrings.trigger_char", value = case.value } }
				local committed = Answers.commit({
					index = index, manifest = Manifest, path = "/unpublished-wizard-utf8-control.toml",
					operations = operations,
					prepare = function() prepared = prepared + 1; return true end,
					write = function() written = written + 1; return true end,
				})
				helpers.assert_eq(committed, false, "malformed UTF-8 cannot reach an acknowledged write")
				helpers.assert_eq(prepared, 0, "refusal precedes preparation")
				helpers.assert_eq(written, 0, "refusal precedes publication")
				local rows = Answers.rows(index, operations, Manifest)
				helpers.assert_nil(rows, "the same actual planner rejects the malformed scalar")
			end)
		end

		helpers.it("keeps valid BMP and non-BMP trigger scalars unchanged", function()
			for _, value in ipairs({ "§", "←", "🦀" }) do
				local rows = assert(Answers.rows(index, { { path = "hotstrings.trigger_char", value = value } }, Manifest))
				helpers.assert_eq(rows[1].value, value, "one valid Unicode scalar retains exact bytes")
			end
			local ordinary, why = Answers.rows(index, { { path = "hotstrings.trigger_char", value = "a" } }, Manifest)
			if driver == "linux" then
				helpers.assert_nil(ordinary, "Linux still refuses prose characters through its rare-symbol policy")
				helpers.assert_contains(tostring(why), "refused")
			else
				helpers.assert_eq(assert(ordinary)[1].value, "a", "macOS keeps its existing common-character capability")
			end
		end)

		helpers.it("writes one versioned batch and never writes a refused one", function()
			local path = new_config_path()
			local writes, prepared = 0, {}
			local ok, err = pcall(function()
				local master = page(index, "llm").master.path
				local committed, why = Answers.commit({
					index = index, manifest = Manifest, path = path,
					operations = { { path = "not.a.path", value = true } },
					prepare = function(target) prepared[#prepared + 1] = target; return true end,
					write = function() writes = writes + 1; return true end,
				})
				helpers.assert_eq(committed, false)
				helpers.assert_contains(why, "no wizard path")
				helpers.assert_eq(writes, 0, "a refused batch writes nothing")
				helpers.assert_eq(#prepared, 0, "nor versions the destination")

				committed, why = Answers.commit({
					index = index, manifest = Manifest, path = path,
					operations = { { path = master, value = true } },
					prepare = function() return false, "newer schema" end,
					write = function() writes = writes + 1; return true end,
				})
				helpers.assert_eq(committed, false)
				helpers.assert_contains(why, "newer schema")
				helpers.assert_eq(writes, 0, "an unversionable destination is never written")

				committed, why = Answers.commit({
					index = index, manifest = Manifest, path = path,
					operations = { { path = master, value = true } },
					prepare = function(target)
						TomlWriter.set_create_rows(target, { { section = "_meta", key = "schema_version", value = 7 } })
						return true
					end,
					write = function(target, rows) return TomlWriter.batch_write(target, rows) end,
				})
				helpers.assert_eq(committed, true, tostring(why))
				local decoded = TomlCodec.decode(assert(read_bytes(path)))
				helpers.assert_eq(decoded._meta.schema_version, 7, "the created file carries the schema version")
				helpers.assert_eq(decoded.llm.enabled, true)

				committed = Answers.commit({
					index = index, manifest = Manifest, path = path,
					operations = { { path = master, value = false } },
					prepare = function() return true end,
					write = function(target, rows) return TomlWriter.batch_write(target, rows) end,
				})
				helpers.assert_eq(committed, true)
				decoded = TomlCodec.decode(assert(read_bytes(path)))
				helpers.assert_nil((decoded.llm or {}).enabled, "a declined switch leaves no key behind")
				helpers.assert_eq(decoded._meta.schema_version, 7)

				committed, why = Answers.commit({
					index = index, manifest = Manifest, path = path,
					operations = { { path = master, value = true } },
					prepare = function() return true end,
					write = function() return false, "disk full" end,
				})
				helpers.assert_eq(committed, false)
				helpers.assert_eq(why, "disk full", "a failed write is reported, never success")
			end)
			os.remove(path)
			os.remove(path .. ".tmp")
			if not ok then error(err, 0) end
		end)

		helpers.it("reads the values in force by the same paths", function()
			local master = page(index, "gestures").master.path
			local decoded = TomlCodec.decode(table.concat({
				"[gestures]", "enabled = true", "[hotstrings]", 'trigger_char = "ù"',
				"[script]", 'log_level = "DEBUG"', "",
			}, "\n"))
			local values = Answers.current_values(index, decoded)
			helpers.assert_eq(values[master], true)
			helpers.assert_eq(values["hotstrings.trigger_char"], trigger and "ù" or nil,
				"the trigger is read back only where the wizard asks for it")
			helpers.assert_nil(values["script.log_level"], "a path the wizard does not own is not reported")
			helpers.assert_nil(values[page(index, "llm").master.path], "an absent key keeps its neutral value")
		end)
	end)
end

return M
