--- modules/hotstrings/engine.lua

--- ==============================================================================
--- MODULE: Hotstring Engine (Linux — thin re-export)
--- DESCRIPTION:
--- Re-exports the canonical pure-Lua hotstring engine from the shared library
--- at _shared/lua/hotstring_engine/. Placing the canonical implementation in
--- _shared/ lets every Lua-based driver (Hammerspoon, Linux, future drivers)
--- share a single source of truth for the matching algorithm.
---
--- All matching logic, tail-char bucketing, longest-match-first sorting, word
--- boundary enforcement, and the Logger shim live in the shared module. This
--- file is intentionally minimal — it adjusts the Lua search path, counts and
--- times each on_char call (infra/perf_counters), and
--- delegates to the canonical implementation.
--- ==============================================================================

-- Resolve the path to _shared/lua/ relative to this file's location so the
-- engine can be required without the caller needing to configure LUA_PATH.
-- __FILE__ is not available in standard Lua; we use a debug trick that works
-- in both LuaJIT and Lua 5.4 (which both support debug.getinfo).
local _this_file = debug.getinfo(1, "S").source:gsub("^@", "")
-- Navigate: …/linux/modules/hotstrings/ → …/linux/ → …/_shared/lua/
--
-- _linux_root already IS the driver root — the pattern above strips
-- modules/hotstrings/ — so _shared is ONE level up, not two. This read "../../"
-- and resolved outside the tree entirely, so the shared engine was never added
-- to package.path from here; whatever else had already put it there was
-- carrying this module. It runs before package.path is set, which is why it
-- resolves by hand rather than through lib.paths: requiring the resolver here
-- would need the very path it is computing. tools/test/
-- test-linux-shared-path-resolver.cjs asserts this depth instead.
-- A backslash is a Linux filename byte, and the shared path owner is not yet
-- reachable: split at slashes alone.
local _linux_root = _this_file:match("^(.*/)modules/hotstrings/")
local _shared_lua = _linux_root and (_linux_root .. "../_shared/lua") or nil

if _shared_lua then
	-- Prepend to package.path only when the entry is not already present.
	local entry = _shared_lua .. "/?.lua"
	if not package.path:find(entry, 1, true) then
		package.path = entry .. ";" .. package.path
	end
end

-- Delegate to the shared implementation; the only addition is the permanent
-- match counter and (at DEBUG) timing span, kept here so the shared engine,
-- which the other drivers load, carries no Linux-only instrumentation.
local Shared = require("hotstring_engine")
local Perf = require("infra.perf_counters")

local M = setmetatable({}, { __index = Shared })

--- Creates a shared engine whose on_char is counted and timed, and whose edits
--- an attached AI typing context mirrors.
--- @return table engine
function M.new(...)
	local engine = Shared.new(...)
	local shared_on_char = engine.on_char
	local shared_backspace = engine.backspace
	local shared_apply_expansion = engine.apply_expansion
	local shared_reset = engine.reset
	-- The AI typing context (modules/llm/context.lua), nil on an engine whose
	-- owner has none: the hotstring matcher itself never depends on it.
	local ai_context = nil

	--- Attaches the observer that mirrors this engine's edits for the AI.
	--- @param context table typed(), backspaced(), replaced(), reset(), navigated(), text().
	function engine:attach_ai_context(context)
		if ai_context ~= nil then error("an AI context is already attached to this engine", 2) end
		if type(context) ~= "table" then error("the AI context must be a table", 2) end
		ai_context = context
	end

	--- The attached AI typing context.
	--- @return table|nil context
	function engine:ai_context() return ai_context end

	function engine:on_char(ch, opts)
		local started = Perf.clock()
		local result = shared_on_char(self, ch, opts)
		Perf.span("hotstring.match", started)
		if result then Perf.count("hotstring.matches") end
		-- Every character is typed text, a match included: the expansion that
		-- replaces it is reported once the driver commits it (apply_expansion).
		if ai_context and type(ch) == "string" and ch ~= "" then ai_context:typed(ch) end
		return result
	end

	function engine:backspace()
		shared_backspace(self)
		if ai_context then ai_context:backspaced() end
	end

	function engine:apply_expansion(result)
		shared_apply_expansion(self, result)
		if ai_context and type(result) == "table" then
			-- The text the application now holds in place of the erased trigger,
			-- the replayed terminator included (the shared engine's own rule).
			local produced = (result.replacement or "")
				.. ((result.end_char and not result.consume_terminator) and (result.terminator or "") or "")
			ai_context:replaced(tonumber(result.backspace_count) or 0, produced, result.is_private)
		end
	end

	--- Clears the word buffer. The AI context follows it (the field is no longer
	--- described) unless the caller says what the reset means for the AI.
	--- @param at_boundary boolean|nil As for the shared engine.
	--- @param at_line_start boolean|nil As for the shared engine.
	--- @param ai_effect string|nil "keep" when the AI context is not affected (an
	---   expansion already mirrored by apply_expansion or replaced(), an accepted
	---   prediction), "navigation" when the reset is a caret move the AI context
	---   treats by `llm.generation.reset_on_nav`; omitted forgets it.
	function engine:reset(at_boundary, at_line_start, ai_effect)
		shared_reset(self, at_boundary, at_line_start)
		if not ai_context then return end
		if ai_effect == "navigation" then
			ai_context:navigated()
		elseif ai_effect ~= "keep" then
			ai_context:reset()
		end
	end

	-- reset_after_pause() resets through engine.reset, so a pause forgets the AI
	-- context too, as it does on macOS.

	--- Reports text the driver produced outside the matcher's own expansions (a
	--- dynamic hotstring) to the AI context: `deletes` codepoints of the field
	--- became `text`.
	--- @param deletes integer Codepoints erased.
	--- @param text string What the application received instead.
	--- @param is_private boolean|nil True when the text is a secret.
	function engine:replaced(deletes, text, is_private)
		if ai_context then ai_context:replaced(deletes, text, is_private) end
	end

	--- Forgets the AI context alone, for an edit the word buffer already handles
	--- on its own terms (a paste, a cut, an undo).
	function engine:forget_ai_context()
		if ai_context then ai_context:reset() end
	end

	--- Reports a navigation key, a click or a shortcut that leaves the word buffer
	--- alone to the AI context, whatever the hotstring word-reset options decide.
	function engine:navigated()
		if ai_context then ai_context:navigated() end
	end

	return engine
end

return M
