--- _shared/lua/test/manual_profile_selection.lua

--- ==============================================================================
--- MODULE: Manual Profile Selection Override Contract
--- DESCRIPTION:
--- Runs the actual menu-owned selection closure over inert runtime and save ports.
--- It keeps deferred intent returns exact and refuses publication over a live mode.
--- ==============================================================================

local M = {}

local function between(source, first, last)
	local start_at = assert(source:find(first, 1, true), first)
	local finish_at = assert(source:find(last, start_at + #first, true), last)
	return source:sub(start_at, finish_at - 1)
end

--- Proves the genuine manual closure retires an override before its transaction.
--- @param helpers table Existing test assertions.
--- @param platform string hs or linux.
--- @param source string Actual menu owner source.
function M.assert_selection(helpers, platform, source)
	assert(platform == "hs" or platform == "linux", "known manual selection owner")
	local body
	if platform == "hs" then
		body = between(source, "deps.set_llm_profile =", "deps.settle_llm_switcher_recovery")
	else
		body = between(source, "local function select_profile(profile_id)", "local function save_profile(")
	end
	for _, kind in ipairs({ "active", "absent", "stop_refused", "stop_throws", "stop_stale", "read_throws", "missing", "save_refused" }) do
		local live = kind == "absent" and nil or { profile_id = "translate_ja" }
		if kind == "absent" then live = nil end
		local stop_calls, commit_calls, refresh_calls = 0, 0, 0
		local order, options, intent, recovery = {}, {}, {}, {}
		local function read_live()
			if kind == "read_throws" then error("owned read refusal") end
			return live
		end
		local function stop(value)
			helpers.assert_nil(value, "the exact nil stop argument reaches the existing owner")
			stop_calls = stop_calls + 1; order[#order + 1] = "stop"
			if kind == "stop_throws" then error("owned stop refusal") end
			if kind == "stop_refused" then return false end
			if kind ~= "stop_stale" then live = nil end
			return true
		end
		local function commit(id, opts)
			commit_calls = commit_calls + 1; order[#order + 1] = "commit"
			helpers.assert_eq(id, "advanced")
			if platform == "hs" then helpers.assert_true(rawequal(opts, options)) end
			if kind == "save_refused" then return false, nil, recovery end
			return true, intent, recovery
		end
		local owner = { get_live_prompt = read_live, set_live_prompt = stop, get_live = read_live, set_live = stop }
		if kind == "missing" then owner.get_live_prompt, owner.get_live = nil, nil end
		local environment = setmetatable({
			Logger = { error = function() end }, LOG = "profile-control",
			keymap = owner, llm = owner, switcher = { set_llm_profile = commit }, deps = {},
			ProfileSettings = { set = function(name, id, model)
				helpers.assert_eq(name, "active"); helpers.assert_eq(model, "owned-model")
				return commit(id)
			end }, current_model = "owned-model", refresh = function() refresh_calls = refresh_calls + 1 end,
		}, { __index = _G })
		local code = platform == "hs" and body .. "return deps.set_llm_profile"
			or body .. "return select_profile"
		local chunk = assert(load(code, "@actual-manual-selection", "t", environment))
		local select_profile = chunk()
		local accepted, returned_intent, returned_recovery = select_profile("advanced", options)
		local refused = kind ~= "active" and kind ~= "absent" and kind ~= "save_refused"
		if refused then
			helpers.assert_eq(accepted, false, kind .. " must refuse selection")
			helpers.assert_eq(commit_calls, 0, kind .. " cannot reach persistence")
		else
			helpers.assert_eq(accepted, kind ~= "save_refused", kind)
			helpers.assert_nil(live, "a successful manual boundary cannot retain the shortcut override")
			helpers.assert_eq(commit_calls, 1)
			helpers.assert_eq(stop_calls, kind == "absent" and 0 or 1)
			if kind ~= "absent" then helpers.assert_eq(table.concat(order, ","), "stop,commit") end
			if platform == "hs" then
				helpers.assert_true(rawequal(returned_recovery, recovery), "exact transaction status is forwarded")
				if kind ~= "save_refused" then helpers.assert_true(rawequal(returned_intent, intent), "exact deferred intent remains owned")
				else helpers.assert_nil(returned_intent) end
			end
		end
		if platform == "linux" then helpers.assert_eq(refresh_calls, accepted == true and 1 or 0) end
	end
end

return M
