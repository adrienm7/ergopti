--- _shared/lua/updater/check_session.lua

--- ==============================================================================
--- MODULE: Update Check Window Session (Shared Lua)
--- DESCRIPTION:
--- Drives the shared update-check window (_shared/ui/update_check) for the
--- macOS and Linux hosts: it starts a check of the subscribed channel, shows
--- "checking" and then the answer, and serves the page's actions (install the
--- offered release, open the release notes, switch to another channel that has
--- a newer release, report or open the log of a failed check, close).
---
--- FEATURES & RATIONALE:
--- 1. One controller for both Lua hosts: the host only creates the window,
---    delivers page messages and pushes the messages this session builds; the
---    check, the channel owner, the installer and the report are injected.
--- 2. Nothing installs without the user: Update acts only on the release the
---    last answer offered, and a switch only to a channel that answer listed.
--- 3. Generations: a new check (a switch, or the menu row clicked again) makes
---    the answer of an older one inert, so a late result never replaces the
---    window's current phase; a retired session (its window closed, or
---    replaced by a new one) shows and does nothing more.
--- 4. PURE Lua (LuaJIT and 5.4): no driver imports, no io, no OS calls.
--- ==============================================================================

local CheckResult = require("updater.check_result")

local M = {}

-- The page's actions, and the phase each one needs (true: any phase)
local ACTIONS = {
	close          = true,
	update         = "available",
	whats_new      = "available",
	switch_channel = true,
	report         = "error",
	open_log       = "error",
}

-- Every port a session needs, with its kind
local PORTS = {
	push = "function", check = "function", channel = "function", current = "function",
	set_channel = "function", install = "function", open_changelog = "function",
	report = "function", open_log = "function", close = "function", log_path = "function",
	log = "function",
}

--- Creates the session of one window.
--- @param opts table
---   push function(message): boolean Sends one message to the page.
---   check function(channel, on_result): boolean Starts one check; on_result
---     receives an updater.check_result table.
---   channel function(): string The subscribed channel.
---   current function(): string The installed version.
---   set_channel function(id): boolean The channel owner's set.
---   install function(result): boolean Hands the offered release to the installer.
---   open_changelog function(channel): boolean Opens the Versions window.
---   report function(result): boolean, boolean|nil Reports a failed check
---     (ok, missing).
---   open_log function(): boolean, boolean|nil Opens today's log (ok, missing).
---   close function() Closes the window.
---   log_path function(): string Today's log file.
---   log function(level, message, ...) The driver's logger.
--- @return table session { start, on_message, message, result }
function M.new(opts)
	if type(opts) ~= "table" then error("an update-check session needs its ports", 2) end
	for name, kind in pairs(PORTS) do
		if type(opts[name]) ~= kind then
			error("an update-check session needs its '" .. name .. "' port", 2)
		end
	end
	local session = {}
	local generation = 0
	local retired = false
	local result = nil     -- the last answer, nil while checking
	local message = nil    -- the page's current state message

	--- Sends the current phase to the page.
	local function publish()
		if retired or message == nil then return false end
		local ok, sent = pcall(opts.push, message)
		if not ok or sent ~= true then
			opts.log("error", "The update-check window could not be updated: %s.", tostring(sent))
			return false
		end
		return true
	end

	--- Sends the outcome of one action to the page.
	local function acknowledge(action, ok, missing)
		if retired then return end
		local pushed_ok, pushed = pcall(opts.push, {
			type = "action", action = action, ok = ok == true, missing = missing == true,
		})
		if not pushed_ok or pushed ~= true then
			opts.log("error", "The update-check action result could not be shown: %s.", tostring(pushed))
		end
	end

	--- The page message of one answer.
	local function state_message(answer)
		local page = {
			type    = "state",
			state   = answer.state,
			channel = answer.channel,
			current = answer.current,
			latest  = answer.latest,
			others  = answer.others or {},
		}
		if answer.state == "error" then
			page.reason_key = answer.reason_key
			local ok, path = pcall(opts.log_path)
			if ok and type(path) == "string" then
				page.log_path = path
			else
				-- The page then hides its log line and button; the log says why
				opts.log("error", "Today's log path is unavailable for the update-check window: %s.", tostring(path))
				page.log_path = ""
			end
		end
		return page
	end

	--- Receives the answer of one check.
	local function answer_of(expected)
		return function(answer)
			if retired or expected ~= generation then
				opts.log("debug", "Discarded the answer of a superseded update check.")
				return
			end
			if type(answer) ~= "table" or not CheckResult.STATES[answer.state] then
				opts.log("error", "The update check answered without a known phase.")
				answer = CheckResult.failure({ channel = message and message.channel, current = message and message.current },
					"unexpected", "the check answered without a known phase")
			end
			result = answer
			message = state_message(answer)
			opts.log("info", "Update check window: %s (channel %s).", answer.state, tostring(answer.channel))
			publish()
		end
	end

	--- Starts a check of the subscribed channel and shows "checking".
	--- @return boolean dispatched
	function session.start()
		if retired then
			opts.log("warn", "Refused to start a check in a retired update-check session.")
			return false
		end
		generation = generation + 1
		local expected = generation
		result = nil
		local channel, current = opts.channel(), opts.current()
		message = { type = "state", state = "checking", channel = channel, current = current, others = {} }
		publish()
		local on_result = answer_of(expected)
		local ok, dispatched = pcall(opts.check, channel, on_result)
		if ok and dispatched == true then return true end
		if expected == generation and result == nil then
			on_result(CheckResult.failure({ channel = channel, current = current }, "unexpected",
				ok and "the check was not dispatched" or tostring(dispatched)))
		end
		return false
	end

	--- Whether a channel is one the current answer listed as newer.
	local function listed(id)
		for _, entry in ipairs(result and result.others or {}) do
			if entry.channel == id then return true end
		end
		return false
	end

	--- Performs one page action.
	local function perform(name, body)
		if name == "close" then
			opts.close()
		elseif name == "update" then
			if opts.install(result) == true then
				opts.close()
			else
				acknowledge(name, false)
			end
		elseif name == "whats_new" then
			acknowledge(name, opts.open_changelog(result.channel) == true)
		elseif name == "switch_channel" then
			local id = body.channel
			if not listed(id) then
				opts.log("warn", "Refused a switch to '%s': the last answer did not list it.", tostring(id))
				acknowledge(name, false)
			elseif opts.set_channel(id) == true then
				session.start()
			else
				acknowledge(name, false)
			end
		elseif name == "report" then
			local ok, missing = opts.report(result)
			acknowledge(name, ok, missing)
		elseif name == "open_log" then
			local ok, missing = opts.open_log()
			acknowledge(name, ok, missing)
		end
	end

	--- Handles one message of the page: "ready", or { action, channel? }.
	--- @param body any The message body the page posted.
	function session.on_message(body)
		if retired then
			opts.log("warn", "Refused a message for a retired update-check session.")
			return
		end
		if body == "ready" then
			publish()
			return
		end
		local name = type(body) == "table" and body.action or nil
		local needs = type(name) == "string" and ACTIONS[name] or nil
		if needs == nil then
			opts.log("warn", "Refused an update-check window message that is not one of its actions.")
			return
		end
		if needs ~= true and (result == nil or result.state ~= needs) then
			opts.log("warn", "Refused the update-check action '%s' outside the '%s' phase.", name, needs)
			acknowledge(name, false)
			return
		end
		opts.log("info", "Update check window action: %s.", name)
		local ok, err = pcall(perform, name, body)
		if not ok then
			opts.log("error", "The update-check action '%s' failed: %s.", name, tostring(err))
			acknowledge(name, false)
		end
	end

	--- Retires the session: its pending answer and its page are ignored from now.
	function session.retire()
		retired = true
		generation = generation + 1
	end

	--- The page's current state message (nil before start).
	function session.message() return message end

	--- The last answer (nil while checking).
	function session.result() return result end

	return session
end

return M
