--- modules/shortcuts/key_combinations.lua

--- Canonical config-backed ordered pairs. Runtime selection and publication
--- retain separate exact leases; unknown/future pairs are never rewritten here.
local Shared = require("tap_hold.key_combinations")
local Codec = require("toml_codec")
local Files = require("adapters.file_system")
local ConfigPaths = require("infra.config_paths")
local Logger = require("logger.shim")
local HoldOptions = require("tap_hold.hold_options")
local M, instance = {}, nil
local function clone(map)
	local result = {}; for key, value in pairs(map) do result[key] = value end; return result
end
local function equal(left, right)
	for key, value in pairs(left) do if right[key] ~= value then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end
function M.new(options)
	assert(type(options) == "table" and type(options.keys) == "table" and type(options.is_paused) == "function" and type(options.changed) == "function")
	local files = options.files or Files
	local route = options.route or function() return ConfigPaths.config("config.toml") end
	local key_ids, known, holds = {}, {}, { none = true }
	for _, key in ipairs(options.keys) do
		assert(type(key.id) == "string" and type(key.key) == "string", "Linux physical catalogue required")
		key_ids[#key_ids + 1] = key.id
	end
	for _, first in ipairs(key_ids) do for _, second in ipairs(key_ids) do
		if first ~= second then known[Shared.pair(first, second)] = true end
	end end
	for _, hold in ipairs(HoldOptions.build(options.hold_picker)) do
		if hold.kind ~= "none" then holds[hold.id] = true end
	end
	local catalogue = options.actions or require("modules.gestures.manager")
	local owner, state, lease, generation, busy = {}, nil, nil, 0, false
	local delivery_fence
	-- A paused inverse may settle only the exact retained delivery fence. This
	-- authorizes source inspection, never ordinary edit or runtime delivery.
	local function pause_allowed(value, token, restoring)
		return value == false or restoring == true and value == true
			and type(token) == "table" and rawequal(delivery_fence, token)
	end
	local function candidate(document, strict)
		assert(type(document) == "table", "decoded canonical config required")
		local shortcuts = document.shortcuts
		assert(shortcuts == nil or type(shortcuts) == "table", "shortcut config shape refused")
		shortcuts = shortcuts or {}
		local taps, held = shortcuts.key_combination_taps or {}, shortcuts.key_combination_holds or {}
		assert(type(taps) == "table" and type(held) == "table", "pair slot shape refused")
		local result = { taps = {}, holds = {}, enabled = true }
		local categories = document.category_enabled
		assert(categories == nil or type(categories) == "table", "category config shape refused")
		if categories and categories.key_combinations ~= nil then
			assert(type(categories.key_combinations) == "boolean", "pair feature state must be boolean")
			result.enabled = categories.key_combinations
		end
		for pair in pairs(known) do
			local action, hold = taps[pair] or "none", held[pair] or "none"
			local action_ok = action == "none" or type(action) == "string" and catalogue.is_assignable(action)
			local hold_ok = type(hold) == "string" and holds[hold] == true
			assert(not strict or action_ok and hold_ok, "invalid known pair slot")
			result.taps[pair] = action_ok and action or "none"
			result.holds[pair] = hold_ok and hold or "none"
		end
		return result
	end
	local function read()
		local path = route()
		assert(type(path) == "string" and path:sub(1,1) == "/" and not path:find("\0",1,true), "pair canonical route refused")
		local bytes, status = files.read_with_status(path)
		assert(status == "ok" or status == "absent", "pair source unreadable")
		local document = status == "ok" and assert(Codec.decode(bytes)) or {}
		return candidate(document), path, bytes, status
	end
	local refused = false
	local function safe_read()
		local ok, selected, path, bytes, status = pcall(read)
		if not ok then
			if not refused then Logger.error("modules.shortcuts.key_combinations", "Canonical combination source refused; native admission is disabled.") end
			refused = true; return nil
		end
		refused = false
		return selected, path, bytes, status
	end
	state = safe_read() or candidate({}, false)
	function owner.has_bindings()
		if not state.enabled then return false end
		for pair in pairs(known) do if state.taps[pair] ~= "none" or state.holds[pair] ~= "none" then return true end end
		return false
	end
	function owner.get_action(pair) return known[pair] and state.taps[pair] or "none" end
	function owner.configuration_domain(binding)
		local pair = type(binding) == "string" and binding:match("^combination__(.+)$")
		return pair and known[pair] and "combination" or nil
	end
	function owner.get_hold(pair) return known[pair] and state.holds[pair] or Shared.NONE end
	function owner.is_enabled() return state.enabled == true end
	--- A private menu receipt; canonical bytes are never sent to the page.
	function owner.capture_edit_source(token, restoring)
		-- Paused compensation still owes exact source and private state ACKs.
		-- Only its retained delivery token can inspect the settled native frame;
		-- ordinary editors and runtime admission continue to require pause=false.
		local function permitted() return delivery_fence == nil or type(token) == "table" and delivery_fence == token end
		if busy or lease or not permitted() or not pause_allowed(options.is_paused(), token, restoring) then return nil end
		local prior, path, bytes, status = safe_read()
		if not prior then return nil end
		if prior.enabled ~= state.enabled or not equal(prior.taps,state.taps) or not equal(prior.holds,state.holds) then return nil end
		local captured, revision = state, generation
		local receipt = { path = path, status = status, content = status == "ok" and bytes or nil }
		receipt.guard = function()
			if busy or lease or not permitted() or state ~= captured or generation ~= revision or not pause_allowed(options.is_paused(), token, restoring) then return false end
			local routed, current_path = pcall(route)
			if not routed or current_path ~= path then return false end
			local called, current, current_status = pcall(files.read_with_status,path)
			local observed, paused = pcall(options.is_paused)
			local final_route, final_path = pcall(route)
			return called and current_status == status and (status ~= "ok" or current == bytes)
				and final_route and final_path == path and not busy and not lease and permitted()
				and state == captured and generation == revision and observed and pause_allowed(paused, token, restoring)
		end
		if receipt.guard() ~= true then return nil end
		return receipt
	end
	function owner.engine_options(thresholds)
		return { keys = clone(key_ids), taps = clone(state.taps), holds = clone(state.holds), thresholds = clone(thresholds),
			enabled = state.enabled and lease == nil and options.is_paused() == false, revision = generation, capture = owner.capture_runtime, capture_action = owner.capture_action }
	end
	local function same_route(path)
		local ok,current = pcall(route); return ok and current == path
	end
	function owner.capture_runtime()
		if busy or lease or delivery_fence or not state.enabled or options.is_paused() ~= false then return nil end
		local prior, path, bytes, status = safe_read()
		if not prior or status ~= "ok" or prior.enabled ~= state.enabled or not equal(prior.taps,state.taps) or not equal(prior.holds,state.holds) then return nil end
		local captured, revision = state, generation
		return function()
			if busy or lease or delivery_fence or state ~= captured or generation ~= revision or options.is_paused() ~= false or not same_route(path) then return false end
			local current_ok, current, current_status = pcall(files.read_with_status,path)
			-- Native route and pause getters may acquire a new configuration lease.
			-- Check private currency only after every external callback has returned.
			local pause_ok, paused = pcall(options.is_paused)
			local routed = same_route(path)
			return current_ok and current_status == "ok" and current == bytes and pause_ok and paused == false and routed
				and not busy and lease == nil and delivery_fence == nil and state == captured and generation == revision
		end
	end
	function owner.capture_action(binding, action)
		local pair = type(binding) == "string" and binding:match("^combination__(.+)$")
		if busy or lease or delivery_fence or not pair or not known[pair] or state.taps[pair] ~= action
			or not state.enabled or options.is_paused() ~= false then return nil end
		local prior, path, bytes, status = safe_read()
		if not prior or status ~= "ok" or prior.enabled ~= state.enabled or not equal(prior.taps,state.taps)
			or not equal(prior.holds,state.holds) then return nil end
		local revision, captured = generation, state
		return function()
			if busy or lease or delivery_fence or state ~= captured or generation ~= revision or not state.enabled
				or options.is_paused() ~= false or state.taps[pair] ~= action or not same_route(path) then return false end
			local current_ok, current, current_status = pcall(files.read_with_status,path)
			local pause_ok, paused = pcall(options.is_paused)
			local routed = same_route(path)
			return current_ok and current_status == "ok" and current == bytes and pause_ok and paused == false and routed
				and not busy and lease == nil and delivery_fence == nil and state == captured and generation == revision and state.enabled and state.taps[pair] == action
		end
	end
	function owner.acquire_configuration(token)
		if type(token) ~= "table" or busy or lease ~= nil and lease ~= token
			or delivery_fence ~= nil and delivery_fence ~= token then return false end
		lease, generation, busy = token, generation + 1, true
		local ok, stopped = pcall(options.changed)
		busy = false
		if not ok or stopped ~= true then return false end
		return true
	end
	--- Stages native installation without admitting delivery during terminal callbacks.
	function owner.acquire_delivery_fence(token)
		if type(token) ~= "table" or token ~= lease or busy
			or delivery_fence ~= nil and delivery_fence ~= token then return false end
		delivery_fence = token; return true
	end
	function owner.owns_delivery_fence(token) return type(token) == "table" and delivery_fence == token end
	--- The final private ACK has no external callbacks after it opens delivery.
	function owner.release_delivery_fence(token)
		if type(token) ~= "table" or delivery_fence ~= token or lease ~= nil or busy then return false end
		delivery_fence = nil; return true
	end
	function owner.configuration_pending() return lease ~= nil end
	function owner.owns_configuration(token) return type(token) == "table" and lease == token end
	function owner.validate_slot(kind, pair, value)
		if not known[pair] or type(value) ~= "string" then return false end
		if kind == "tap" then return value == "none" or catalogue.is_assignable(value) == true end
		if kind == "hold" then return holds[value] == true end
		return false
	end
	function owner.release_configuration(token)
		if token ~= lease or busy then return false end
		-- Resume only after the current desired state is physically installed.
		busy = true
		local prior = lease; lease = nil
		local ok, installed = pcall(options.changed)
		busy = false
		if not ok or installed ~= true then lease = prior; return false end
		return true
	end
	--- Reads a coherent source frame while the exact native lease is held.
	--- @param token table Exact configuration owner.
	--- @param restoring boolean|nil True permits a paused inverse under its retained delivery fence.
	function owner.configuration_source(token, restoring)
		if token ~= lease or busy or not pause_allowed(options.is_paused(), token, restoring) then return nil end
		local captured, revision = state, generation
		local prior, path, bytes, status = safe_read()
		local observed, paused = pcall(options.is_paused)
		local routed, current_path = pcall(route)
		if not prior or not routed or current_path ~= path or not observed or not pause_allowed(paused, token, restoring)
			or token ~= lease or busy or state ~= captured or generation ~= revision
			or prior.enabled ~= state.enabled or not equal(prior.taps,state.taps) or not equal(prior.holds,state.holds) then return nil end
		return {path=path,status=status,content=status == "ok" and bytes or nil}
	end
	--- Checks source identity after external native callbacks without requiring
	--- the candidate state to equal the previous unpublished runtime snapshot.
	--- @param token table Exact configuration owner.
	--- @param source table Exact canonical source frame.
	--- @param restoring boolean|nil True permits a paused inverse under its retained delivery fence.
	function owner.configuration_source_matches(token, source, restoring)
		if token ~= lease or busy or type(source) ~= "table" or not pause_allowed(options.is_paused(), token, restoring) then return false end
		local captured, revision = state, generation
		local prior, path, bytes, status = safe_read()
		local observed, paused = pcall(options.is_paused)
		local routed, current_path = pcall(route)
		return prior ~= nil and routed and current_path == path and observed and pause_allowed(paused, token, restoring)
			and path == source.path and status == source.status and (status ~= "ok" or bytes == source.content)
			and token == lease and not busy and state == captured and generation == revision
	end
	function owner.configuration_snapshot(token)
		if lease ~= token then return nil end
		return { taps = clone(state.taps), holds = clone(state.holds), enabled = state.enabled }
	end
	function owner.configuration_candidate(document, strict) return candidate(document,strict) end
	function owner.apply_configuration(token, selected)
		if lease ~= token or busy or type(selected) ~= "table" then return false end
		local copy = candidate({shortcuts={key_combination_taps=selected.taps,key_combination_holds=selected.holds},
			category_enabled={key_combinations=selected.enabled}},true)
		state, generation, busy = copy, generation + 1, true
		local ok, installed = pcall(options.changed)
		busy = false
		return ok and installed == true
	end
	return owner
end
function M.set_instance(owner)
	if type(owner) ~= "table" or type(owner.capture_runtime) ~= "function" then return false end
	instance = owner; return true
end
function M.install(options)
	if instance then return false end
	instance = M.new(options)
	return true
end
for _, name in ipairs({"get_action","get_hold","is_enabled","capture_edit_source","has_bindings","configuration_domain","capture_action","engine_options",
	"capture_runtime","acquire_delivery_fence","owns_delivery_fence","release_delivery_fence","configuration_pending","owns_configuration","validate_slot","acquire_configuration","release_configuration","configuration_snapshot","configuration_source","configuration_source_matches","configuration_candidate","apply_configuration"}) do
	M[name] = function(...)
		if not instance then return name == "get_action" and "none" or nil end
		return instance[name](...)
	end
end
return M
