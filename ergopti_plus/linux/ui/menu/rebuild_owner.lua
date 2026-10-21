--- ui/menu/rebuild_owner.lua

--- ==============================================================================
--- MODULE: Coalesced Native Tray Publication
--- DESCRIPTION:
--- Retires old action authority on a refresh request and publishes at most one
--- current tree per pump. Native GTK objects and their IDs remain tray-owned.
--- ==============================================================================

local M = {}

--- Creates a pure-RAM owner; callers pump after physical input admission.
--- @param options table Pinned build, publish, current and optional appearance/error callbacks.
--- @return table owner
function M.new(options)
	assert(type(options) == "table", "menu rebuild options are required")
	local build, publish, current = options.build, options.publish, options.current
	local appearance, on_error = options.appearance, options.on_error
	assert(type(build) == "function" and type(publish) == "function"
		and type(current) == "function", "menu rebuild ports are required")
	assert(appearance == nil or type(appearance) == "function", "menu appearance port must be callable")
	assert(on_error == nil or type(on_error) == "function", "menu error port must be callable")
	local generation, published, dirty, stopped, pumping = 0, nil, false, false, false
	local reported_generation, reported_reason
	local owner = {}

	local function live(epoch)
		if stopped or generation ~= epoch then return false end
		local ok, accepted = pcall(current)
		return ok and accepted == true and not stopped and generation == epoch
	end

	local function report(epoch, reason)
		if reported_generation == epoch and reported_reason == reason then return end
		reported_generation, reported_reason = epoch, reason
		if on_error then pcall(on_error, reason) end
	end

	--- Copies newly built rows; an old native ID never gains a successor action.
	local function bind(items, epoch, ancestors)
		assert(type(items) == "table" and not ancestors[items], "menu tree must be acyclic")
		ancestors[items] = true
		local rows = {}
		for index, item in ipairs(items) do
			assert(type(item) == "table", "menu rows must be tables")
			local row = {}
			for key, value in pairs(item) do row[key] = value end
			if type(row.menu) == "table" then row.menu = bind(row.menu, epoch, ancestors) end
			local action = row.fn
			if type(action) == "function" then
				row.fn = function(...)
					if pumping or published ~= epoch or not live(epoch) then return false end
					return action(...)
				end
			end
			rows[index] = row
		end
		ancestors[items] = nil
		return rows
	end

	--- Revokes existing callbacks immediately without entering GTK or the builder.
	--- @return boolean accepted Refresh request, never a publication receipt.
	function owner.request()
		if stopped then return false end
		generation, dirty = generation + 1, true
		return true
	end

	--- Publishes one latest generation; refusals remain dirty for the next pump.
	--- @return boolean acknowledged Current menu accepted by the native publisher.
	--- @return string|nil reason Idle, retired generation or contained refusal.
	function owner.pump()
		if stopped then return false, "stopped" end
		if pumping then return false, "busy" end
		if not dirty then return false, "idle" end
		local epoch = generation
		pumping = true
		if not live(epoch) then pumping = false; return false, "retired" end
		local ok, items, state = pcall(build)
		if ok and live(epoch) then ok, items = pcall(bind, items, epoch, {}) end
		if not live(epoch) then pumping = false; return false, "retired" end
		if not ok then
			report(epoch, "build-refused"); pumping = false; return false, "build-refused"
		end
		local called, accepted = pcall(publish, items)
		if not live(epoch) then pumping = false; return false, "retired" end
		if not called or accepted ~= true then
			report(epoch, "publication-refused"); pumping = false; return false, "publication-refused"
		end
		published, dirty = epoch, false
		if appearance and live(epoch) then
			local applied, result = pcall(appearance, state)
			if not applied or result == false then report(epoch, "appearance-refused") end
		end
		local retained = live(epoch)
		pumping = false
		if not retained then return false, "retired" end
		return true
	end

	--- Permanently retires queued work and every action without touching GTK.
	--- @return boolean acknowledged No resource is acquired by this owner.
	function owner.stop()
		if not stopped then generation = generation + 1 end
		stopped, dirty, published = true, false, nil
		return true
	end

	return owner
end

return M
