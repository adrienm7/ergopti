--- macos/tests/unit/ui/test_changelog_managed_admission.lua

--- ==============================================================================
--- MODULE: Versions Native Pause and Publication Admission
--- DESCRIPTION:
--- Drives the actual controller, native script-control module ports and private
--- release installer callbacks. Controlled ports do not prove native macOS I/O.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.changelog_fixture")
local Json = require("json")
local TAG, BODY = "v0.0.0-dev.139", '[{"tag_name":"v0.0.0-dev.139"}]'

local function listed(body)
	fixture.with_changelog(function(changelog, state, post)
		state.backups, state.arms, state.exits, state.stages = 0, 0, 0, {}
		changelog._deps = {
			updater = {
				is_local_source = function()
					if state.on_source_read then state.on_source_read() end
					return false
				end,
				current_version = function() return "0.0.0-dev.140" end,
			},
			backup = { owner = function() return {
				latest = function() return nil end,
				create = function() state.backups = state.backups + 1; return { path = "/cfg/backup" } end,
			} end },
			installer = {
				find_asset = function() return { url = "https://fixture.invalid/app", digest = "literal", version = TAG } end,
				stage = function(_, done) state.stages[#state.stages + 1] = done; return true end,
				arm_swap = function() state.arms = state.arms + 1; return true end,
			},
			coordinator = { request_user_exit = function() state.exits = state.exits + 1; return true end },
		}
		hs.json.decode = function(raw)
			if raw == BODY then return { { tag_name = TAG, prerelease = true, assets = {} } } end
			return nil
		end
		hs.json.encode = function(value) return Json.encode(value) end
		helpers.assert_true(changelog.open({ channel = "dev" }))
		post("ready")
		post({ action = "fetch", channel = "dev" })
		state.callbacks[#state.callbacks](200, BODY, {})
		body(changelog, state, post)
	end)
end

local function install(post)
	post({ action = "install_release", tag = TAG, channel = "dev" })
end

local function terminal(state)
	for i = #(state.view_evaluations or {}), 1, -1 do
		local item = state.view_evaluations[i]
		local raw = item.code:match("^setInstallProgress%((.*)%)$")
		if raw then
			local message = Json.decode(raw)
			if message.phase == "failed" then return message end
		end
	end
	error("the actual page received no terminal report")
end

local function progress_count(state, view)
	local count = 0
	for _, item in ipairs(state.view_evaluations or {}) do
		if item.view == view and item.code:find("setInstallProgress(", 1, true) then count = count + 1 end
	end
	return count
end

local function retry(post, message)
	post({ action = "install_failure_action", operation = message.operation,
		epoch = message.failure_epoch, id = "retry" })
end

local function encoding_hook(phase, hook, body)
	local previous = Json.encode
	local once = false
	Json.encode = function(value)
		if not once and type(value) == "table" and value.phase == phase then
			once = true
			Json.encode = previous
			hook()
		end
		return previous(value)
	end
	local ok, err = xpcall(body, debug.traceback)
	Json.encode = previous
	if not ok then error(err, 0) end
	helpers.assert_true(once, "the actual production message encoder must exercise the causal hook")
end

helpers.describe("Versions native managed admission (macOS)", function()
	for _, field in ipairs({ "paused", "pause_transition" }) do
		helpers.it("refuses new installation while actual native " .. field .. " is true", function()
			listed(function(_, state, post)
				state[field] = true
				install(post)
				helpers.assert_eq(state.backups, 0)
				helpers.assert_eq(#state.stages, 0)
			end)
		end)
		for _, value in ipairs({ {name="nil"}, {name="number",value=0}, {name="string",value="false"} }) do
			helpers.it("refuses nonboolean native " .. field .. " receipt " .. value.name, function()
				listed(function(_, state, post)
					state[field] = value.value
					install(post)
					helpers.assert_eq(state.backups, 0)
				end)
			end)
		end
	end

	for _, port in ipairs({ "is_paused", "is_pause_transition_pending" }) do
		for _, kind in ipairs({ "missing", "raise" }) do
			helpers.it("refuses " .. kind .. " authoritative native port " .. port, function()
				listed(function(_, state, post)
					state.script_control[port] = kind == "raise" and function() error("controlled probe refusal") end or nil
					install(post)
					helpers.assert_eq(state.backups, 0)
				end)
			end)
		end
	end

	helpers.it("does not borrow a replacement script-control module during probe", function()
		listed(function(_, state, post)
			state.on_pause_read = function()
				package.loaded["modules.shortcuts.script_control"] = {
					is_paused = function() return false end,
					is_pause_transition_pending = function() return false end,
				}
			end
			install(post)
			helpers.assert_eq(state.backups, 0)
		end)
	end)

	helpers.it("does not borrow a successor native window during pause read", function()
		listed(function(changelog, state, post)
			state.on_pause_read = function()
				state.on_pause_read = nil
				helpers.assert_true(changelog.close())
				helpers.assert_true(changelog.open({channel="dev"}))
				post("ready")
			end
			install(post)
			helpers.assert_eq(state.backups, 0)
		end)
	end)

	helpers.it("rechecks fresh pause after the actual source-run probe", function()
		listed(function(_, state, post)
			state.on_source_read = function() state.paused = true end
			install(post)
			helpers.assert_eq(state.backups, 0)
		end)
	end)

	helpers.it("failed accepted download advertises no retry while paused", function()
		listed(function(_, state, post)
			install(post)
			state.paused = true
			state.stages[1](nil, "download", "controlled failure", {})
			local message = terminal(state)
			helpers.assert_true(message.managed_failure == true)
			helpers.assert_eq(message.failure_report.cause, "unknown")
			helpers.assert_eq(#message.failure_report.actions, 0)
			retry(post, message)
			helpers.assert_eq(state.backups, 1)
		end)
	end)

	helpers.it("fresh pause refuses old retry and fresh resume admits the same exact terminal", function()
		listed(function(_, state, post)
			install(post)
			state.stages[1](nil, "download", "controlled failure", {})
			local message = terminal(state)
			helpers.assert_eq(message.failure_report.actions[1].id, "retry")
			state.paused = true
			retry(post, message)
			helpers.assert_eq(state.backups, 1)
			state.paused = false
			retry(post, message)
			helpers.assert_eq(state.backups, 2)
			helpers.assert_eq(#state.stages, 2)
		end)
	end)

	helpers.it("accepted install still arms and exits after later pause", function()
		listed(function(_, state, post)
			install(post)
			state.paused = true
			state.stages[1]("/staged/ErgoptiPlus.app")
			helpers.assert_eq(state.arms, 1)
			helpers.assert_eq(state.exits, 1)
		end)
	end)

	helpers.it("accepted install completes after retirement without publishing into successor", function()
		listed(function(changelog, state, post)
			install(post)
			helpers.assert_true(changelog.close())
			helpers.assert_true(changelog.open({channel="dev"}))
			post("ready")
			local successor = state.view
			state.paused = true
			state.stages[1]("/staged/ErgoptiPlus.app")
			helpers.assert_eq(state.arms, 1)
			helpers.assert_eq(state.exits, 1)
			helpers.assert_eq(progress_count(state, successor), 0)
		end)
	end)

	helpers.it("phase encoding reentry does not select a successor report recipient", function()
		listed(function(changelog, state, post)
			local successor
			encoding_hook("backing_up", function()
				helpers.assert_true(changelog.close())
				helpers.assert_true(changelog.open({channel="dev"}))
				post("ready")
				successor = state.view
			end, function() install(post) end)
			helpers.assert_eq(progress_count(state, successor), 0)
			helpers.assert_eq(state.backups, 1)
			helpers.assert_eq(#state.stages, 1)
			state.stages[1]("/staged/ErgoptiPlus.app")
			helpers.assert_eq(state.arms, 1)
			helpers.assert_eq(state.exits, 1)
		end)
	end)

	helpers.it("terminal encoding reentry cannot publish old failure into successor", function()
		listed(function(changelog, state, post)
			install(post)
			local successor
			encoding_hook("failed", function()
				helpers.assert_true(changelog.close())
				helpers.assert_true(changelog.open({channel="dev"}))
				post("ready")
				successor = state.view
			end, function() state.stages[1](nil,"download","controlled failure",{}) end)
			helpers.assert_eq(progress_count(state, successor), 0)
			helpers.assert_eq(state.backups, 1)
		end)
	end)
end)
