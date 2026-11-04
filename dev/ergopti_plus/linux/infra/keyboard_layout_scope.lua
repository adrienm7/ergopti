--- infra/keyboard_layout_scope.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Scope Transaction (Linux)
--- DESCRIPTION:
--- Restores or clears the layout rows of config.toml (the number-row ordering
--- and its edge-key switch) through the shared scope transaction, then has the
--- layout manager load the layout that carries them (modules/keymap/
--- number_row_live), so a global restore covers the layout category here as it
--- does on the other drivers.
---
--- FEATURES & RATIONALE:
--- 1. Same transaction as every other scope: verified backup, conditional
---    publication, an exact inverse kept while a later category may still
---    refuse, and retained debt when a restore is refused.
--- 2. Exact ownership: only the manifest's keyboard_layout rows change; unknown
---    sections and fields of config.toml survive.
--- 3. Acknowledged by the session: the participant settles only once the layout
---    manager reports the new layout read back from the running session
---    (docs/design/layout-option-emulation.md, section 5). A choice this session
---    cannot apply (no layout of ours, a desktop without a live path) is stored
---    and acknowledged with its reason, as Windows keeps an inert choice. A load
---    the session refuses reverts the rows, so the file never claims options the
---    keyboard does not type; a revert the session refuses stays owed.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Transaction = require("config_scope_transaction")
local Logger = require("logger.shim")
local LOG = "infra.keyboard_layout_scope"
local SCOPE = "keyboard_layout"
local _owner, _sequence = nil, 0
require("infra.scope_registry").register("keyboard_layout_scope", function() return _owner ~= nil and _owner.pending() == true end)

--- Builds one recoverable transaction over config.toml's layout rows.
--- @param options table path, backup_path and an optional files port.
--- @return table owner apply(mode), revert(), release(), pending(), retry_restore().
function M.new(options)
	assert(type(options) == "table", "keyboard layout scope requires its options")
	local transaction = Transaction.new({
		path = options.path, backup_path = options.backup_path,
		files = options.files or require("adapters.file_system"), manifest = Manifest,
		-- The live layout is acknowledged by the participant, after the rows are
		-- published: the receipt is empty but present, so the transaction records
		-- that the capture happened.
		capture = function() return {} end,
		apply = function() return true end,
		restore = function() return true end,
	})
	local owner = {}
	for _, name in ipairs({ "revert", "release", "pending", "retry_restore" }) do owner[name] = transaction[name] end
	--- @param mode string "recommended" or "clear".
	function owner.apply(mode) return transaction.apply(SCOPE, mode) end
	return owner
end

--- Executes a menu request, retaining any failed inverse for the next retry.
--- @param mode string "recommended" or "clear".
--- @param is_paused function Live pause getter.
--- @return boolean committed
--- @return string|nil detail
function M.apply(mode, is_paused)
	if mode ~= "recommended" and mode ~= "clear" then return false, "invalid keyboard layout scope mode" end
	if type(is_paused) ~= "function" or is_paused() then return false, "keyboard layout configuration is paused" end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then
		return false, "keyboard layout rollback is pending"
	end
	_sequence = _sequence + 1
	local path = require("infra.config_paths").config("config.toml")
	_owner = M.new({ path = path,
		backup_path = path .. ".layout-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak" })
	Logger.start(LOG, "Keyboard layout scope '%s' started.", mode)
	local committed, detail = _owner.apply(mode)
	if committed then Logger.success(LOG, "Keyboard layout scope '%s' completed.", mode)
	else Logger.error(LOG, "Keyboard layout scope '%s' refused: %s.", mode, tostring(detail)) end
	return committed, detail
end

--- Whether two stored row choices are the same.
--- @param left table { order, edges }
--- @param right table { order, edges }
--- @return boolean
local function same_rows(left, right)
	return left.order == right.order and left.edges == right.edges
end

--- Brings the session to the stored rows; settle(ok, code) once the layout manager answers.
--- An inert choice (no layout of ours, a desktop without a live path) settles at once.
--- @param live table The number-row live owner.
--- @param settle function
local function load_stored(live, settle)
	local available, reason = live.available()
	if not available then
		Logger.warn(LOG, "The layout rows are stored and not loaded: %s.", tostring(reason))
		return settle(true, reason)
	end
	local dispatched = live.apply_stored(function(applied, code, _, live_code)
		if applied then return settle(true, nil) end
		return settle(false, tostring(live_code or code))
	end)
	if dispatched == false then return settle(false, "the layout manager refused the request") end
end

--- The layout participant of a composed scope, bound to the retained owner. It
--- settles each request only once the session holds the layout the stored rows
--- describe.
--- @param is_paused function Live pause getter.
--- @param ports table|nil { live } The number-row live owner (tests replace it).
--- @return table participant See config_scope_composition.
function M.participant(is_paused, ports)
	ports = ports or {}
	local live = ports.live or require("modules.keymap.number_row_live")
	-- cohort: the owner of this participant's request; changed: its rows moved;
	-- owed: the session still has to be brought back to the reverted rows.
	local cohort, changed, applying, owed = nil, false, false, false
	local participant = {}

	function participant.pending()
		if applying or owed then return true end
		local owner = cohort or _owner
		return owner ~= nil and owner.pending() ~= false
	end

	function participant.apply(mode, done)
		if participant.pending() then return done(false, "the layout scope retains an unsettled request") end
		applying = true
		local before = live.stored()
		local called, committed, detail = pcall(M.apply, mode, is_paused)
		cohort = _owner
		if not called or committed ~= true then
			applying = false
			return done(false, called and detail or tostring(committed))
		end
		changed = not same_rows(before, live.stored())
		if not changed then
			applying = false
			return done(true, "rows_unchanged")
		end
		load_stored(live, function(loaded, code)
			if loaded then
				applying = false
				return done(true, code)
			end
			-- The session kept its layout: the file must not claim the new rows.
			local reverted, revert_detail = cohort.revert()
			applying = false
			Logger.error(LOG, "The layout rows were not loaded (%s); config.toml reverted: %s.", tostring(code),
				tostring(reverted == true or revert_detail))
			return done(false, "the session did not load the layout: " .. tostring(code))
		end)
	end

	function participant.revert(done)
		if applying then return done(false, "the layout scope request is still settling") end
		if cohort == nil then return done(false, "no committed scope to revert") end
		local reverted, detail = cohort.revert()
		if reverted ~= true then
			-- The session reload follows the rows once their rollback settles.
			owed, changed = changed, false
			return done(false, detail)
		end
		if not changed then return done(true) end
		changed = false
		applying = true
		load_stored(live, function(loaded, code)
			applying = false
			owed = not loaded
			return done(loaded, code)
		end)
	end

	function participant.release()
		if applying or owed or (cohort ~= nil and cohort.pending() ~= false) then return false end
		if cohort ~= nil then cohort.release() end
		cohort, changed = nil, false
	end

	function participant.retry_restore(done)
		if applying then return done(false, "the layout scope request is still settling") end
		if cohort ~= nil and cohort.pending() ~= false and cohort.retry_restore() ~= true then
			return done(false, "the layout rows rollback is still pending")
		end
		if not owed then
			cohort, changed = nil, false
			return done(true)
		end
		applying = true
		load_stored(live, function(loaded, code)
			applying = false
			owed = not loaded
			if loaded then cohort, changed = nil, false end
			return done(loaded, code)
		end)
	end

	return participant
end

--- Test seam: forgets the retained owner and its debt.
function M._reset_for_test()
	_owner, _sequence = nil, 0
end

return M
