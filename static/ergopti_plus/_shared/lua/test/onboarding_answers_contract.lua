--- _shared/lua/test/onboarding_answers_contract.lua

--- ==============================================================================
--- MODULE: Onboarding Answers Contract
--- DESCRIPTION:
--- What every Lua host of the first-run wizard must keep, registered once per
--- driver suite so the macOS runner (Lua 5.4) and the Linux runner (LuaJIT in
--- CI) both prove it against their own generated manifest: the catalogue names
--- only this driver's configuration paths, the finish payload becomes manifest
--- rows or is refused whole, and the commit writes one versioned batch.
---
--- USAGE (one call per driver suite):
---   require("test.onboarding_answers_contract").register(helpers, { driver = "macos" })
--- ==============================================================================

local M = {}

local Answers    = require("onboarding_answers")
local TomlCodec  = require("toml_codec")
local TomlWriter = require("toml_codec.writer")

local _sequence = 0





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
				helpers.assert_true(Manifest.has_default(path), path .. " is declared for " .. driver)
				local neutral = Manifest.default_for(path)
				helpers.assert_eq(entry.default, neutral, path .. " keeps the manifest's neutral value")
				if entry.kind == "choice" then
					helpers.assert_eq(type(entry.value), type(neutral), path .. " imports a value of its type")
				end
			end
			helpers.assert_true(count > 20, "the catalogue lists this driver's wizard paths")
			helpers.assert_eq(#index.pages, 7, "one page per configuration scope")
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
