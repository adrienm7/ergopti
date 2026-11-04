--- _shared/lua/menu/frames/magic_frame.lua

--- ==============================================================================
--- MODULE: Menu Magic Trigger Frame Snapshot
--- DESCRIPTION:
--- Captures the declared magic-trigger frame of the shared manifest before a
--- native value reader can reenter it, and later proves that every captured
--- declaration identity and field is still the same.
---
--- FEATURES & RATIONALE:
--- 1. Raw reads only: `rawget`, `next` and `rawequal` keep source metamethods
---    from running while the frame is admitted or rechecked.
--- 2. Publication gate: a caller builds rows from the live frame, then asks
---    `current` whether the frame it captured is still the declared one; a
---    changed row withholds publication instead of publishing a stale tree.
--- 3. Pure Lua with no driver dependency: the renderer is injected, so the
---    macOS and Linux menus share one body and one contract.
--- ==============================================================================

local M = {}




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

--- Captures the actual declared frame before native value readers can reenter it.
--- @param renderer table Manifest renderer exposing `get_root`.
--- @param key string|nil Root key of the frame (default the magic trigger frame).
--- @param expected number|nil Required row count (default 3).
--- @return table|nil snapshot Opaque snapshot, nil when the frame is not plain.
function M.snapshot(renderer, key, expected)
	key, expected = key or "hotstrings_magic_trigger_frame", expected or 3
	local root = renderer.get_root()
	local frame = type(root) == "table" and rawget(root, key)
	if type(frame) ~= "table" or getmetatable(frame) ~= nil or #frame ~= expected then return nil end
	local slots = 0
	for index in next, frame do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > expected then return nil end
		slots = slots + 1
	end
	if slots ~= expected then return nil end
	local snapshot = {}
	for index, row in ipairs(frame) do
		if type(row) ~= "table" or getmetatable(row) ~= nil then return nil end
		local fields = {}
		for key, value in next, row do
			if type(value) == "table" then
				if getmetatable(value) ~= nil then return nil end
				local entries = {}
				for field, item in next, value do
					if type(item) == "table" or type(item) == "function" then return nil end
					entries[field] = item
				end
				fields[key] = { identity = value, entries = entries }
			elseif type(value) == "function" then return nil
			else fields[key] = value end
		end
		snapshot[index] = { identity = row, fields = fields }
	end
	return { root = root, frame = frame, rows = snapshot, key = key }
end

-- Publication is withheld when any captured declaration identity or field changed.

--- Whether the live frame is still exactly the captured one.
--- Publication is withheld when any captured declaration identity or field changed.
--- @param renderer table Manifest renderer exposing `get_root`.
--- @param snapshot table|nil Value returned by `snapshot`.
--- @return boolean
function M.current(renderer, snapshot)
	if not snapshot or not rawequal(renderer.get_root(), snapshot.root)
		or not rawequal(rawget(snapshot.root, snapshot.key), snapshot.frame)
		or getmetatable(snapshot.frame) ~= nil or #snapshot.frame ~= #snapshot.rows then return false end
	local slots = 0
	for index in next, snapshot.frame do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #snapshot.rows then return false end
		slots = slots + 1
	end
	if slots ~= #snapshot.rows then return false end
	for index, saved in ipairs(snapshot.rows) do
		local row = rawget(snapshot.frame, index)
		if not rawequal(row, saved.identity) or getmetatable(row) ~= nil then return false end
		local count, expected = 0, 0
		for key, value in next, row do
			count = count + 1
			local prior = saved.fields[key]
			if type(prior) == "table" then
				if not rawequal(value, prior.identity) or getmetatable(value) ~= nil then return false end
				local entries, wanted = 0, 0
				for field, item in next, value do
					entries = entries + 1
					if not rawequal(item, prior.entries[field]) then return false end
				end
				for _ in next, prior.entries do wanted = wanted + 1 end
				if entries ~= wanted then return false end
			elseif not rawequal(value, prior) then return false end
		end
		for _ in next, saved.fields do expected = expected + 1 end
		if count ~= expected then return false end
	end
	return true
end

return M
