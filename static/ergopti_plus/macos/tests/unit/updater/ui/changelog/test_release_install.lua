--- macos/tests/unit/updater/ui/changelog/test_release_install.lua

--- ==============================================================================
--- MODULE: Versions Window Release Install (macOS)
--- DESCRIPTION:
--- The Versions window listed releases with « View on GitHub » and nothing
--- else. Its « Install this version » button now posts install_release; the
--- real window controller runs the shared sequence with stubbed owners: back
--- the configuration up, find the release in the list it fetched, stage and
--- verify it, arm the app replacement, then quit through the controlled exit.
--- These cases drive the real bridge callback and read what reaches the page.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_changelog = require("tests.support.changelog_fixture").with_changelog

local LIST_BODY = '[{"tag_name":"v0.0.0-dev.139"}]'

--- The decoded GitHub API list the stubbed decoder returns.
local function releases()
	return {
		{ tag_name = "v0.0.0-dev.141", prerelease = true, assets = {} },
		{ tag_name = "v0.0.0-dev.140", prerelease = true, assets = {} },
		{ tag_name = "v0.0.0-dev.139", prerelease = true, assets = {} },
	}
end

--- Stubbed owners recording every effect in order.
--- @param opts table { source, asset = false, stage = { path, stage }, armed = false, restore,
---   reload = false | "throw", exits = { accepted… } }
--- @return table deps, table events
local function owners(opts)
	opts = opts or {}
	local events = {}
	local function event(name) events[#events + 1] = name end
	local deps = {
		updater = {
			is_local_source = function() return opts.source == true end,
			current_version = function() return opts.source and "local" or "0.0.0-dev.140" end,
		},
		backup = {
			owner = function()
				return {
					create = function(kind, meta)
						event("backup:" .. kind .. ":" .. tostring(meta.tag))
						return { path = "/cfg/backups/pre-install-x" }
					end,
					latest = function()
						return opts.latest
					end,
					restore = function(id)
						event("restore:" .. id)
						if opts.restore then return false, opts.restore, { path = "/cfg/backups/pre-restore-y" } end
						return true, nil, { path = "/cfg/backups/pre-restore-y" }
					end,
				}
			end,
		},
		installer = {
			find_asset = function(release)
				event("asset:" .. release.tag_name)
				if opts.asset == false then return nil end
				return { tag = release.tag_name, url = "u", digest = "d", version = "v" }
			end,
			SWAP_WAIT_SECONDS = 120,
			stage = function(_, done)
				event("stage")
				local result = opts.stage or { path = "/tmp/stage/app/ErgoptiPlus.app" }
				done(result.path, result.stage, "detail")
				return true
			end,
			arm_swap = function(staged, done)
				event("arm:" .. tostring(staged))
				if opts.previous then done(false, "previous_backup_occupied"); return true end
				if opts.armed == false then return false, "refused" end
				if opts.defer_arm then opts.arm_done = done; return true end
				if done then done(true) end
				return true
			end,
		},
		coordinator = {
			request_user_exit = function(reason)
				event("exit:" .. reason)
				if opts.exits then return table.remove(opts.exits, 1) end
				return true
			end,
			request_reload_owned = function(reason, on_aborted)
				event("reload:" .. reason)
				opts.reload_aborted = on_aborted
				if opts.reload == "throw" then error("reload raised") end
				return opts.reload ~= false
			end,
		},
		timer = {
			after = function(delay, fn)
				event("expiry:" .. tostring(delay))
				opts.expire = fn
				return {}, true
			end,
		},
	}
	return deps, events
end

--- Opens the window, lists the fixture releases and returns the phases helper.
local function open_listed(changelog, state, post, deps)
	changelog._deps = deps
	hs.json.decode = function(body)
		if body == LIST_BODY then return releases() end
		return nil
	end
	hs.json.encode = function() return "[]" end
	helpers.assert_true(changelog.open({ channel = "dev" }))
	post("ready")
	post({ action = "fetch", channel = "dev" })
	state.callbacks[#state.callbacks](200, LIST_BODY, {})
end

--- The install phases the page received, in order.
local function phases(state)
	local out = {}
	for _, code in ipairs(state.evaluations) do
		if code:find("setInstallProgress(", 1, true) then out[#out + 1] = code:match('"phase":"([%a_]+)"') end
	end
	return table.concat(out, ",")
end

local function last_install_message(state)
	for index = #state.evaluations, 1, -1 do
		local code = state.evaluations[index]
		if code:find("setInstallProgress(", 1, true) then return code end
	end
	return ""
end

helpers.describe("Changelog one-click release install (macOS)", function()
	helpers.it("does not install a release while its replacement list is unavailable", function()
		for _, mode in ipairs({ "pending", "invalid", "encode_failure" }) do
			with_changelog(function(changelog, state, post)
				local deps, events = owners()
				open_listed(changelog, state, post, deps)
				post({ action = "fetch", channel = "dev" })
				if mode == "invalid" then state.callbacks[#state.callbacks](200, "[invalid", {}) end
				if mode == "encode_failure" then
					hs.json.encode = function() return nil end
					state.callbacks[#state.callbacks](200, LIST_BODY, {})
				end
				post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
				helpers.assert_eq(#events, 0, "a stale release list must not authorize installation")
				helpers.assert_true(last_install_message(state):find("changelog_window.install_error_unknown_release", 1, true) ~= nil,
					last_install_message(state))
			end)
		end
	end)

	helpers.it("reports an active install when a refresh is also pending", function()
		with_changelog(function(changelog, state, post)
			local options = { defer_arm = true }
			local deps = owners(options)
			open_listed(changelog, state, post, deps)
			post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
			post({ action = "fetch", channel = "dev" })
			post({ action = "install_release", tag = "v0.0.0-dev.140", channel = "dev" })
			helpers.assert_true(last_install_message(state):find("changelog_window.install_error_busy", 1, true) ~= nil)
		end)
	end)
	helpers.it("tells the user to move an existing app backup before retrying", function()
		with_changelog(function(changelog, state, post)
			local deps, events = owners({ previous = true })
			open_listed(changelog, state, post, deps)
			post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
			helpers.assert_true(last_install_message(state):find("changelog_window.install_error_previous_backup", 1, true) ~= nil)
			helpers.assert_true(table.concat(events, ","):find("exit:", 1, true) == nil)
		end)
	end)
	helpers.it("seeds the installed build and the restorable backup into the page", function()
		with_changelog(function(changelog, state)
			local deps = owners({ latest = { id = "pre-install-b", created_at = "2026-09-30T10:00:00Z", tag = "v1" } })
			changelog._deps = deps
			helpers.assert_true(changelog.open({ channel = "dev" }))
			local html = state.view.options.html_string
			helpers.assert_true(html:find('window.__installed_version="0.0.0-dev.140"', 1, true) ~= nil)
			helpers.assert_true(html:find('window.__install_blocked_key=""', 1, true) ~= nil)
			helpers.assert_true(html:find('"id":"pre-install-b"', 1, true) ~= nil, "the backup is seeded")
		end)
	end)

	helpers.it("greys a source run with its reason", function()
		with_changelog(function(changelog, state)
			changelog._deps = owners({ source = true })
			helpers.assert_true(changelog.open({ channel = "dev" }))
			helpers.assert_true(state.view.options.html_string:find(
				'window.__install_blocked_key="changelog_window.install_blocked_source"', 1, true) ~= nil)
		end)
	end)

	helpers.it("backs up first, stages and verifies, arms the replacement, then quits", function()
		with_changelog(function(changelog, state, post)
			local deps, events = owners()
			open_listed(changelog, state, post, deps)
			post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
			helpers.assert_eq(table.concat(events, ","), table.concat({
				"backup:pre_install:v0.0.0-dev.139", "asset:v0.0.0-dev.139", "stage",
				"arm:/tmp/stage/app/ErgoptiPlus.app", "exit:release_install" }, ","))
			helpers.assert_eq(phases(state), "backing_up,downloading,installing,restarting")
			helpers.assert_true(last_install_message(state):find('"backup_path":"/cfg/backups/pre-install-x"', 1, true) ~= nil)
		end)
	end)

	helpers.it("waits for the detached worker before quitting (release-arming-bridge)", function()
		with_changelog(function(changelog, state, post)
			local options = { defer_arm = true }
			local deps, events = owners(options)
			open_listed(changelog, state, post, deps)
			post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
			helpers.assert_eq(phases(state), "backing_up,downloading,installing")
			helpers.assert_eq(events[#events], "arm:/tmp/stage/app/ErgoptiPlus.app")
			helpers.assert_eq(type(options.arm_done), "function")
			options.arm_done(true)
			helpers.assert_eq(events[#events], "exit:release_install")
			helpers.assert_eq(phases(state), "backing_up,downloading,installing,restarting")
			options.arm_done(false, "late refusal")
			helpers.assert_eq(phases(state), "backing_up,downloading,installing,restarting")
		end)
	end)

	-- A refused quit after ARMED was reported failed and idle while the armed
	-- worker still waited to replace the app (MUR-001).
	helpers.it("holds an armed release whose quit is refused (release-restart-pending)", function()
		with_changelog(function(changelog, state, post)
			local options = { exits = { false, false, true } }
			local deps, events = owners(options)
			open_listed(changelog, state, post, deps)
			post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
			helpers.assert_eq(phases(state), "backing_up,downloading,installing,restarting,restart_pending")
			helpers.assert_eq(events[#events], "expiry:120", "the hold lasts as long as the swap worker waits")
			helpers.assert_eq(changelog.pending_install().tag, "v0.0.0-dev.139")
			post({ action = "install_release", tag = "v0.0.0-dev.141", channel = "dev" })
			helpers.assert_eq(phases(state), "backing_up,downloading,installing,restarting,restart_pending,restart_pending",
				"a second install is refused while the armed release waits")
			helpers.assert_eq(#events, 6, "the refused second install backs nothing up")
			helpers.assert_true(changelog.close())
			helpers.assert_true(changelog.open({ channel = "dev" }))
			helpers.assert_true(state.view.options.html_string:find(
				'window.__install_pending={"backup_path":"/cfg/backups/pre-install-x","tag":"v0.0.0-dev.139"}', 1, true) ~= nil
				or state.view.options.html_string:find(
				'window.__install_pending={"tag":"v0.0.0-dev.139","backup_path":"/cfg/backups/pre-install-x"}', 1, true) ~= nil,
				"a window opened later shows the waiting release")
			post("ready")
			post({ action = "complete_install_restart" })
			helpers.assert_eq(events[#events], "exit:release_install")
			helpers.assert_eq(changelog.pending_install().tag, "v0.0.0-dev.139", "a second refusal keeps it waiting")
			helpers.assert_eq(changelog.complete_pending_install(), true, "the menu row completes it")
			helpers.assert_eq(changelog.pending_install(), nil)
			helpers.assert_true(last_install_message(state):find('"phase":"restarting"', 1, true) ~= nil)
		end)
	end)

	helpers.it("reports an armed release not installed once the swap worker stops waiting (release-restart-pending)", function()
		with_changelog(function(changelog, state, post)
			local options = { exits = { false } }
			local deps = owners(options)
			open_listed(changelog, state, post, deps)
			local redraws = 0
			changelog.set_pending_install_observer(function() redraws = redraws + 1 end)
			post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
			helpers.assert_eq(redraws, 1, "the menu redraws its completing row")
			options.expire()
			helpers.assert_eq(redraws, 2)
			helpers.assert_eq(phases(state), "backing_up,downloading,installing,restarting,restart_pending,failed")
			helpers.assert_true(last_install_message(state):find("changelog_window.install_error_restart_expired", 1, true) ~= nil)
			helpers.assert_eq(changelog.pending_install(), nil)
		end)
	end)

	helpers.it("keeps the driver running when arming refuses (release-arming-bridge)", function()
		with_changelog(function(changelog, state, post)
			local options = { defer_arm = true }
			local deps, events = owners(options)
			open_listed(changelog, state, post, deps)
			post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
			helpers.assert_eq(phases(state), "backing_up,downloading,installing")
			options.arm_done(false, "log open refused")
			helpers.assert_eq(phases(state), "backing_up,downloading,installing,failed")
			helpers.assert_eq(events[#events], "arm:/tmp/stage/app/ErgoptiPlus.app")
			options.arm_done(true)
			helpers.assert_eq(phases(state), "backing_up,downloading,installing,failed")
		end)
	end)

	helpers.it("refuses a release without the macOS archive and keeps the backup", function()
		with_changelog(function(changelog, state, post)
			local deps, events = owners({ asset = false })
			open_listed(changelog, state, post, deps)
			post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
			helpers.assert_eq(table.concat(events, ","), "backup:pre_install:v0.0.0-dev.139,asset:v0.0.0-dev.139")
			local message = last_install_message(state)
			helpers.assert_true(message:find("install_error_no_asset", 1, true) ~= nil, message)
			helpers.assert_true(message:find("pre-install-x", 1, true) ~= nil, "the backup is named")
		end)
	end)

	helpers.it("never arms a replacement for a release that failed its verification", function()
		with_changelog(function(changelog, state, post)
			local deps, events = owners({ stage = { stage = "verify" } })
			open_listed(changelog, state, post, deps)
			post({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" })
			for _, name in ipairs(events) do
				helpers.assert_true(name:sub(1, 4) ~= "arm:" and name:sub(1, 5) ~= "exit:", "nothing installs: " .. name)
			end
			helpers.assert_true(last_install_message(state):find("install_error_verify", 1, true) ~= nil)
		end)
	end)

	helpers.it("refuses a tag the fetched list does not hold, without a backup", function()
		with_changelog(function(changelog, state, post)
			local deps, events = owners()
			open_listed(changelog, state, post, deps)
			post({ action = "install_release", tag = "v0.0.0-dev.99", channel = "dev" })
			helpers.assert_eq(#events, 0)
			helpers.assert_true(last_install_message(state):find("install_error_unknown_release", 1, true) ~= nil)
		end)
	end)

	helpers.it("restores a backup and reloads on it", function()
		with_changelog(function(changelog, state, post)
			local deps, events = owners()
			open_listed(changelog, state, post, deps)
			post({ action = "restore_backup", id = "pre-install-x" })
			helpers.assert_eq(table.concat(events, ","), "restore:pre-install-x,reload:config_restore")
			local restored = false
			for _, code in ipairs(state.evaluations) do
				if code:find("setRestoreProgress(", 1, true) and code:find('"phase":"restored"', 1, true) then
					restored = true
				end
			end
			helpers.assert_true(restored, "the page learns the restore")
		end)
	end)

	helpers.it("reloads nothing when a restore fails", function()
		with_changelog(function(changelog, state, post)
			local deps, events = owners({ restore = "missing" })
			open_listed(changelog, state, post, deps)
			post({ action = "restore_backup", id = "pre-install-x" })
			helpers.assert_eq(table.concat(events, ","), "restore:pre-install-x")
		end)
	end)
	--- The restore phases the page received, in order.
	local function restore_phases(state)
		local phases = {}
		for _, code in ipairs(state.evaluations) do
			if code:find("setRestoreProgress(", 1, true) then
				phases[#phases + 1] = code:match('"phase":"([%a_]+)"')
			end
		end
		return table.concat(phases, ",")
	end

	-- (restore-reload-refused) The disk was restored but the handoff failed: the
	-- page must not keep promising a restart (macOS MC-002).
	for _, mode in ipairs({ false, "throw" }) do
		helpers.it("reports a refused restore reload as failed (" .. tostring(mode) .. ")", function()
			with_changelog(function(changelog, state, post)
				local deps = owners({ reload = mode })
				open_listed(changelog, state, post, deps)
				post({ action = "restore_backup", id = "pre-install-x" })
				helpers.assert_eq(restore_phases(state), "restoring,failed")
				local last = state.evaluations[#state.evaluations]
				helpers.assert_true(last:find("restore_error_unexpected", 1, true) ~= nil, last)
				helpers.assert_true(last:find("pre-restore-y", 1, true) ~= nil, "names the pre-restore copy")
			end)
		end)
	end

	helpers.it("reports a restore reload aborted after acceptance (restore-reload-refused)", function()
		with_changelog(function(changelog, state, post)
			local opts = {}
			local deps = owners(opts)
			open_listed(changelog, state, post, deps)
			post({ action = "restore_backup", id = "pre-install-x" })
			helpers.assert_eq(restore_phases(state), "restoring,restored")
			helpers.assert_eq(type(opts.reload_aborted), "function", "the reload is owned")
			opts.reload_aborted("fence refused")
			helpers.assert_eq(restore_phases(state), "restoring,restored,failed")
		end)
	end)
end)
