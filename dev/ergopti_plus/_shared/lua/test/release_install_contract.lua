--- _shared/lua/test/release_install_contract.lua

--- Exercises the shared one-click release install over recording ports: the
--- click backs the configuration up before anything else, a missing asset or a
--- failed verification stops before the install and keeps the backup, a
--- success installs through the update path and restarts, and nothing runs
--- without the click. Registered by the macOS and Linux suites.
local M = {}

--- Recording ports whose outcomes each test sets.
--- @param outcome table|nil Overrides: blocked, release, backup, asset,
---   download = { path, reason } or "pending", installed, install_reason, restarted.
--- @return table ports
--- @return table seen { calls, reports }
local function recording(outcome)
	outcome = outcome or {}
	local seen = { calls = {}, reports = {}, pending = nil, levels = {} }
	local function call(name) seen.calls[#seen.calls + 1] = name end
	local logger = {}
	for _, level in ipairs({ "start", "success", "info", "warn", "error", "debug", "done", "trace" }) do
		logger[level] = function() seen.levels[#seen.levels + 1] = level end
	end
	local ports = {
		logger = logger,
		log = "test",
		blocked = function() call("blocked"); return outcome.blocked end,
		find_release = function(tag, channel)
			call("find_release")
			seen.found = { tag = tag, channel = channel }
			if outcome.release == false then return nil, outcome.missing end
			return { tag = tag }
		end,
		backup = function(release)
			call("backup")
			if outcome.backup == false then return nil, "disk full" end
			return { path = "/cfg/backups/pre-install-x-" .. release.tag }
		end,
		resolve_asset = function()
			call("resolve_asset")
			if outcome.asset == false then return nil end
			return { name = "bundle" }
		end,
		download = function(_, _, done)
			call("download")
			if outcome.download == "pending" then
				seen.pending = done
				return true
			end
			local result = outcome.download or { path = "/tmp/verified" }
			done(result.path, result.reason, result.detail)
			return true
		end,
		install = function(path)
			call("install")
			seen.installed_path = path
			if outcome.installed == false then return false, outcome.install_reason, "refused" end
			return true
		end,
		restart = function()
			call("restart")
			return outcome.restarted ~= false
		end,
		report = function(message) seen.reports[#seen.reports + 1] = message end,
	}
	return ports, seen
end

local function phases(seen)
	local out = {}
	for _, message in ipairs(seen.reports) do out[#out + 1] = message.phase end
	return table.concat(out, ",")
end

local function last(seen) return seen.reports[#seen.reports] end

--- @param helpers table Test helpers of the driver suite.
function M.register(helpers)
	local Install = require("updater.release_install")

	helpers.describe("shared one-click release install (release_install)", function()
		helpers.it("does nothing until the click", function()
			local ports, seen = recording()
			Install.new(ports)
			helpers.assert_eq(#seen.calls, 0)
			helpers.assert_eq(#seen.reports, 0)
		end)

		helpers.it("backs up first, then downloads, verifies, installs and restarts", function()
			local ports, seen = recording()
			local session = Install.new(ports)
			helpers.assert_eq(session.install("v0.0.0-dev.139", "dev"), true)
			helpers.assert_eq(table.concat(seen.calls, ","),
				"blocked,find_release,backup,resolve_asset,download,install,restart")
			helpers.assert_eq(phases(seen), "backing_up,downloading,installing,restarting")
			helpers.assert_eq(seen.found.channel, "dev")
			helpers.assert_eq(seen.installed_path, "/tmp/verified", "the verified download is what installs")
			helpers.assert_eq(last(seen).backup_path, "/cfg/backups/pre-install-x-v0.0.0-dev.139")
		end)

		helpers.it("refuses a release without this system's asset and keeps the backup", function()
			local ports, seen = recording({ asset = false })
			local session = Install.new(ports)
			helpers.assert_eq(session.install("v0.0.0-dev.139", "dev"), false)
			helpers.assert_eq(table.concat(seen.calls, ","), "blocked,find_release,backup,resolve_asset")
			helpers.assert_eq(last(seen).phase, "failed")
			helpers.assert_eq(last(seen).reason_key, Install.REASON.no_asset)
			helpers.assert_eq(last(seen).backup_path, "/cfg/backups/pre-install-x-v0.0.0-dev.139")
			helpers.assert_eq(session.busy(), false)
		end)

		helpers.it("never installs a download that failed its verification", function()
			local ports, seen = recording({ download = { reason = Install.REASON.verify, detail = "SHA-256 mismatch" } })
			local session = Install.new(ports)
			session.install("v0.0.0-dev.139", "dev")
			helpers.assert_eq(table.concat(seen.calls, ","), "blocked,find_release,backup,resolve_asset,download")
			helpers.assert_eq(last(seen).reason_key, Install.REASON.verify)
			helpers.assert_eq(last(seen).backup_path, "/cfg/backups/pre-install-x-v0.0.0-dev.139")
		end)

		helpers.it("reports a failed download as one, and never as a verification", function()
			local ports, seen = recording({ download = { reason = "anything else" } })
			Install.new(ports).install("v1", "main")
			helpers.assert_eq(last(seen).reason_key, Install.REASON.download)
		end)

		helpers.it("downloads nothing when the backup fails", function()
			local ports, seen = recording({ backup = false })
			local session = Install.new(ports)
			helpers.assert_eq(session.install("v1", "main"), false)
			helpers.assert_eq(table.concat(seen.calls, ","), "blocked,find_release,backup")
			helpers.assert_eq(last(seen).reason_key, Install.REASON.backup)
			helpers.assert_eq(last(seen).backup_path, nil)
		end)

		helpers.it("shows an install refusal and restarts nothing", function()
			local ports, seen = recording({ installed = false, install_reason = Install.REASON.install })
			Install.new(ports).install("v1", "main")
			helpers.assert_eq(table.concat(seen.calls, ","),
				"blocked,find_release,backup,resolve_asset,download,install")
			helpers.assert_eq(last(seen).reason_key, Install.REASON.install)
		end)

		helpers.it("refuses a blocked build before any backup", function()
			local ports, seen = recording({ blocked = "changelog_window.install_blocked_source" })
			helpers.assert_eq(Install.new(ports).install("v1", "main"), false)
			helpers.assert_eq(table.concat(seen.calls, ","), "blocked")
			helpers.assert_eq(last(seen).phase, "failed")
		end)

		helpers.it("refuses a tag the loaded list does not hold, with the host's reason", function()
			local ports, seen = recording({ release = false, missing = Install.REASON.no_details })
			helpers.assert_eq(Install.new(ports).install("v9", "main"), false)
			helpers.assert_eq(table.concat(seen.calls, ","), "blocked,find_release")
			helpers.assert_eq(last(seen).reason_key, Install.REASON.no_details)
			-- The page explains a feed-only list; an ERROR opened the error window
			-- over it while the API was rate limited (install-no-details-warning-99)
			helpers.assert_eq(table.concat(seen.levels, ","), "warn")
		end)

		helpers.it("refuses a tag the loaded API list lacks as an error: the page is stale", function()
			local ports, seen = recording({ release = false, missing = Install.REASON.unknown_release })
			helpers.assert_eq(Install.new(ports).install("v9", "main"), false)
			helpers.assert_eq(last(seen).reason_key, Install.REASON.unknown_release)
			helpers.assert_eq(table.concat(seen.levels, ","), "error")
		end)

		helpers.it("runs one install at a time", function()
			local ports, seen = recording({ download = "pending" })
			local session = Install.new(ports)
			helpers.assert_eq(session.install("v1", "main"), true)
			helpers.assert_eq(session.busy(), true)
			helpers.assert_eq(session.install("v2", "main"), false)
			helpers.assert_eq(last(seen).reason_key, Install.REASON.busy)
			seen.pending(nil, Install.REASON.download, "timeout")
			helpers.assert_eq(session.busy(), false, "a failure frees the session for Retry")
			seen.pending("/tmp/late", nil, nil)
			local installs = 0
			for _, name in ipairs(seen.calls) do if name == "install" then installs = installs + 1 end end
			helpers.assert_eq(installs, 0, "a second completion of a settled download installs nothing")
		end)
	end)
	helpers.describe("shared release install capabilities (release-install-capabilities)", function()
		local function names_refusal(reason, messages)
			if type(reason) ~= "string" then return false end
			for _, message in ipairs(messages) do
				if reason:find(message, 1, true) then return true end
			end
			return false
		end
		helpers.it("runs a sync-only capability through its actual completion", function()
			local ports, seen = recording()
			local session = Install.new(ports)
			helpers.assert_eq(#seen.calls, 0, "construction must not dispatch work")
			helpers.assert_eq(session.install("v1", "main"), true)
			helpers.assert_eq(table.concat(seen.calls, ","),
				"blocked,find_release,backup,resolve_asset,download,install,restart")
			helpers.assert_eq(phases(seen), "backing_up,downloading,installing,restarting")
		end)

		helpers.it("runs an async-only capability and waits for its actual completion", function()
			local ports, seen = recording()
			ports.install = nil
			local completed
			ports.install_async = function(path, release, asset, done)
				seen.calls[#seen.calls + 1] = "install_async"
				helpers.assert_eq(path, "/tmp/verified")
				helpers.assert_eq(release.tag, "v1")
				helpers.assert_eq(asset.name, "bundle")
				completed = done
				return true
			end
			local session = Install.new(ports)
			helpers.assert_eq(#seen.calls, 0, "construction must not dispatch work")
			helpers.assert_eq(session.install("v1", "main"), true)
			helpers.assert_eq(type(completed), "function")
			helpers.assert_eq(session.busy(), true)
			helpers.assert_eq(table.concat(seen.calls, ","),
				"blocked,find_release,backup,resolve_asset,download,install_async")
			helpers.assert_eq(phases(seen), "backing_up,downloading,installing")
			completed(true)
			helpers.assert_eq(table.concat(seen.calls, ","),
				"blocked,find_release,backup,resolve_asset,download,install_async,restart")
			helpers.assert_eq(phases(seen), "backing_up,downloading,installing,restarting")
		end)

		for _, installed in ipairs({ true, false }) do
			helpers.it("prefers async over sync without fallback after completion " .. tostring(installed), function()
				local ports, seen = recording()
				local completed
				ports.install_async = function(_, _, _, done)
					seen.calls[#seen.calls + 1] = "install_async"
					completed = done
					return true
				end
				local session = Install.new(ports)
				helpers.assert_eq(session.install("v1", "main"), true)
				helpers.assert_eq(type(completed), "function")
				helpers.assert_eq(phases(seen), "backing_up,downloading,installing")
				completed(installed, Install.REASON.install, "controlled completion")
				helpers.assert_eq(table.concat(seen.calls, ","),
					"blocked,find_release,backup,resolve_asset,download,install_async" .. (installed and ",restart" or ""))
				helpers.assert_eq(last(seen).phase, installed and "restarting" or "failed")
				if not installed then
					helpers.assert_eq(last(seen).reason_key, Install.REASON.install)
					helpers.assert_eq(session.busy(), false)
				end
			end)
		end

		helpers.it("refuses missing install capabilities before any side effect", function()
			local ports, seen = recording()
			ports.install = nil
			local ok, reason = pcall(Install.new, ports)
			helpers.assert_eq(ok, false)
			helpers.assert_true(names_refusal(reason, { "release_install needs the install port",
				"release_install needs an install or async install port" }))
			helpers.assert_eq(seen.calls, {}, "constructor refusal must precede backup and download")
			helpers.assert_eq(seen.reports, {})
		end)

		for _, invalid in ipairs({ { name = "false", value = false }, { name = "string", value = "not a capability" } }) do
			for _, capability in ipairs({ "install", "install_async" }) do
				helpers.it("refuses " .. capability .. " " .. invalid.name .. " despite a valid counterpart", function()
					local ports, seen = recording()
					ports.install_async = function() error("construction must not dispatch async work") end
					ports[capability] = invalid.value
					local ok, reason = pcall(Install.new, ports)
					helpers.assert_eq(ok, false)
					local label = capability == "install" and "sync" or "async"
					local messages = { "release_install " .. label .. " install port is invalid" }
					if capability == "install" then messages[#messages + 1] = "release_install needs the install port" end
					helpers.assert_true(names_refusal(reason, messages), "the refusal must name the actual invalid capability")
					helpers.assert_eq(seen.calls, {}, "invalid capability must be refused before backup and download")
					helpers.assert_eq(seen.reports, {})
				end)
			end
		end
	end)

end

return M
