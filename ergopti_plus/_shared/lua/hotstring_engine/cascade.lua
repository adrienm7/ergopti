--- _shared/lua/hotstring_engine/cascade.lua

--- ==============================================================================
--- MODULE: Hotstring Cascade Net Edit
--- DESCRIPTION:
--- The loop that turns a chain of hotstring expansions into ONE net edit: the
--- text a first expansion produced may complete further hotstrings, and the
--- application must receive a single replacement, never the intermediate texts.
---
--- The chain runs on a virtual copy of the buffer before anything is typed. What
--- is shared here is everything that is not a question about the registry: the
--- virtual buffer, the arrow bound, the same-spec guard, the end character that
--- travels through the chain, the untouched prefix of the screen and the net
--- backspace count and replacement. What differs per driver is only the question
--- "which hotstring does this buffer complete?", which each driver answers through
--- the `pick` port, and its per-step delay, which it answers in the step's
--- `admit` callback.
---
--- Pure: no logger state, no registry, no clock, no platform.
--- ==============================================================================

local Logger = require("logger.shim")

local LOG = "shared.hotstring_engine.cascade"

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Codepoints ==============
-- ====================================
-- ====================================

--- Splits a UTF-8 string into its codepoints (a bare continuation byte counts as one).
--- @param s string
--- @return table cps Array of single-codepoint strings.
function M.codepoints(s)
	local cps = {}
	local i = 1
	while i <= #s do
		local b = s:byte(i)
		local len
		if b < 0xC0 then len = 1
		elseif b < 0xE0 then len = 2
		elseif b < 0xF0 then len = 3
		else len = 4
		end
		len = math.min(len, #s - i + 1)
		cps[#cps + 1] = s:sub(i, i + len - 1)
		i = i + len
	end
	return cps
end





-- ====================================
-- ====================================
-- ======= 2/ The Chain ===============
-- ====================================
-- ====================================

--- Runs the chain and returns the net edit, or nil when the first step has no successor.
---
--- The `pick` port receives the virtual buffer the previous step produced (array
--- of codepoints), the time stamps parallel to it, the end character still
--- carried (nil when none), and how many codepoints at the start of the buffer no
--- step has touched. It returns nil to stop the chain, or a step
--- `{ key, backspace_count, replacement, final_result, trigger_length, admit }`:
--- `backspace_count` codepoints are erased from the END of the virtual buffer
--- (the carried end character included), `replacement` replaces them and the
--- carried end character is appended after it. `admit()`, when present, is
--- called last and may refuse the step by returning anything but true; it runs
--- after the same-spec guard so a refused repeat never reaches a delay.
---
--- The chain also stops at the arrow bound and after a `final_result` link.
--- @param spec table {
---   buffer = table (codepoints, read-only), times = table|nil (parallel stamps),
---   stamp = any (the stamp every produced codepoint carries),
---   first = { key, backspace_count, replacement, terminator = string|nil, final_result },
---   max_arrows = number (whole, >= 2), pick = function }
--- @return table|nil net { stable, backspace_count, replacement, terminator, final_result, steps }
---   `stable` counts the untouched leading codepoints of the buffer; `terminator`
---   is the end character still to replay.
function M.resolve(spec)
	local first = spec.first
	local original_len = #spec.buffer
	local vcps, vtimes = {}, {}
	for index = 1, original_len do
		vcps[index] = spec.buffer[index]
		vtimes[index] = spec.times and spec.times[index] or false
	end
	local stamp = spec.stamp or false
	local stable = original_len

	local function apply(erase, text, terminator)
		for _ = 1, erase do
			if #vcps == 0 then break end
			vcps[#vcps] = nil
			vtimes[#vtimes] = nil
		end
		if #vcps < stable then stable = #vcps end
		for _, cp in ipairs(M.codepoints(text)) do
			vcps[#vcps + 1] = cp
			vtimes[#vtimes + 1] = stamp
		end
		if terminator then
			for _, cp in ipairs(M.codepoints(terminator)) do
				vcps[#vcps + 1] = cp
				vtimes[#vtimes + 1] = stamp
			end
		end
	end

	local seen = { [first.key] = true }
	local last_final = first.final_result
	local terminator = first.terminator
	local steps = 1
	apply(first.backspace_count, first.replacement, terminator)

	while steps < spec.max_arrows and not last_final do
		local step = spec.pick(vcps, vtimes, terminator, stable)
		if not step then break end
		if seen[step.key] then
			Logger.debug(LOG, "Cascade stopped at step %d: the same spec would fire again.", steps)
			break
		end
		if step.admit ~= nil and step.admit() ~= true then
			Logger.debug(LOG, "Cascade stopped at step %d: the step's gate refused it.", steps)
			break
		end
		seen[step.key] = true
		apply(step.backspace_count, step.replacement, terminator)
		last_final = step.final_result
		steps = steps + 1
		Logger.debug(LOG, "Cascade step %d fired (trigger of %d char(s)).", steps - 1, step.trigger_length or 0)
	end
	if steps == 1 then return nil end

	local produced_end = #vcps - (terminator and #M.codepoints(terminator) or 0)
	return {
		stable          = stable,
		backspace_count = original_len - stable,
		replacement     = table.concat(vcps, "", stable + 1, produced_end),
		terminator      = terminator,
		final_result    = last_final,
		steps           = steps,
	}
end

return M
