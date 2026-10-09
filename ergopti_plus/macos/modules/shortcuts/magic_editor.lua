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
local original_source_id = rawget(Probe, "current_source_id")
local original_request = rawget(Probe, "request")
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

--- Retains the exact source issuer loaded before any external constructor read.
--- Replacement values cannot publish signed-source proof through this owner.
local function probe_current()
	return rawequal(package.loaded["adapters.keyboard_source_probe"], Probe)
		and getmetatable(Probe) == nil and type(original_source_id) == "function"
		and type(original_request) == "function"
		and rawequal(rawget(Probe, "current_source_id"), original_source_id)
		and rawequal(rawget(Probe, "request"), original_request)
end

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

--- Rejoins only the spec/ports from this attempt's construction frame.
--- Parent configuration and context callbacks are trusted constructor-owned
--- inputs; a true callback result never authenticates a replacement frame.
local function attempt_matches(attempt)
	local spec, context, ports = attempt.spec, attempt.context, attempt.ports
	if not probe_current() or not _started or _spec ~= spec or attempt.generation ~= _generation
		or spec.context ~= context or spec.action ~= attempt.action
		or spec.configuration_generation ~= attempt.configuration
		or spec.is_current ~= ports.is_current or spec.is_action ~= ports.is_action
		or context.legacy_present ~= attempt.legacy_present
		or context.assignment_unavailable ~= attempt.assignment_unavailable
		or Probe.current_source_id ~= ports.source_id then return false end
	for _, name in ipairs({ "trigger", "magic_source", "replace_active", "paused", "inhibited" }) do
		if context[name] ~= ports[name] then return false end
	end
	return true
end

--- Validates callback observations before a final private attempt check.
local function current(attempt)
	local function owned()
		return _attempt == attempt and attempt.fenced ~= true and attempt_matches(attempt)
	end
	local function observe(callback)
		if not owned() then return nil end
		local value = callback()
		if not owned() then return nil end
		return value
	end
	local ports = attempt.ports
	return observe(ports.trigger) == attempt.trigger
		and observe(ports.magic_source) == attempt.magic_source
		and observe(ports.replace_active) == attempt.replace_active
		and observe(ports.source_id) == attempt.source_id
		and observe(ports.is_current) == true and owned()
end

local function project(receipt, attempt)
	local context = attempt.context
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
		stored_action = attempt.action,
		is_action = attempt.ports.is_action,
		trigger = attempt.trigger,
		source = {
			generation = attempt.generation,
			status = receipt and attempt.replace_active ~= nil and "ready" or "unavailable",
			candidates = candidates,
		},
		known_codes = known,
		explicit_claims = Registrar.physical_claims(),
		configuration_generation = attempt.configuration,
		admission = {
			master = _started and attempt.ports.is_current() == true,
			paused = context.paused() ~= false,
			inhibited = context.inhibited() ~= false,
		},
	})
end

--- Joins callback observations to the same retained conditional owner.
--- Context/native reads may retire or replace this owner synchronously. Never
--- reread cleared globals or execute a successor through the captured callback.
--- @return boolean accepted
local function deliver()
	local decision, spec, handle, epoch = _decision, _spec, _handle, _generation
	if _acquisition_depth ~= 0 or not decision or not spec or handle == nil
		or spec.context.legacy_present or spec.context.assignment_unavailable then return false end
	local context, action, configuration = spec.context, spec.action, spec.configuration_generation
	local ports = {
		is_current = spec.is_current, execute = spec.execute,
		paused = context.paused, inhibited = context.inhibited, trigger = context.trigger,
		magic_source = context.magic_source, replace_active = context.replace_active,
	}
	local source_id = original_source_id
	local function owner_current()
		if not probe_current() or not _started or _spec ~= spec or _decision ~= decision or _handle ~= handle
			or _generation ~= epoch or _acquisition_depth ~= 0 or _cancel_depth ~= 0
			or spec.context ~= context or spec.action ~= action or spec.configuration_generation ~= configuration
			or context.legacy_present or context.assignment_unavailable
			or spec.is_current ~= ports.is_current or spec.execute ~= ports.execute
			or Probe.current_source_id ~= source_id then return false end
		for _, name in ipairs({ "paused", "inhibited", "trigger", "magic_source", "replace_active" }) do
			if context[name] ~= ports[name] then return false end
		end
		return true
	end
	local function observe(callback)
		if not owner_current() then return nil end
		local value = callback()
		if not owner_current() then return nil end
		return value
	end
	local effective_action = action or Manifest.default_for(Policy.PATH)
	local paused, inhibited = observe(ports.paused), observe(ports.inhibited)
	if paused ~= false or inhibited ~= false
		or observe(ports.trigger) ~= decision.trigger
		or observe(ports.magic_source) ~= decision.magic_source
		or observe(ports.replace_active) ~= decision.replace_active then return false end
	-- Join source and parent after the final context callback, then leave only
	-- exact private identity checks after those external observations.
	if observe(source_id) ~= decision.source_id or observe(ports.is_current) ~= true
		or not Policy.can_deliver(decision, {
			source_generation = epoch, configuration_generation = configuration,
			action = effective_action, master = true, paused = paused, inhibited = inhibited,
		}) or Registrar.physical_claims()[decision.source.identity] ~= nil
		or not owner_current() then return false end
	return ports.execute(decision.action, Policy.BINDING_ID)
end

--- Replaces the source proof only after exact prior owners have settled.
--- @return boolean accepted
function M.refresh()
	_generation = _generation + 1
	_decision = nil
	local cancelled = cancel_attempt()
	local released = release_native()
	if not cancelled or not released then return false end
	if not probe_current() then return false end
	if not _started or _spec.action == "none" or _spec.context.legacy_present
		or _spec.context.assignment_unavailable then return true end
	local spec, context = _spec, _spec.context
	local attempt = {
		generation = _generation, spec = spec, context = context,
		action = spec.action, configuration = spec.configuration_generation,
		legacy_present = context.legacy_present, assignment_unavailable = context.assignment_unavailable,
		ports = {
			source_id = original_source_id, is_current = spec.is_current, is_action = spec.is_action,
			trigger = context.trigger, magic_source = context.magic_source, replace_active = context.replace_active,
			paused = context.paused, inhibited = context.inhibited,
		},
		installing = true,
	}
	local source_id = attempt.ports.source_id()
	if not attempt_matches(attempt) or _attempt ~= nil then return false end
	if source_id == nil then return true end
	local codes, seen = {}, {}
	for _, entry in pairs(registry()) do
		if entry.kind == "key" and type(entry.hs) == "number" and not seen[entry.hs] then
			seen[entry.hs] = true
			codes[#codes + 1] = entry.hs
		end
	end
	table.sort(codes)
	if not attempt_matches(attempt) or _attempt ~= nil then return false end
	attempt.source_id = source_id
	for _, name in ipairs({ "trigger", "magic_source", "replace_active" }) do
		attempt[name] = attempt.ports[name]()
		if not attempt_matches(attempt) or _attempt ~= nil then return false end
	end
	_attempt = attempt
	local operation = original_request({ source_id = source_id, codes = codes }, function(receipt, reason)
		if not current(attempt) then return end
		local decision = project(receipt, attempt)
		if not current(attempt) then return end
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
	if not probe_current() then
		attempt.fenced = true
		cancel_attempt()
		return false
	end
	if attempt.fenced then return cancel_attempt() end
	return true
end

--- Starts one ordinary conditional slot under its parent's generation fence.
--- @param spec table Canonical assignment, live context and parent admission.
--- @return boolean accepted
function M.start(spec)
	if not probe_current() then return false end
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
