--- macos/tests/unit/ui/test_changelog_release_install.lua

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
--- @param opts table { source, asset = false, stage = { path, stage }, armed = false, restore }
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
			stage = function(_, done)
				event("stage")
				local result = opts.stage or { path = "/tmp/stage/app/ErgoptiPlus.app" }
				done(result.path, result.stage, "detail")
				return true
			end,
			arm_swap = function(staged)
				event("arm:" .. tostring(staged))
				if opts.armed == false then return false, "refused" end
				return true
			end,
		},
		coordinator = {
			request_user_exit = function(reason) event("exit:" .. reason); return true end,
			request_reload = function(reason) event("reload:" .. reason); return true end,
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
end)
