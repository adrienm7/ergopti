--- modules/shortcuts/actions/text_dispatch.lua

--- ==============================================================================
--- MODULE: Text Native Dispatch Ownership
--- DESCRIPTION:
--- Retains one exact synthetic transaction until its terminal callback. Clipboard
--- stages may start their grace delays only after the native payload handoff,
--- while a paused owner keeps cancellation debt until completion is observed.
--- ==============================================================================

local M = {}

--- Starts one transaction without confusing FIFO admission with completion.
--- @param input table SyntheticInput adapter.
--- @param owner table Exact Text owner.
--- @param publication table|nil Full and cached output predicates.
--- @param build function Receives the explicit transaction, returns true on admission.
--- @param completed function Receives the terminal status outside the input callback.
--- @param paste boolean|nil Observe native handoff even when later cancellation wins.
--- @return boolean started
--- @return any failure
function M.start(input, owner, publication, build, completed, paste)
	if owner.synthetic_pending == true then return false, "a text payload is still pending" end
	local tx
	local handed_off = false
	owner.synthetic_pending = true
	owner.synthetic_completion_registered = false
	owner.mutations = owner.mutations + 1
	local ok, failure = xpcall(function()
		tx = input.begin("shortcuts.text.transform", "action", publication)
		owner.synthetic_tx = tx
		if paste then
			input.on_dispatched(tx, function(finished, _, status)
				if owner.synthetic_tx == finished and status == "dispatched" then handed_off = true end
			end)
		end
		input.on_complete(tx, function(finished, status)
			if owner.synthetic_tx ~= finished or owner.synthetic_pending ~= true then return end
			owner.synthetic_pending = false
			owner.synthetic_tx = nil
			completed(status, handed_off)
		end)
		owner.synthetic_completion_registered = true
		assert(build(tx) == true, "text native payload admission was refused")
		assert(input.seal(tx) == true, "text native transaction seal was refused")
	end, debug.traceback)
	owner.mutations = owner.mutations - 1
	if ok then return true end
	if tx then
		local cancelled, result = pcall(input.cancel, tx)
		if cancelled and result == true and owner.synthetic_completion_registered ~= true then
			owner.synthetic_pending = false
			owner.synthetic_tx = nil
		end
	else
		owner.synthetic_pending = false
	end
	return false, failure
end

return M
