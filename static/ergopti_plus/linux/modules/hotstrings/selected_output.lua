--- modules/hotstrings/selected_output.lua

--- ==============================================================================
--- MODULE: Staged Selected Output (Linux)
--- DESCRIPTION:
--- Pins one output route across clipboard preparation and two short native
--- transactions. Cold range observations never hold modifier custody.
--- ==============================================================================
local M = {}
local Layout = require("adapters.keyboard_layout")
local Clipboard = require("adapters.clipboard")
local Broker = require("adapters.modifier_broker")

--- Constructs a reversible selected-output owner without desktop I/O.
--- @param text string Private replacement bytes.
--- @param publication table Original action and exact field authority.
--- @param ports table Captured injector primitives; never refreshed between phases.
--- @return table stage
function M.new(text, publication, ports)
	assert(type(text) == "string" and text ~= "", "selected output requires text")
	local stage, clip, route, plan = {}, nil, nil, nil
	local prepared, busy, revoked, payload_written, key_cleanup = false, false, false, false, true
	local channel = ports.channel
	local emit = type(channel) == "table" and channel.emit or nil
	local is_open = type(channel) == "table" and channel.is_open or nil
	local broker, binding = Broker.for_channel(channel)
	local output_current = broker and broker.output_current
	local layout_plan, layout_current, layout_view, shortcut = Layout.plan, Layout.plan_current, Layout.plan_view, Layout.shortcut_keycode
	local paste_keycode = Clipboard.paste_keycode
	local receipt
	local data_codes = {}

	local function pinned()
		local current, observer = Broker.for_channel(channel)
		return ports.current_channel() == channel and type(channel) == "table"
			and channel.emit == emit and channel.is_open == is_open and current == broker and observer == binding
			and Clipboard.paste_keycode == paste_keycode
			and (not broker or (binding(broker) == true and broker.output_current == output_current))
	end
	local function admitted(cached)
		if revoked or not pinned() then return false end
		local check = cached and publication.cached or publication.current
		local ok, allowed = pcall(check)
		if not ok or allowed ~= true or revoked or not pinned() then return false end
		if receipt then
			if Layout.plan ~= layout_plan or Layout.plan_current ~= layout_current or Layout.plan_view ~= layout_view
				or Layout.shortcut_keycode ~= shortcut then return false end
			ok, allowed = pcall(layout_current, receipt, cached)
			if not ok or allowed ~= true or revoked or not pinned() then return false end
		end
		ok, allowed = pcall(publication.cached)
		return ok and allowed == true and not revoked and pinned()
	end
	local joined = { current = function() return admitted(false) end, cached = function() return admitted(true) end }
	local function current()
		if busy or not admitted(false) then return false end
		if broker then
			local ok, allowed = pcall(output_current)
			if not ok or allowed ~= true then return false end
		end
		return admitted(true)
	end
	local function result(ok, phase)
		-- A data DOWN with an uncertain native ACK may already have mutated the
		-- document. This flag invalidates caches; it never promises full delivery.
		return { ok = ok == true, cleanup_ok = key_cleanup and (not clip or clip.close()),
			native_cleanup_ok = key_cleanup,
			payload_written = payload_written, failed_phase = phase,
			error = ok ~= true and "selected output admission or observation refused" or nil }
	end

	--- Revokes output before restoring; in-flight frames remain cleanup debt.
	--- @return boolean settled
	function stage.close()
		revoked = true
		local cleaned = not clip or clip.close()
		return not busy and key_cleanup and cleaned
	end
	--- Resolves the route and completes clipboard preparation before range capture.
	--- @return boolean ready
	function stage.prepare()
		if busy or prepared or not current() then return false end
		busy = true
		local ok, ready = pcall(function()
			local offered, _, token = layout_plan(text)
			if offered then
				plan, receipt = { receipt = token, plan = layout_view(token) }, token
				if not plan.plan then return false end
				-- Injector's prepared native contract keeps its ordinary seal. This
				-- descriptor joins B's original field, action, route and RAM source
				-- without observing output_current while a Broker is reserved.
				plan.seal = function()
					if not admitted(true) then error("programmable publication is no longer current", 0) end
				end
				for _, step in ipairs(plan.plan) do data_codes[step.keycode] = true end
				route = "native"
			else
				-- Empty plans seal the actual cohort without guessing a typed key.
				local empty, _, seal = layout_plan("")
				if not empty then return false end
				receipt, route = seal, "clipboard"
				local key = paste_keycode()
				data_codes[key] = true
				if not admitted(false) then return false end
				clip = Clipboard.new_paste_stage(text, ports.sleep, key, function() return admitted(false) end)
				if not admitted(false) or not clip.prepare() then return false end
			end
			return admitted(false)
		end)
		busy = false
		prepared = ok and ready == true and not revoked
		if not prepared then stage.close() end
		return prepared
	end
	--- Emits the payload, cleans native custody and waits the existing caret delay.
	--- @return table receipt Honest physical cleanup and partial-payload status.
	function stage.payload()
		if not prepared or payload_written or not current() then return result(false, "payload admission") end
		busy = true
		local ok, native = pcall(ports.run, "selected payload", function(tx)
			local sent
			if route == "native" then sent = ports.native(tx, text, plan)
			else sent = clip.paste(tx.channel()) end
			if not sent then error("selected payload refused", 0) end
		end, joined, nil, function(code, phase)
			-- This runs after admission and immediately before a data DOWN on the
			-- original wire. A failed native ACK may already have changed text;
			-- modifier masking/neutralisation alone never invalidates the document.
			if data_codes[code] and (phase == "replacement key down" or phase == "clipboard paste chord") then payload_written = true end
		end)
		key_cleanup = ok and type(native) == "table" and native.cleanup_ok == true
		-- Clipboard cleanup is independent of business admission and its deadline.
		local restored = not clip or clip.close()
		local delivered = key_cleanup and restored and native.ok == true and payload_written
		if delivered then
			local waited = pcall(ports.settle)
			delivered = waited and admitted(false)
		end
		busy = false
		return result(delivered, not restored and "clipboard restoration" or not delivered and "payload" or nil)
	end
	--- Selects only after the caller verifies the original inserted span and caret.
	--- @return table receipt
	function stage.reselect()
		if not payload_written or not current() then return result(false, "reselection admission") end
		busy = true
		local ok, native = pcall(ports.run, "selected reselection", ports.reselect, joined)
		key_cleanup = key_cleanup and ok and type(native) == "table" and native.cleanup_ok == true
		busy = false
		return result(key_cleanup and native.ok == true and admitted(false), "reselection")
	end
	return stage
end

return M
