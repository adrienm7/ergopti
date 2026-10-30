--- modules/keymap/layout_rows_build.lua

--- ==============================================================================
--- MODULE: Layout Rows Build (macOS live replace)
--- DESCRIPTION:
--- Installs a layout that types the number-row options and makes it the typing
--- layout with no logout (docs/design/layout-option-emulation.md, section 3.1).
--- macOS keeps typing the cells it cached for a keyboard it has seen (probe M3),
--- so every build is a NEW loose .keylayout under its own name and id
--- (layouts/keylayout_rows.lua): written, enabled through the enabled-sources
--- preference (the route the driver already proves, probe P5), selected, read
--- back from a fresh process, and only then is the previous build retired.
---
--- FEATURES & RATIONALE:
--- 1. Settles only on the read-back: a build is accepted once a fresh process
---    reports it selected AND the launcher's keyboard probe, on that exact
---    source, types the base cells the build was compiled with. A write or an
---    exit status alone proves nothing.
--- 2. Nothing half applied: a build that fails after its file was written is
---    unselected (the previous layout is selected again), disabled and deleted;
---    the previous build stays the typing layout.
--- 3. Bounded stale sources: a retirement that fails is recorded and retried
---    before the next build; with two retirements outstanding a build is refused
---    (stale_sources_pending). A disabled source stays listed by the system until
---    logout (probe M5a); that is reported, not hidden.
--- 4. One operation at a time; every collaborator is injectable, so the suite
---    replays the whole sequence and the field run reuses it with its own record.
--- ==============================================================================

local Logger = require("infra.logger")
local Rows = require("layouts.keylayout_rows")

local M = {}

local LOG = "keymap.layout_rows_build"

-- Closed failure codes (section 3.2 of the design note).
M.FAILURE_BUSY = "busy"
M.FAILURE_REFUSED = "layout_refused"
M.FAILURE_STALE = "stale_sources_pending"
M.FAILURE_FOREIGN = "foreign_file"
M.FAILURE_WRITE = "write_failed"
M.FAILURE_RECORD = "record_failed"
M.FAILURE_ENABLE = "enable_failed"
M.FAILURE_LOGOUT = "requires_logout"
M.FAILURE_SELECT = "select_refused"
M.FAILURE_READBACK = "readback_mismatch"

-- The most retirements left outstanding before a build is refused.
M.MAX_PENDING_REMOVALS = 2

local RECORD_SCHEMA = 1

local _busy = false
-- The decoded shared keycode table, once read.
local _keycodes_table = nil





-- ==============================
-- ==============================
-- ======= 1/ Record ============
-- ==============================
-- ==============================

--- Reads the build record; an absent one is empty.
--- @param deps table
--- @return table|nil record { schema, n, current, pending_removal }
--- @return string|nil err
local function read_record(deps)
	if not deps.exists(deps.record_path) then
		return { schema = RECORD_SCHEMA, n = 0, current = nil, pending_removal = {} }, nil
	end
	local text = deps.read(deps.record_path)
	if type(text) ~= "string" then return nil, "the build record is unreadable" end
	local ok, record = pcall(deps.decode_json, text)
	if not ok or type(record) ~= "table" or record.schema ~= RECORD_SCHEMA or type(record.n) ~= "number" then
		return nil, "the build record is malformed"
	end
	record.pending_removal = type(record.pending_removal) == "table" and record.pending_removal or {}
	return record, nil
end

--- @param deps table
--- @param record table
--- @return boolean ok
--- @return string|nil err
local function write_record(deps, record)
	local prepared, prepare_err = deps.prepare_parent(deps.record_path)
	if not prepared then return false, tostring(prepare_err) end
	return deps.write(deps.record_path, deps.encode_json(record))
end

--- The installed path and keyboard name of build `n`.
--- @param deps table
--- @param base_name string The source layout's keyboard name.
--- @param n integer
--- @return string path, string name
function M.build_identity(deps, base_name, n)
	return deps.layouts_dir .. deps.file_prefix .. n .. ".keylayout", base_name .. " " .. n
end





-- ==============================
-- ==============================
-- ======= 2/ Steps =============
-- ==============================
-- ==============================

--- Disables and deletes one build; fn(ok, reason).
--- @param deps table
--- @param build table { name, path }
--- @param on_done function
local function retire(deps, build, on_done)
	deps.disable_source(build.name, build.name, function(disabled, _, reason)
		if not disabled then
			Logger.warn(LOG, "The build '%s' could not be disabled: %s.", build.name, tostring(reason))
			return on_done(false, "disable_failed")
		end
		local deleted, delete_err = deps.delete_build(build.path)
		if deleted == false or deps.exists(build.path) then
			Logger.warn(LOG, "The build file '%s' could not be deleted: %s.", build.path, tostring(delete_err))
			return on_done(false, "delete_failed")
		end
		Logger.info(LOG, "Retired the build '%s'; the system lists it until the next login.", build.name)
		on_done(true, nil)
	end)
end

--- Retries the recorded retirements in order, keeping the ones that fail.
--- @param deps table
--- @param record table
--- @param on_done function fn() once every retry answered.
local function retry_pending(deps, record, on_done)
	local left, index = {}, 0
	local function step()
		index = index + 1
		local build = record.pending_removal[index]
		if build == nil then
			record.pending_removal = left
			return on_done()
		end
		retire(deps, build, function(ok)
			if not ok then left[#left + 1] = build end
			step()
		end)
	end
	step()
end

--- The cells the build types on its base level must be what the probe read.
--- @param expected table From Rows.cells: { digits, edges } of { plain, shift }.
--- @param receipt table The keyboard probe's receipt.
--- @return boolean matches
--- @return string detail The first difference, or the count compared.
function M.compare_readback(expected, receipt)
	local wanted = {}
	for _, cell in ipairs(expected.digits) do wanted[#wanted + 1] = cell.plain end
	for _, cell in ipairs(expected.edges) do wanted[#wanted + 1] = cell.plain end
	if type(receipt) ~= "table" or type(receipt.levels) ~= "table" or #receipt.levels ~= #wanted then
		return false, "the probe read " .. tostring(type(receipt) == "table" and type(receipt.levels) == "table"
			and #receipt.levels or 0) .. " keys, " .. #wanted .. " expected"
	end
	for index, cell in ipairs(wanted) do
		local level = receipt.levels[index]
		local ok
		if cell == nil then ok = level.text == "" and level.dead == false
		elseif cell.Kind == "dead" then ok = level.dead == true
		else ok = level.dead == false and level.text == cell.Text end
		if not ok then
			return false, string.format("key %d types '%s'%s, the build holds %s", level.code, level.text,
				level.dead and " (dead)" or "", cell and (cell.Kind .. " '" .. tostring(cell.Text) .. "'") or "nothing")
		end
	end
	return true, tostring(#wanted) .. " keys"
end

--- The macOS key codes of the read-back, in Rows.cells order.
local function readback_codes(codes)
	local list = {}
	for _, code in ipairs(codes.digits) do list[#list + 1] = code end
	for _, code in ipairs(codes.edges) do list[#list + 1] = code end
	return list
end





-- ==============================
-- ==============================
-- ======= 3/ Replace ===========
-- ==============================
-- ==============================

--- Builds, installs, selects and verifies a layout that types `rows`, then retires
--- the previous build. A choice the layout already types (or cannot take) installs
--- nothing: the source layout is selected again and the build retired.
--- on_done(true, { report, build = { n, name, path, source_id } | nil, readback, ghosts })
--- or on_done(false, code, detail, { report }) is called exactly once.
--- @param source table { id, keyboard_name, text, convention } The layout the options apply to.
--- @param rows table { order, edges }
--- @param on_done function
--- @param deps table See M.default_deps.
--- @return boolean dispatched
function M.replace(source, rows, on_done, deps)
	if _busy then
		on_done(false, M.FAILURE_BUSY, "another layout build is still running", {})
		return false
	end
	_busy = true
	local report = nil
	local function finish(ok, code_or_result, detail)
		_busy = false
		if ok then
			Logger.success(LOG, "Number-row layout ready for '%s' (%s).", tostring(source.id),
				code_or_result.build and code_or_result.build.name or "the source layout")
			on_done(true, code_or_result)
		else
			Logger.error(LOG, "The number-row layout for '%s' was not applied (%s): %s.", tostring(source.id),
				tostring(code_or_result), tostring(detail))
			on_done(false, code_or_result, detail, { report = report })
		end
	end
	Logger.start(LOG, "Building the number-row layout of '%s' (%s, edges=%s)…", tostring(source.id),
		tostring(rows.order), tostring(rows.edges))

	local codes, codes_err = Rows.key_codes(deps.keycodes_table, source.convention)
	if not codes then
		finish(false, M.FAILURE_REFUSED, codes_err)
		return false
	end
	local record, record_err = read_record(deps)
	if not record then
		finish(false, M.FAILURE_RECORD, record_err)
		return false
	end
	local result, apply_err = Rows.apply(source.text, rows, codes)
	if not result then
		finish(false, M.FAILURE_REFUSED, apply_err)
		return false
	end
	report = result.report

	retry_pending(deps, record, function()
		if #record.pending_removal >= M.MAX_PENDING_REMOVALS then
			return finish(false, M.FAILURE_STALE, #record.pending_removal .. " earlier builds are still listed")
		end
		local previous = record.current

		--- Retires the previous build once `selected_name` types; records the outcome.
		local function settle(build, readback)
			local function done()
				record.current = build
				local written, write_err = write_record(deps, record)
				if not written then return finish(false, M.FAILURE_RECORD, write_err) end
				finish(true, { report = report, build = build, readback = readback,
					ghosts = #record.pending_removal })
			end
			if previous == nil then return done() end
			retire(deps, previous, function(retired)
				if not retired then record.pending_removal[#record.pending_removal + 1] = previous end
				done()
			end)
		end

		if not result.changed then
			-- The layout already types the choice (or cannot take it): its own layout types.
			if previous == nil then return settle(nil, nil) end
			return deps.select_source(source.keyboard_name, source.keyboard_name, function(selected, _, reason)
				if not selected then return finish(false, M.FAILURE_SELECT, tostring(reason)) end
				settle(nil, nil)
			end)
		end

		local n = record.n + 1
		local path, name = M.build_identity(deps, source.keyboard_name, n)
		local text, rename_err = Rows.rename(result.text, name)
		if not text then return finish(false, M.FAILURE_REFUSED, rename_err) end
		if deps.exists(path) then return finish(false, M.FAILURE_FOREIGN, path .. " already exists") end
		local expected, cells_err = Rows.cells(text, codes)
		if not expected then return finish(false, M.FAILURE_REFUSED, cells_err) end
		-- Recorded before the write: an interrupted build leaves a file the next build removes.
		record.n = n
		local build = { n = n, name = name, path = path, source_id = source.id }
		record.pending_removal[#record.pending_removal + 1] = build
		local recorded, recorded_err = write_record(deps, record)
		if not recorded then return finish(false, M.FAILURE_RECORD, recorded_err) end
		local written, write_err = deps.write_build(path, text)
		if not written then return finish(false, M.FAILURE_WRITE, tostring(write_err)) end

		--- Undoes this build: the previous layout types again, the build goes.
		local function abandon(code, detail)
			local back = previous and previous.name or source.keyboard_name
			deps.select_source(back, back, function()
				retire(deps, build, function(retired)
					if retired then table.remove(record.pending_removal) end
					write_record(deps, record)
					finish(false, code, detail)
				end)
			end)
		end

		deps.enable_source(path, name, function(listed, _, enable_reason)
			if not listed then return abandon(M.FAILURE_ENABLE, tostring(enable_reason)) end
			deps.confirm_enabled(name, { register_path = path }, function(read, state, read_reason)
				if not read then return abandon(M.FAILURE_ENABLE, tostring(read_reason)) end
				if state.enabled ~= true then return abandon(M.FAILURE_LOGOUT, "a fresh process reads the build off") end
				deps.select_source(name, name, function(selected, _, select_reason)
					if not selected then return abandon(M.FAILURE_SELECT, tostring(select_reason)) end
					deps.confirm_source(name, {}, function(seen, now, seen_reason)
						if not seen or now.selected ~= true or type(now.id) ~= "string" then
							return abandon(M.FAILURE_SELECT, "a fresh process does not see the build selected ("
								.. tostring(seen_reason or (now and now.id)) .. ")")
						end
						deps.probe({ source_id = now.id, codes = readback_codes(codes) }, function(receipt, probe_reason)
							if receipt == nil then
								return abandon(M.FAILURE_READBACK, "the keyboard probe answered " .. tostring(probe_reason))
							end
							local matches, detail = M.compare_readback(expected, receipt)
							if not matches then return abandon(M.FAILURE_READBACK, detail) end
							table.remove(record.pending_removal)
							build.source_id_seen = now.id
							settle(build, { source_id = now.id, keys = #receipt.levels, detail = detail })
						end)
					end)
				end)
			end)
		end)
	end)
	return true
end

--- The build typing for a layout now, from the record; nil when none or unreadable.
--- @param deps table
--- @return table|nil build { n, name, path, source_id }
function M.current(deps)
	local record = read_record(deps)
	return record and record.current or nil
end

--- Retires the current build and the recorded ones (the field run's restore, or
--- a reset); selects nothing. on_done(ok, left) with the builds still listed.
--- @param on_done function
--- @param deps table
function M.retire_all(on_done, deps)
	local record, record_err = read_record(deps)
	if not record then return on_done(false, record_err) end
	if record.current ~= nil then
		record.pending_removal[#record.pending_removal + 1] = record.current
		record.current = nil
	end
	retry_pending(deps, record, function()
		local written, write_err = write_record(deps, record)
		if not written then return on_done(false, write_err) end
		on_done(#record.pending_removal == 0, #record.pending_removal)
	end)
end

--- The production collaborators; `overrides` replaces any of them.
--- @param overrides table|nil Any field below, plus record_path and file_prefix.
--- @return table deps
function M.default_deps(overrides)
	overrides = overrides or {}
	local FileSystem = require("adapters.file_system")
	local Json = require("json")
	local InputSources = require("modules.keymap.input_sources")
	local LayoutFiles = require("adapters.keyboard_layout_files")
	local deps = {
		read = FileSystem.read,
		write = FileSystem.write,
		-- The builds themselves leave no lock file in the user's layouts folder.
		write_build = LayoutFiles.write_new,
		delete_build = LayoutFiles.remove,
		exists = FileSystem.exists,
		prepare_parent = FileSystem.prepare_parent_for_create,
		decode_json = Json.decode,
		encode_json = Json.encode,
		layouts_dir = FileSystem.expand_path("~/Library/Keyboard Layouts") .. "/",
		file_prefix = "ErgoptiRows-",
		record_path = require("infra.config_paths").get_config_dir() .. "layouts/rows_builds.json",
		enable_source = InputSources.enable_keylayout_source_async,
		disable_source = InputSources.disable_keylayout_source_async,
		select_source = InputSources.set_input_source_async,
		confirm_enabled = InputSources.confirm_enabled_async,
		confirm_source = InputSources.confirm_source_async,
		probe = function(request, callback) return require("adapters.keyboard_source_probe").request(request, callback) end,
	}
	-- Read once: the menu asks for these collaborators at every rebuild.
	if _keycodes_table == nil then
		local table_path = require("infra.paths").shared("modules/layouts/mac_keycodes.json")
		local table_text = type(table_path) == "string" and FileSystem.read(table_path) or nil
		_keycodes_table = type(table_text) == "string" and Json.decode(table_text) or nil
	end
	deps.keycodes_table = _keycodes_table
	for key, value in pairs(overrides) do deps[key] = value end
	return deps
end

--- Test seam: forgets the operation in flight.
function M._reset() _busy = false end

return M
