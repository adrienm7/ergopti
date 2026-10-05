--- modules/dynamic_hotstrings/user_code.lua

--- ==============================================================================
--- MODULE: Programmable Hotstrings (macOS)
--- DESCRIPTION:
--- Defers user callbacks outside the event tap through its consumed-input owner.
--- Every driver output requires the original source, cursor and lifecycle receipt.
--- ==============================================================================
local M = {}
local UserCode = require("dynamic_hotstrings.user_code")
local UserScope = require("dynamic_hotstrings.user_scope")
local Source = require("dynamic_hotstrings.user_source")
local FileSystem = require("adapters.file_system")
local SyntheticInput = require("adapters.synthetic_input")
local ConfigPaths = require("infra.config_paths")
local Logger = require("infra.logger")
local Notifier = require("adapters.notifier")
local I18n = require("infra.i18n")
local Manifest = require("infra.manifest_reader")
local LOG = "dynamic_hotstrings.user_code"
local _owner, _keymap, _path
local _desired_enabled = false
local _time_activation
local _active_enabled, _lifecycle_dirty = false, false
local _scope, set_time

--- Reports a classified failure without leaking user source or callback output.
--- @param kind string Stable failure class.
--- @param id string|nil Admitted descriptor identifier.
--- @return boolean reported
local function report(kind, id)
	if SyntheticInput.is_collecting_callback() then
		return SyntheticInput.defer_after_callback("programmable hotstring error", report, kind, id) == true
	end
	Logger.error(LOG, "Programmable hotstring refused (%s; rule=%s; content withheld).",
		tostring(kind), tostring(id or "source"))
	return Notifier.send(I18n.get("menu.hotstrings.user_code.error"), { kind = "error" }) == true
end

--- Loads the user factory from the configured directory without creating it.
--- @return boolean loaded
local function reload(token)
	if not _owner or not _scope.current(token) then return false end
	local configured = ConfigPaths.get_config_dir()
	local path = configured .. "/personal_dynamic_hotstrings.lua"
	_active_enabled = false
	_lifecycle_dirty = _owner.refuse_source() ~= true
	if _lifecycle_dirty then return false end
	local rules, receipt, problem = Source.load(FileSystem.read_with_status, path, { platform = "macos" })
	if not _scope.current(token) then return false end
	if not rules or receipt.present ~= true then
		_lifecycle_dirty = _owner.refuse_source() ~= true
		report(problem or "source-absent")
		return false
	end
	_path = path
	local committed = _owner.reload(rules, receipt) == true and _owner.set_enabled(_desired_enabled) == true
	if not _scope.current(token) then return false end
	_active_enabled = committed and _desired_enabled
	return committed
end

--- Reloads source under one operation-owned configuration revision.
--- @return boolean loaded
--- @return table revision Exact revision assigned to this operation.
function M.reload()
	local token = _scope.begin()
	return reload(token), token
end

--- Starts the single keymap-bound programmable generation.
--- @param keymap table Native input owner.
--- @return boolean started
function M.start(keymap)
	if _owner then return _keymap == keymap end
	_scope.begin()
	_keymap = keymap
	_owner = UserCode.new({
		capture = function(rule) return keymap.capture_user_hotstring(rule) end,
		current = function(capture, receipt)
			return _keymap == keymap
				and _path == ConfigPaths.get_config_dir() .. "/personal_dynamic_hotstrings.lua"
				and keymap.is_group_enabled("dynamichotstrings") == true
				and keymap.owns_user_hotstring(capture) == true
				and Source.current(FileSystem.read_with_status, receipt) == true
		end,
		publication_current = function(capture, receipt)
			return _keymap == keymap and _path == M.source_path()
				and keymap.owns_user_hotstring_publication(capture) == true
				and Source.current(FileSystem.read_with_status, receipt) == true
				and _keymap == keymap and _path == M.source_path()
				and keymap.owns_user_hotstring_publication_cached(capture) == true
		end,
		publication_cached = function(capture)
			return _keymap == keymap and _path == M.source_path()
				and keymap.owns_user_hotstring_publication_cached(capture) == true
		end,
		invoke = function(rule, context, done, capture)
			capture.execution_context = context
			local cancelled, scheduled, settled, retired = false, false, false, false
			local function retire()
				if retired then return true end
				if keymap.owns_user_hotstring(capture) == true
					and keymap.commit_user_hotstring(false, capture, rule) ~= true then return false end
				retired = true
				return true
			end
			return {
				start = function()
					scheduled = SyntheticInput.defer_consumed_input_action("programmable hotstring", function()
						if cancelled then retire(); settled = true; return end
						if context.cancelled() then done(false); settled = true; return end
						local ok, result = pcall(rule.callback, context)
						if ok then done(result) else done(nil, "callback-error") end
						settled = true
					end) == true
					return scheduled
				end,
				cancel = function()
					cancelled = true
					if not scheduled then return true end
					return settled and retire()
				end,
			}
		end,
		retire = function(capture, rule)
			if keymap.owns_user_hotstring(capture) ~= true then return true end
			return keymap.commit_user_hotstring(false, capture, rule) == true
		end,
		commit = function(result, capture, rule, publication)
			return keymap.commit_user_hotstring(result, capture, rule, function()
				return capture.execution_context.cancelled() == false
			end, publication)
		end,
		report = report,
	})
	_path = M.source_path()
	local receipt, problem = Source.read(FileSystem.read_with_status, _path)
	if not receipt then report(problem); return true end
	-- Reading source at closed boot does not admit executable factory metadata.
	return _owner.refuse_source() == true
end

--- Applies the canonical user-code activation choice without writing config.
--- @param enabled boolean Requested native posture.
--- @return boolean committed
function M.set_enabled(enabled)
	local token = _scope.begin()
	if not _owner or type(enabled) ~= "boolean" then return false, token end
	if not enabled and not _desired_enabled and not _active_enabled and not _lifecycle_dirty then
		return true, token
	end
	if enabled and _active_enabled and not _lifecycle_dirty then
		local receipt = _owner.scope_snapshot().source
		local admitted = receipt and receipt.path == M.source_path()
			and Source.current(FileSystem.read_with_status, receipt) == true
		if not _scope.current(token) then return false, token end
		if admitted then return true, token end
	end
	if enabled and _time_activation == nil then
		local ready = set_time(Manifest.default_for("hotstrings.dynamic.user_code.time_activation_seconds"), token)
		if ready ~= true or not _scope.current(token) then return false, token end
	end
	if not enabled then
		_desired_enabled, _active_enabled = false, false
		_lifecycle_dirty = _owner.set_enabled(false) ~= true
		return not _lifecycle_dirty and _scope.current(token), token
	end
	_desired_enabled = true
	if reload(token) == true then return true, token end
	if _scope.current(token) then _desired_enabled = false end
	return false, token
end

--- Applies the configured activation interval before admitting execution.
--- @param seconds number Nonnegative activation interval.
--- @return boolean committed
set_time = function(seconds, token)
	if not _owner or type(seconds) ~= "number" or seconds < 0 or seconds ~= seconds or seconds >= math.huge then
		return false
	end
	if _time_activation == seconds and not _lifecycle_dirty then return true end
	_lifecycle_dirty = _owner.invalidate("activation interval") ~= true
	if _lifecycle_dirty or not _scope.current(token) then return false end
	if _keymap.set_user_hotstring_time_activation(seconds) ~= true or not _scope.current(token) then return false end
	_time_activation = seconds
	return true
end

--- Applies an interval under this call's exact configuration operation receipt.
--- @param seconds number Nonnegative activation interval.
--- @return boolean committed
--- @return table revision Revision assigned before validation or native calls.
function M.set_time_activation(seconds)
	local token = _scope.begin()
	return set_time(seconds, token), token
end

--- Returns the configured user source path for the shared menu.
--- @return string path
function M.source_path()
	return ConfigPaths.get_config_dir() .. "/personal_dynamic_hotstrings.lua"
end

--- Creates the explicit example while preserving every existing user file.
--- @return boolean created
function M.create_example()
	return Source.create_example(FileSystem.read_with_status, FileSystem.write_if_unchanged, M.source_path())
end

--- Returns the admitted metadata count without running callbacks.
--- @return number count
function M.count()
	return _owner and _owner.admitted_count() or 0
end

--- Fences pending work at a native pause or configuration boundary.
--- @param reason string Native lifecycle transition.
--- @return boolean retired
function M.invalidate(reason)
	if not _owner then return true end
	_lifecycle_dirty = _owner.invalidate(reason) ~= true
	return not _lifecycle_dirty
end

--- Requests the matching suffix after builtins declined it.
--- @param buffer string Observed text before the magic key.
--- @return boolean accepted
function M.request(buffer)
	if _keymap and _keymap.has_registered_magic_action(buffer) then return false end
	return _owner ~= nil and _owner.request(buffer) == true
end

--- Returns inert user metadata for a matching suffix.
--- @param buffer string Observed text before the magic key.
--- @return string|nil preview
function M.preview(buffer)
	if _keymap and _keymap.has_registered_magic_action(buffer) then return nil end
	local row = _owner and _owner.preview(buffer)
	return row and row.preview or nil
end

--- Returns the acknowledged execution gate without invoking user code.
--- @return boolean enabled
function M.is_enabled() return _owner ~= nil and _active_enabled and not _lifecycle_dirty end

--- Returns the current native activation interval.
--- @return number|nil seconds
function M.time_activation() return _time_activation end

--- Retires the generation before cancelling any outstanding operation.
--- @return boolean stopped
function M.stop()
	if not _owner then return true end
	_scope.begin()
	_active_enabled = false
	_lifecycle_dirty = _owner.stop() ~= true
	if _lifecycle_dirty then return false end
	_owner, _keymap, _path = nil, nil, nil
	_desired_enabled = false
	_time_activation = nil
	return true
end


--- Captures native lifecycle, callbacks, source and scalar posture for a scope.
--- @return table|nil snapshot Exact configuration inverse.
function M.scope_snapshot() return _scope.capture() end

--- Checks a retained inverse before any enclosing runtime or file restoration.
--- @param snapshot table Exact configuration inverse.
--- @return boolean current
function M.scope_current(snapshot) return _scope.current_snapshot(snapshot) end

--- Adopts controls only for the scope's expected operation revision.
--- @param snapshot table Retained configuration inverse.
--- @param seconds number Nonnegative activation interval.
--- @param enabled boolean Requested callback gate.
--- @return boolean adopted
function M.scope_adopt(snapshot, seconds, enabled) return _scope.adopt(snapshot, seconds, enabled) end

--- Restores retained callbacks without evaluating the user factory again.
--- @param snapshot table Exact configuration inverse.
--- @return boolean restored
function M.scope_restore(snapshot) return _scope.restore(snapshot) end

_scope = UserScope.new({
	identity = function() return _owner, _keymap end,
	read_source = function() return Source.read(FileSystem.read_with_status, M.source_path()) end,
	source_current = function(receipt)
		return receipt.path == M.source_path() and Source.current(FileSystem.read_with_status, receipt) == true
	end,
	policy = function() return _owner.scope_snapshot() end,
	quiescent = function() return not _lifecycle_dirty and _owner.scope_snapshot().quiescent == true end,
	seconds = function() return _time_activation end,
	enabled = M.is_enabled,
	desired = function() return _desired_enabled end,
	set_seconds = M.set_time_activation,
	set_enabled = M.set_enabled,
	restore = function(snapshot, token)
		_lifecycle_dirty = _owner.invalidate("configuration inverse") ~= true
		if _lifecycle_dirty or not _scope.current(token) then return false end
		if _keymap.set_user_hotstring_time_activation(snapshot.seconds) ~= true then return false end
		if not _scope.current(token) or _owner.scope_restore(snapshot.policy) ~= true then return false end
		if not _scope.current(token) then return false end
		_time_activation, _desired_enabled = snapshot.seconds, snapshot.desired
		_active_enabled, _lifecycle_dirty = snapshot.enabled, false
		return true
	end,
})

return M
