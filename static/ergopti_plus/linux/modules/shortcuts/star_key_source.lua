--- modules/shortcuts/star_key_source.lua

--- ==============================================================================
--- MODULE: The ★ Key's Physical Source (Linux)
--- DESCRIPTION:
--- Proves which grabbed keys type the real ★ at their base level under the
--- session's XKB group, for the ★ key's ordinary slot (meta_star, Super+★,
--- _shared/shortcuts/engine/star_slot_core.lua). The shared policy selects the
--- unique direct source; this module only gathers the native evidence.
---
--- FEATURES & RATIONALE:
--- 1. Every candidate the native capture reports is kept, ★ or not: the shared
---    policy tells a missing, a modified, a dead and an ambiguous ★ apart.
--- 2. The configured magic key never moves the slot (maintainer's decision of
---    2026-11-21): the evidence names what each key types, nothing else.
--- 3. A key a tap-hold or a tap key owns is no direct source: its press never
---    types its character.
--- 4. One generation covers the native group and the evidence, so a queued
---    delivery is refused once either changed.
--- ==============================================================================

local M = {}

local Paths      = require("core.fs.engine.paths")
local FileSystem = require("core.fs.adapters.file_system")
local Json       = require("core.text.engine.json")

-- Decoded once: the physical-key registry, KeyboardEvent.code -> { evdev, ... }.
local _registry = nil
-- The daemon's collaborators, optional ports set once by M.init.
local _deps = nil
-- The last evidence signature and its generation.
local _signature, _generation = nil, 0





-- ===========================
-- ===========================
-- ======= 1/ Registry =======
-- ===========================
-- ===========================

--- The shared physical-key registry.
--- @return table registry
local function registry()
	if _registry then return _registry end
	local path = Paths.shared("layouts/data/keycodes/physical_keys.json")
	local text = path and FileSystem.read(path)
	if type(text) ~= "string" then error("the physical-key registry is unreadable: " .. tostring(path)) end
	local decoded = Json.decode(text)
	assert(type(decoded) == "table" and type(decoded.keys) == "table", "the physical-key registry is malformed")
	_registry = decoded
	return decoded
end

--- Registry identities admitted by the shared slot policy.
--- @return table known_codes KeyboardEvent.code -> true.
function M.known_codes()
	local known = {}
	for code in pairs(registry().keys) do known[code] = true end
	return known
end





-- ===========================
-- ===========================
-- ======= 2/ Evidence =======
-- ===========================
-- ===========================

--- Proves actual plain sources without selecting one or discarding ambiguity.
--- @return table source { generation, status, reason?, candidates }.
function M.source()
	local Capture = require("adapters.xkb_capture")
	local source_generation, direct_sources = Capture.source_generation, Capture.direct_sources
	local deps = _deps or {}
	local candidates, native_codes, codes, seen = {}, {}, {}, {}
	local xkb_generation, why, observed_current = source_generation()
	for code, record in pairs(registry().keys) do
		if type(record.evdev) == "number" then
			if not codes[record.evdev] or code < codes[record.evdev] then codes[record.evdev] = code end
			if not seen[record.evdev] then native_codes[#native_codes + 1] = record.evdev; seen[record.evdev] = true end
		end
	end
	table.sort(native_codes)
	local origin = deps.input_source_receipt and deps.input_source_receipt() or nil
	-- Keep primitive origin facts; later collaborators cannot rewrite this proof.
	if type(origin) == "table" then origin = { generation = origin.generation, ready = origin.ready } end
	local rows = xkb_generation and (origin == nil or origin.ready == true) and direct_sources(native_codes) or nil
	for _, row in ipairs(rows or {}) do
		local admitted = deps.direct_source_admitted == nil or deps.direct_source_admitted(row.code) == true
		candidates[#candidates + 1] = { code = codes[row.code], native_code = row.code,
			identity = "evdev:" .. row.code, text = row.text, native_text = row.text,
			direct = admitted and row.direct == true, dead = row.dead == true }
	end
	-- Rejoin the native owner after the admission callbacks: a group switch in
	-- between retires this evidence.
	local current = package.loaded["adapters.xkb_capture"] == Capture
		and Capture.source_generation == source_generation and Capture.direct_sources == direct_sources
	if current then
		local called, current_generation = pcall(source_generation)
		current = called and current_generation == xkb_generation
	end
	if current and origin ~= nil then
		local called, current_origin = pcall(deps.input_source_receipt)
		current = called and type(current_origin) == "table" and current_origin.ready == origin.ready
			and current_origin.generation == origin.generation
	end
	if current and type(observed_current) == "function" then
		local called, observed = pcall(observed_current)
		current = called and observed == true
	end
	if not current then rows, candidates, why = nil, {}, "direct-source-changed" end
	local signature = Json.encode({ native = xkb_generation, origin = origin, candidates = candidates })
	if signature ~= _signature then
		_signature = signature
		_generation = _generation + 1
	end
	return { generation = _generation, status = rows and "ready" or "unavailable",
		reason = rows and nil or (origin and origin.ready ~= true and "physical-origin-unqualified") or why
			or "direct-source-unavailable", candidates = candidates }
end





-- ============================
-- ============================
-- ======= 3/ Lifecycle =======
-- ============================
-- ============================

--- Wires the daemon's optional collaborators, once.
--- @param deps table { input_source_receipt fn() -> { generation, ready },
---   direct_source_admitted fn(evdev) -> boolean (a tap owner keeps the key) }
function M.init(deps)
	if _deps ~= nil then error("star_key_source: already initialized", 2) end
	if type(deps) ~= "table" then error("star_key_source.init needs its collaborators", 2) end
	for _, name in ipairs({ "input_source_receipt", "direct_source_admitted" }) do
		if deps[name] ~= nil and type(deps[name]) ~= "function" then
			error("star_key_source.init needs a callable " .. name, 2)
		end
	end
	_deps = deps
end

--- Test seam: forgets the collaborators and the evidence generation.
function M._reset_for_test()
	_deps, _signature, _generation, _registry = nil, nil, 0, nil
end

return M
