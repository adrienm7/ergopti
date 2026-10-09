--- _shared/lua/onboarding_answers.lua

--- ==============================================================================
--- MODULE: Onboarding Answers (shared)
--- DESCRIPTION:
--- The one contract between the first-run wizard page and the Lua hosts: the
--- generated catalogue (_shared/ui/_generated/onboarding_catalogue.json) says
--- which manifest paths the wizard may write on a platform, and this module
--- turns the page's finish payload into the configuration rows the shared TOML
--- writer publishes in one atomic batch, and into the tap-hold keys the host
--- imports through its own tap-hold writer.
---
--- FEATURES & RATIONALE:
--- 1. No interpretation: every answer is a manifest path and a value. A host
---    never translates a question into keys of its own. A tap-hold key is the
---    one answer that is no configuration path: no driver keeps its keys in
---    config.toml, so the catalogue names the key and the host's writer imports
---    its shipped recommendation.
--- 2. Fail-closed validation: a path outside the platform's catalogue, a value
---    the row cannot take, a duplicate or a malformed payload refuses the whole
---    batch before anything is written.
--- 3. Neutral values are deletions: the manifest reader's sparse operation
---    decides, so a declined feature leaves the file as empty as a fresh one.
--- 4. A re-run starts from the values in force, read from the decoded file by
---    the same paths, and from the tap-hold keys and switch the host's
---    tap-hold owner reports: a configured key is shown as kept, never
---    imported over.
--- ==============================================================================

local M = {}

local Json = require("json")
local Utf8 = require("compat.utf8")

-- The catalogue format this module reads; the generator emits the same number.
M.SCHEMA_VERSION = 1

-- Where the generated catalogue lives, relative to the shared tree.
M.CATALOGUE_PATH = "ui/_generated/onboarding_catalogue.json"





-- ==================================
-- ==================================
-- ======= 1/ Catalogue index =======
-- ==================================
-- ==================================

--- Structural equality over decoded JSON scalars and tables.
--- @param left any
--- @param right any
--- @return boolean
local function same(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not same(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

--- Indexes one driver's writable paths.
--- @param text string The catalogue JSON.
--- @param driver string "macos", "linux" or "windows".
--- @return table index `{ driver, pages, entries = { [path] = entry },
---   tap_hold_state = { path, default }|nil }`.
function M.load(text, driver)
	assert(type(text) == "string", "the onboarding catalogue must be text")
	local catalogue = Json.decode(text)
	assert(type(catalogue) == "table", "the onboarding catalogue is not valid JSON")
	assert(catalogue.schema_version == M.SCHEMA_VERSION, "the onboarding catalogue has an unsupported format")
	local platform = type(catalogue.platforms) == "table" and catalogue.platforms[driver] or nil
	assert(type(platform) == "table" and type(platform.pages) == "table",
		"the onboarding catalogue has no pages for " .. tostring(driver))
	local entries = {}
	local tap_hold_state = nil
	local function claim(path, entry)
		assert(type(path) == "string" and path ~= "", "the onboarding catalogue has an unnamed row")
		assert(entries[path] == nil, "the onboarding catalogue writes " .. path .. " twice")
		entries[path] = entry
	end
	local function walk(groups, page)
		for _, group in ipairs(groups or {}) do
			if group.path ~= nil then
				claim(group.path, { kind = "choice", value = group.value, default = group.default })
			end
			for _, item in ipairs(group.items or {}) do
				if item.tap_hold_key ~= nil then
					assert(type(item.tap_hold_key) == "string" and item.tap_hold_key ~= ""
						and type(item.customised_value) == "string" and item.customised_value ~= "",
						"the onboarding catalogue names a tap-hold key without an id or a customised value")
					claim(item.path, { kind = "tap_hold_key", key = item.tap_hold_key,
						value = item.value, default = item.default, customised = item.customised_value })
					if type(page.state) == "table" then tap_hold_state = page.state end
				else
					claim(item.path, { kind = "choice", value = item.value, default = item.default })
				end
			end
			walk(group.groups, page)
		end
	end
	for _, page in ipairs(platform.pages) do
		if type(page.master) == "table" then claim(page.master.path, { kind = "switch", default = false }) end
		-- A switch of part of the checklist that the master no longer reaches.
		if type(page.sub_switch) == "table" then
			claim(page.sub_switch.path, { kind = "switch", default = page.sub_switch.default })
		end
		if type(page.magic_key) == "table" then
			local limit = page.magic_key.max_characters
			assert(type(limit) == "number" and limit >= 1 and limit % 1 == 0,
				"the onboarding catalogue gives the trigger character no length limit")
			local validation = page.magic_key.validation
			assert(validation == nil or validation == "safe_magic_key",
				"the onboarding catalogue declares an unsupported trigger validation")
			claim(page.magic_key.path, { kind = "character", default = page.magic_key.default,
				max_characters = limit, validation = validation })
		end
		walk(page.groups, page)
	end
	return { driver = driver, pages = platform.pages, entries = entries, tap_hold_state = tap_hold_state }
end





-- =================================
-- =================================
-- ======= 2/ Finish payload =======
-- =================================
-- =================================

--- Counts the characters of a UTF-8 string, or nil when it is not UTF-8.
--- @param text string
--- @return number|nil
local function utf8_length(text)
	local called, count = pcall(Utf8.len, text)
	return called and type(count) == "number" and count or nil
end

--- Why a value cannot be written to an entry, or nil when it can.
--- @param entry table Catalogue entry.
--- @param value any Decoded payload value.
--- @return string|nil
local function refusal(entry, value)
	if entry.kind == "switch" then
		return type(value) ~= "boolean" and "a category switch takes true or false" or nil
	end
	if entry.kind == "choice" or entry.kind == "tap_hold_key" then
		if same(value, entry.value) or same(value, entry.default) then return nil end
		return "an imported item takes its recommendation or its neutral value"
	end
	if type(value) ~= "string" or value:match("^%s*$") or value:find("[%c]") then
		return "the trigger character must be visible text",
			entry.validation and "dialog.magic_key.error_empty" or nil
	end
	local length = utf8_length(value)
	if not length or length > entry.max_characters then
		return "the trigger character is at most " .. entry.max_characters .. " characters",
			entry.validation and "dialog.magic_key.error_length" or nil
	end
	if entry.validation == "safe_magic_key" then
		local valid, why = require("keymap.terminators").validate_magic_key(value)
		if valid ~= true then
			return "the trigger character is refused: " .. tostring(why),
				why == "invalid_character" and "dialog.magic_key.error_length" or "dialog.magic_key.error_common"
		end
	end
	return nil
end

--- Validates the page's operations as a whole and splits them between their
--- owners: configuration rows for the TOML writer, checked tap-hold keys for
--- the host's tap-hold writer.
--- @param index table From M.load.
--- @param operations any The payload's `operations` array.
--- @param manifest table Manifest reader with `sparse_operation(path, value)`.
--- @return table|nil answers `{ rows, tap_hold_keys }`.
--- @return string|nil reason Why the batch was refused.
local function split(index, operations, manifest)
	if type(index) ~= "table" or type(index.entries) ~= "table" then return nil, "no catalogue index" end
	if type(manifest) ~= "table" or type(manifest.sparse_operation) ~= "function" then
		return nil, "no manifest reader"
	end
	if type(operations) ~= "table" then return nil, "the answers carry no operations" end
	local count, highest = 0, 0
	for key in pairs(operations) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil, "the operations are not a list" end
		count, highest = count + 1, math.max(highest, key)
	end
	if highest ~= count then return nil, "the operations are not a list" end
	local rows, keys, seen = {}, {}, {}
	for position = 1, count do
		local operation = operations[position]
		if type(operation) ~= "table" then return nil, "operation " .. position .. " is not a table" end
		local path, value = operation.path, operation.value
		local entry = type(path) == "string" and index.entries[path] or nil
		if not entry then return nil, "operation " .. position .. " names no wizard path" end
		if seen[path] then return nil, path .. " is answered twice" end
		seen[path] = true
		local why, reason_key = refusal(entry, value)
		if why then return nil, path .. ": " .. why, reason_key end
		if entry.kind == "tap_hold_key" then
			-- An unchecked key keeps whatever it has: nothing is written for it.
			if same(value, entry.value) then keys[#keys + 1] = entry.key end
		else
			local ok, row = pcall(manifest.sparse_operation, path, value)
			if not ok or type(row) ~= "table" then
				return nil, path .. " is not a configuration path of this driver: " .. tostring(row)
			end
			rows[#rows + 1] = row
		end
	end
	return { rows = rows, tap_hold_keys = keys }
end

--- Turns the page's operations into configuration rows.
--- @param index table From M.load.
--- @param operations any The payload's `operations` array.
--- @param manifest table Manifest reader with `sparse_operation(path, value)`.
--- @return table|nil rows `{ section, key, value | delete }` for the TOML writer.
--- @return string|nil reason Why the batch was refused.
--- @return string|nil reason_key Existing translated trigger refusal, when applicable.
function M.rows(index, operations, manifest)
	local answers, why, reason_key = split(index, operations, manifest)
	if not answers then return nil, why, reason_key end
	return answers.rows
end

--- The tap-hold keys the answers import: every checked key of the Tap-Holds
--- page, in answer order, for the host's tap-hold writer. The whole payload is
--- validated as M.rows validates it.
--- @param index table From M.load.
--- @param operations any The payload's `operations` array.
--- @param manifest table Manifest reader with `sparse_operation(path, value)`.
--- @return table|nil keys The engine's key ids; empty when nothing is imported.
--- @return string|nil reason Why the batch was refused.
function M.tap_hold_keys(index, operations, manifest)
	local answers, why = split(index, operations, manifest)
	if not answers then return nil, why end
	return answers.tap_hold_keys
end

--- Commits the answers: validates them, versions the destination, then writes
--- every row in one atomic batch.
--- @param opts table `{ index, operations, manifest, path, prepare(path) -> true | false, detail,
---   write(path, rows) -> true | false, detail }`.
--- @return boolean committed
--- @return string|nil detail Refusal or failure reason.
function M.commit(opts)
	assert(type(opts) == "table" and type(opts.path) == "string" and opts.path ~= ""
		and type(opts.prepare) == "function" and type(opts.write) == "function",
		"onboarding commit requires a destination and its prepare and write owners")
	local rows, why = M.rows(opts.index, opts.operations, opts.manifest)
	if not rows then return false, why end
	local prepared_ok, prepared, prepare_detail = pcall(opts.prepare, opts.path)
	if not prepared_ok or prepared ~= true then
		return false, "the destination cannot be written: "
			.. tostring(prepared_ok and prepare_detail or prepared)
	end
	local write_ok, written, write_detail = pcall(opts.write, opts.path, rows)
	if not write_ok then return false, tostring(written) end
	if written ~= true then return false, tostring(write_detail or "the write was not confirmed") end
	return true
end





-- ==================================
-- ==================================
-- ======= 3/ Values in force =======
-- ==================================
-- ==================================

--- The value a decoded configuration holds at a dotted path, or nil.
--- @param decoded table
--- @param segments table Path segments.
--- @return any
local function lookup(decoded, segments)
	local node = decoded
	for _, segment in ipairs(segments) do
		if type(node) ~= "table" then return nil end
		node = node[segment]
	end
	return node
end

--- The configured value of every wizard path the file sets; absent paths are
--- left out so the page shows their neutral value.
--- @param index table From M.load.
--- @param decoded table Decoded config.toml, or an empty table.
--- @param mark function|nil mark(...segments) for each key present and read;
---   the unused-key cleanup never offers a key the wizard reads.
--- @return table values `{ [path] = value }`.
function M.current_values(index, decoded, mark)
	assert(type(index) == "table" and type(index.entries) == "table", "no catalogue index")
	assert(type(decoded) == "table", "the configuration must be decoded")
	assert(mark == nil or type(mark) == "function", "the read marker must be a function")
	local values = {}
	for path, entry in pairs(index.entries) do
		-- A tap-hold key lives in the tap-hold writer's file, never in config.toml.
		if entry.kind ~= "tap_hold_key" then
			local segments = {}
			for segment in path:gmatch("[^%.]+") do segments[#segments + 1] = segment end
			local value = lookup(decoded, segments)
			if value ~= nil then
				values[path] = value
				if mark then mark((table.unpack or unpack)(segments)) end
			end
		end
	end
	return values
end

--- The wizard values of what the host's tap-hold owner reports: each key it
--- configures, as its recommendation or as customised, and on a platform
--- without a config.toml switch, the Tap-Holds switch in its own file.
--- @param index table From M.load.
--- @param report table `{ enabled = boolean|nil, keys = { [key id] =
---   "recommended"|"customised" } }`.
--- @return table values `{ [path] = value }`.
function M.tap_hold_values(index, report)
	assert(type(index) == "table" and type(index.entries) == "table", "no catalogue index")
	assert(type(report) == "table" and type(report.keys) == "table", "the tap-hold report has no keys")
	local values = {}
	for path, entry in pairs(index.entries) do
		if entry.kind == "tap_hold_key" then
			local state = report.keys[entry.key]
			assert(state == nil or state == "recommended" or state == "customised",
				"unknown tap-hold key state " .. tostring(state))
			if state == "recommended" then values[path] = entry.value end
			if state == "customised" then values[path] = entry.customised end
		end
	end
	local state = index.tap_hold_state
	if state and type(report.enabled) == "boolean" and report.enabled ~= state.default then
		values[state.path] = report.enabled
	end
	return values
end

return M
