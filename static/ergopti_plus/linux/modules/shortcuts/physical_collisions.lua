--- modules/shortcuts/physical_collisions.lua

--- Joins four captured Linux claim families to the original physical-chord source.
--- This preflight is partial; it never publishes all-owner or output readiness.
local Policy = require("shortcuts.physical_conflicts")
local M = {}
local conflicts = Policy.conflicts

--- Binds original owner ports; validation acquires no input/output or file lease.
function M.new(keyboard, taps, combinations, manager, capture)
	local owners = { [1] = keyboard, [2] = taps, [3] = combinations, [4] = manager }
	local methods = {}
	for index = 1, 4 do
		local owner = owners[index]
		methods[index] = type(owner) == "table" and rawget(owner, "capture_collision_inventory") or nil
	end
	local descriptor, native_code, identity = keyboard.physical_slot_descriptor, keyboard.physical_native_code, keyboard.collision_identity
	local source, view, sealed = capture.chord_sources, capture.chord_source_view, capture.chord_source_current
	local function ports_current()
		for index = 1, 4 do
			local owner = owners[index]
			if type(methods[index]) ~= "function" or getmetatable(owner) ~= nil
				or rawget(owner, "capture_collision_inventory") ~= methods[index] then return false end
		end
		return rawequal(package.loaded["shortcuts.physical_conflicts"], Policy) and Policy.conflicts == conflicts
			and keyboard.physical_slot_descriptor == descriptor and keyboard.physical_native_code == native_code
			and keyboard.collision_identity == identity and type(native_code) == "function" and type(identity) == "function"
			and capture.chord_sources == source and capture.chord_source_view == view and capture.chord_source_current == sealed
			and type(source) == "function" and type(view) == "function" and type(sealed) == "function"
			and rawequal(package.loaded["modules.shortcuts.keyboard_shortcuts"], keyboard)
			and rawequal(package.loaded["modules.shortcuts.tap_keys"], taps)
			and rawequal(package.loaded["modules.shortcuts.key_combinations"], combinations)
			and rawequal(package.loaded["platform.remap.tap_hold_manager"], manager)
			and rawequal(package.loaded["adapters.xkb_capture"], capture)
	end
	local owner = {}
	function owner.validate(updates)
		if not ports_current() then return false, "unavailable" end
		local frames, claims = {}, {}
		for index, method in ipairs(methods) do
			local frame = method()
			if type(frame) ~= "table" or getmetatable(frame) ~= nil or type(frame.current) ~= "function"
				or type(frame.sealed) ~= "function" or frame.current() ~= true or type(frame.claims) ~= "table" then return false, "source_changed" end
			frames[index] = frame
			if index < 4 and index > 1 and (frame.path ~= frames[1].path or frame.content ~= frames[1].content
				or frame.status ~= frames[1].status) then return false, "source_changed" end
			if index ~= 3 then for _, claim in ipairs(frame.claims) do claims[#claims + 1] = claim end end
		end
		for _, pair in ipairs(frames[3].claims) do
			local first, second = frames[4].codes[pair.first], frames[4].codes[pair.second]
			if type(first) ~= "number" or type(second) ~= "number" then return false, "source_changed" end
			claims[#claims + 1] = { kind = "prefix", binding = pair.binding, codes = { first, second }, unmodified_only = true }
		end
		local requests, candidates = {}, {}
		for _, update in ipairs(updates) do
			if update.section == "shortcuts.keyboard" and update.delete ~= true and update.value ~= "none" then
				local row, code = descriptor(update.key), native_code(update.key)
				if not row or type(code) ~= "number" then return false, "save_failed" end
				requests[#requests + 1] = { code = code, mods = row.mods }
				candidates[#candidates + 1] = { slot = update.key, action = update.value, code = code, mods = row.mods, aliases = {} }
			end
		end
		if #requests == 0 then return false, "unavailable" end -- Parameter-only writes have no new input identity here.
		local token = source(requests)
		local observed = token and view(token)
		if type(observed) ~= "table" or type(observed.chords) ~= "table" or #observed.chords ~= #requests * 2 then return false, "unavailable" end
		for index, row in ipairs(observed.chords) do
			local candidate = candidates[math.floor((index + 1) / 2)]
			local alias = type(row.identity) == "string" and identity(row.identity) or nil
			if not candidate or row.code ~= candidate.code or type(alias) ~= "string" then return false, "unavailable" end
			candidate.aliases[alias] = true
		end
		local function current()
			if not ports_current() or sealed(token) ~= true then return false end
			for _, frame in ipairs(frames) do if frame.current() ~= true then return false end end
			if not ports_current() or sealed(token) ~= true then return false end
			-- Rejoin every private runtime epoch after the last source observer.
			for _, frame in ipairs(frames) do if frame.sealed() ~= true then return false end end
			return ports_current()
		end
		if not current() then return false, "source_changed" end
		for _, candidate in ipairs(candidates) do
			local collision = conflicts(candidate, claims)
			if collision == nil then return false, "unavailable" end
			if collision then
				return false, current() and "collision" or "source_changed"
			end
		end
		if not current() then return false, "source_changed" end
		return true
	end
	return owner
end
return M
