--- modules/shortcuts/magic_editor.lua

--- ==============================================================================
--- MODULE: Conditional Ordinary Editor Shortcut
--- DESCRIPTION:
--- Projects a measured macOS input source into the shared magic-editor policy.
--- Native proof, physical acquisition and cleanup remain owned across source,
--- assignment, pause and preference changes; displayed glyphs never bind keys.
--- ==============================================================================

local M = {}

local Policy = require("shortcuts.magic_editor")
local Registrar = require("adapters.hotkey_registrar")
local Broker = require("adapters.input_source_broker")
local Probe = require("adapters.keyboard_source_probe")
local FileSystem = require("adapters.file_system")
local JsonCodec = require("adapters.json_codec")
local Paths = require("infra.paths")
local Manifest = require("infra.manifest_reader")
local MagicKeySource = require("modules.keymap.magic_key_source")
local Geometry = require("adapters.keyboard_geometry")
local Logger = require("infra.logger")

local LOG = "shortcuts.magic_editor"
local SUBSCRIBER = "shortcuts.magic_editor"
local _spec = nil
local _started = false
local _generation = 0
local _attempt = nil
local _handle = nil
local _decision = nil
local _registry = nil
local _subscribed = false
local _acquisition_depth = 0
local _cancel_depth = 0

local function registry()
	if _registry then return _registry end
	local text = FileSystem.read(Paths.shared("data/keycodes/physical_keys.json"))
	local parsed, detail = JsonCodec.decode(text or "")
	assert(type(parsed) == "table" and type(parsed.keys) == "table",
		"physical keyboard registry unavailable: " .. tostring(detail))
	_registry = parsed.keys
	return _registry
end

local function gates()
	return {
		master = _started and _spec.is_current() == true,
		paused = _spec.context.paused() ~= false,
		inhibited = _spec.context.inhibited() ~= false,
	}
end

local function release_native()
	if _handle == nil then return true end
	local called, released = xpcall(Registrar.unbind, debug.traceback, _handle)
	if not called or released ~= true then return false end
	_handle = nil
	return true
end

local function cancel_attempt()
	local attempt = _attempt
	if attempt == nil then return true end
	attempt.fenced = true
	if attempt.operation == nil then return attempt.installing ~= true end
	_cancel_depth = _cancel_depth + 1
	local called, cancelled = xpcall(attempt.operation.cancel, debug.traceback)
	_cancel_depth = _cancel_depth - 1
	if not called or cancelled ~= true then return false end
	if _attempt == attempt then _attempt = nil end
	return true
end

local function current(attempt)
	return _started and _attempt == attempt and attempt.fenced ~= true
		and attempt.generation == _generation and _spec.is_current() == true
		and Probe.current_source_id() == attempt.source_id
		and _spec.context.trigger() == attempt.trigger
		and _spec.context.magic_source() == attempt.magic_source
		and _spec.context.replace_active() == attempt.replace_active
end

local function project(receipt, attempt)
	local candidates, remapped_candidates, known = {}, {}, {}
	local by_native = {}
	local keyboard_type = receipt and receipt.keyboard_type or nil
	for code, entry in pairs(registry()) do
		if entry.kind == "key" and type(entry.hs) == "number" then
			known[code] = true
			local native = Geometry.physical_code(entry, keyboard_type)
			if native ~= nil then by_native[native] = code end
		end
	end
	for _, level in ipairs(receipt and receipt.levels or {}) do
		local code = by_native[level.code]
		if code then
			local remapped = MagicKeySource.remaps(level.code, {}, function()
				return attempt.replace_active
			end, keyboard_type)
			local candidate = {
				code = code,
				native_code = level.code,
				identity = Registrar.physical_identity({ "ctrl" }, level.code),
				text = remapped and attempt.trigger or level.text,
				direct = remapped or level.direct,
				dead = not remapped and level.dead,
			}
			candidates[#candidates + 1] = candidate
			if remapped then remapped_candidates[#remapped_candidates + 1] = candidate end
		end
	end
	-- An acknowledged explicit replacement owns the effective source. Automatic
	-- scanning applies only when no selected replacement actually emits it.
	if #remapped_candidates > 0 then candidates = remapped_candidates end
	return Policy.resolve({
		default_action = Manifest.default_for(Policy.PATH),
		stored_action = _spec.action,
		is_action = _spec.is_action,
		trigger = attempt.trigger,
		source = {
			generation = attempt.generation,
			status = receipt and attempt.replace_active ~= nil and "ready" or "unavailable",
			candidates = candidates,
		},
		known_codes = known,
		explicit_claims = Registrar.physical_claims(),
		configuration_generation = _spec.configuration_generation,
		admission = gates(),
	})
end

local function deliver()
	local decision = _decision
	if _acquisition_depth ~= 0 or not decision or not _spec or (_spec.context.legacy_present or _spec.context.assignment_unavailable) then return false end
	local admission = gates()
	if not Policy.can_deliver(decision, {
		source_generation = _generation,
		configuration_generation = _spec.configuration_generation,
		action = _spec.action or Manifest.default_for(Policy.PATH),
		master = admission.master,
		paused = admission.paused,
		inhibited = admission.inhibited,
	}) then return false end
	if Probe.current_source_id() ~= _decision.source_id
		or _spec.context.trigger() ~= _decision.trigger
		or _spec.context.magic_source() ~= _decision.magic_source
		or _spec.context.replace_active() ~= _decision.replace_active
		or Registrar.physical_claims()[decision.source.identity] ~= nil then return false end
	return _spec.execute(decision.action, Policy.BINDING_ID)
end

--- Replaces the source proof only after exact prior owners have settled.
--- @return boolean accepted
function M.refresh()
	_generation = _generation + 1
	_decision = nil
	local cancelled = cancel_attempt()
	local released = release_native()
	if not cancelled or not released then return false end
	if not _started or _spec.action == "none" or _spec.context.legacy_present
		or _spec.context.assignment_unavailable then return true end
	local source_id = Probe.current_source_id()
	if source_id == nil then return true end
	local codes, seen = {}, {}
	for _, entry in pairs(registry()) do
		if entry.kind == "key" and type(entry.hs) == "number" and not seen[entry.hs] then
			seen[entry.hs] = true
			codes[#codes + 1] = entry.hs
		end
	end
	table.sort(codes)
	local attempt = {
		generation = _generation,
		source_id = source_id,
		trigger = _spec.context.trigger(),
		magic_source = _spec.context.magic_source(),
		replace_active = _spec.context.replace_active(),
		installing = true,
	}
	_attempt = attempt
	local operation = Probe.request({ source_id = source_id, codes = codes }, function(receipt, reason)
		if not current(attempt) then return end
		local decision = project(receipt, attempt)
		decision.source_id, decision.trigger = attempt.source_id, attempt.trigger
		decision.magic_source, decision.replace_active = attempt.magic_source, attempt.replace_active
		_decision = decision
		if not decision.active then
			Logger.debug(LOG, "Conditional editor shortcut is inactive: %s.", tostring(reason or decision.reason))
			return
		end
		_acquisition_depth = _acquisition_depth + 1
		local called, candidate = xpcall(Registrar.bind_conditional, debug.traceback,
			{ "ctrl" }, decision.source.native_code, deliver)
		_acquisition_depth = _acquisition_depth - 1
		if not called or candidate == nil then
			_decision = nil
			Logger.warn(LOG, "Conditional editor shortcut native acquisition was refused.")
			return
		end
		_handle = candidate
		if not current(attempt) then
			_decision = nil
			release_native()
		end
	end)
	attempt.operation, attempt.installing = operation, false
	operation.on_settled(function()
		if _attempt ~= attempt or not attempt.fenced or _cancel_depth ~= 0 then return end
		_attempt = nil
		if _started and M.refresh() ~= true then
			Logger.error(LOG, "Settled input-source proof retains native cleanup debt.")
		end
	end)
	if attempt.fenced then return cancel_attempt() end
	return true
end

--- Starts one ordinary conditional slot under its parent's generation fence.
--- @param spec table Canonical assignment, live context and parent admission.
--- @return boolean accepted
function M.start(spec)
	_spec = spec
	_started = true
	_subscribed = true
	if not Broker.subscribe(SUBSCRIBER, function()
		if M.refresh() ~= true then Logger.error(LOG, "Input-source retargeting has cleanup debt.") end
	end) then return false end
	return M.refresh()
end

--- Returns the shared reason without exposing mutable source receipts.
--- @return string|nil reason Canonical translated-policy reason.
function M.reason()
	if _spec == nil then return nil end
	if _spec.action == "none" then return "shortcut_disabled" end
	local admission = gates()
	if not admission.master then return "shortcuts_disabled" end
	if admission.paused then return "paused" end
	if admission.inhibited then return "inhibited" end
	if _spec.context.legacy_present or _spec.context.assignment_unavailable then return "explicit_assignment" end
	if _decision then return _decision.reason end
	return "source_unavailable"
end

--- Fences delivery before joining every exact native/probe/broker owner.
--- @return boolean settled
function M.stop()
	_started = false
	_generation = _generation + 1
	_decision = nil
	local cancelled = cancel_attempt()
	local released = release_native()
	local unsubscribed = not _subscribed
	if _subscribed then
		local called, released_broker = xpcall(Broker.unsubscribe, debug.traceback, SUBSCRIBER)
		unsubscribed = called and released_broker == true
	end
	if unsubscribed then _subscribed = false end
	return cancelled and released and unsubscribed and _acquisition_depth == 0
end

return M
