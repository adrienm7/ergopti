--- linux/tests/unit/meta/test_changelog_release_install.lua

--- ==============================================================================
--- MODULE: Versions Window Release Install (Linux)
--- DESCRIPTION:
--- The Versions window listed releases with « View on GitHub » and nothing
--- else. Its « Install this version » button now posts install_release, and
--- the bridge runs the shared sequence over the real updater manager: back the
--- configuration up, find the release in the list the window fetched, then
--- download, verify and install it through the manager's update path and
--- restart. These cases drive the real bridge and manager with a stubbed
--- transport, digest, installer, backup owner and restart hook: nothing is
--- downloaded and nothing is installed for real.
---
--- The last case is the "never on its own" guard: the background schedule finds
--- a newer release and only announces it; no download and no install follow.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local ASSET = "ergopti-plus-linux.tar.gz"
local DIGEST = string.rep("ab", 32)

--- One release object of the GitHub API list.
--- @param tag string
--- @param with_bundle boolean Whether it carries the Linux bundle and checksum.
--- @return table
local function release(tag, with_bundle)
	local base = "https://github.com/adrienm7/ergopti/releases/download/" .. tag .. "/"
	local assets = {}
	if with_bundle then
		assets = {
			{ name = ASSET, browser_download_url = base .. ASSET },
			{ name = ASSET .. ".sha256", browser_download_url = base .. ASSET .. ".sha256" },
		}
	end
	return { tag_name = tag, prerelease = true, published_at = "2026-09-28T10:00:00Z",
		html_url = "https://github.com/adrienm7/ergopti/releases/tag/" .. tag, body = "notes", assets = assets }
end

local LIST = Json.encode({
	release("v0.0.0-dev.141", false),
	release("v0.0.0-dev.140", true),
	release("v0.0.0-dev.139", true),
})

--- Builds the real bridge over the real manager with every effect recorded.
--- @param opts table|nil { version, source_run, kind, digest, feed, backup_fails }
--- @return table ctx
local function harness(opts)
	opts = opts or {}
	local ctx = { events = {}, pushes = {}, restarts = {}, installs = {} }
	local function event(name) ctx.events[#ctx.events + 1] = name end
	local saved = {}
	for _, name in ipairs({ "infra.version", "modules.updater.manager", "ui.changelog.bridge" }) do
		saved[name] = package.loaded[name]
	end
	local RealVersion = require("infra.version")
	package.loaded["infra.version"] = setmetatable({ VERSION = opts.version or "0.0.0-dev.140" },
		{ __index = RealVersion })
	-- The suite runs from a checkout, which is a source run: each case says.
	local Installation = require("infra.installation")
	local real_is_source_run = Installation.is_source_run
	Installation.is_source_run = function() return opts.source_run == true end
	local manager = helpers.load_module("modules.updater.manager")
	local Installer = require("modules.updater.installer")
	ctx.real_install = Installer.install
	Installer.install = function(args)
		event("install")
		ctx.installs[#ctx.installs + 1] = args
		return true
	end
	ctx.Installer = Installer
	manager._resolve_installation = function()
		return { kind = opts.kind or "standalone", reason = "test", wrapper = "/opt/test/ergopti" }
	end
	manager._http_client = {
		get = function(url, _, _, callback)
			event("checksum:" .. url)
			callback({ ok = true, status = 200, body = DIGEST .. "  " .. ASSET .. "\n" })
			return true
		end,
		download = function(url, _, destination, _, callback)
			event("download:" .. url)
			local handle = assert(io.open(destination, "wb"))
			handle:write("archive")
			handle:close()
			callback({ ok = true, status = 200, body = "" })
			return true
		end,
		cancel = function() return true end,
	}
	manager._file_digest = {
		sha256 = function(_, _, callback)
			event("digest")
			callback(opts.digest or DIGEST, nil)
			return true
		end,
		cancel = function() return true end,
	}
	ctx.manager = manager
	local bridge = helpers.load_module("ui.changelog.bridge")
	bridge._push = function(payload) ctx.pushes[#ctx.pushes + 1] = payload; return true end
	bridge._http_get = function(_, _, _, callback)
		if opts.feed then
			callback(0, "", "blocked")
		else
			callback(200, LIST, nil)
		end
	end
	bridge._config_backup = {
		owner = function()
			return {
				create = function(kind, meta)
					event("backup")
					ctx.backup_meta = { kind = kind, tag = meta.tag, from_version = meta.from_version }
					if opts.backup_fails then return nil, "disk full" end
					return { path = "/cfg/backups/pre-install-x", id = "pre-install-x" }
				end,
				latest = function()
					return opts.latest
				end,
				restore = function(id)
					event("restore:" .. tostring(id))
					if opts.restore_fails then return false, opts.restore_fails, { path = "/cfg/backups/pre-restore-y" } end
					return true, nil, { path = "/cfg/backups/pre-restore-y" }
				end,
			}
		end,
	}
	ctx.state = {
		restart_after_update = function() event("restart"); return true end,
		restart = function(reason) event("restart:" .. reason); return true end,
	}
	ctx.bridge = bridge
	function ctx.restore_modules()
		if ctx.document_fixture then ctx.document_fixture.close() end
		Installer.install = ctx.real_install
		Installation.is_source_run = real_is_source_run
		for name, value in pairs(saved) do package.loaded[name] = value end
	end
	-- The window opens and loads the list (feed-only when opts.feed: the stub
	-- API fails, and the feed stub below serves the Atom text).
	if opts.feed then
		local fed = false
		bridge._http_get = function(url, _, _, callback)
			if url:find("releases.atom", 1, true) and not fed then
				fed = true
				callback(200, "<feed></feed>", nil)
			else
				callback(0, "", "blocked")
			end
		end
	end
	ctx.document_fixture = require("tests.support.document_fixture").new("changelog", bridge, ctx.state)
	ctx.bridge = ctx.document_fixture.proxy()
	ctx.initial = ctx.document_fixture.handshake()
	return ctx
end

--- The install_progress pushes, in order.
local function progress(ctx)
	local out = {}
	for _, payload in ipairs(ctx.pushes) do
		if payload.action == "install_progress" then out[#out + 1] = payload end
	end
	return out
end

local function phases(ctx)
	local out = {}
	for _, payload in ipairs(progress(ctx)) do out[#out + 1] = payload.phase end
	return table.concat(out, ",")
end

local function index_of(list, prefix)
	for index, value in ipairs(list) do
		if value:sub(1, #prefix) == prefix then return index end
	end
	return nil
end

helpers.describe("changelog_bridge: one-click release install", function()
	helpers.it("announces the installed build and the restorable backup when the page is ready", function()
		local ctx = harness({ latest = { id = "pre-install-b", created_at = "2026-09-30T10:00:00Z", tag = "v1" } })
		ctx.restore_modules()
		local context = ctx.initial.install
		helpers.assert_eq(ctx.initial.action, "releases", "the context rides on the release answer")
		helpers.assert_eq(context.installed, "0.0.0-dev.140")
		helpers.assert_eq(context.blocked_key, "")
		helpers.assert_eq(context.backup.id, "pre-install-b")
	end)

	helpers.it("backs up first, then downloads, verifies, installs through the update path and restarts", function()
		local ctx = harness()
		ctx.bridge.on_message({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(phases(ctx), "backing_up,downloading,installing,restarting")
		helpers.assert_eq(index_of(ctx.events, "backup"), 1, "the backup is the first effect")
		helpers.assert_true(index_of(ctx.events, "checksum:") > index_of(ctx.events, "backup"))
		helpers.assert_contains(ctx.events[index_of(ctx.events, "download:")], "/v0.0.0-dev.139/" .. ASSET)
		helpers.assert_true(index_of(ctx.events, "install") > index_of(ctx.events, "digest"),
			"the install follows the verification")
		helpers.assert_eq(#ctx.installs, 1)
		helpers.assert_eq(ctx.installs[1].expected_version, "v0.0.0-dev.139",
			"the installer checks the archive carries the chosen version")
		helpers.assert_eq(ctx.events[#ctx.events], "restart")
		helpers.assert_eq(ctx.backup_meta.tag, "v0.0.0-dev.139")
		helpers.assert_eq(ctx.backup_meta.from_version, "0.0.0-dev.140")
		helpers.assert_eq(progress(ctx)[4].backup_path, "/cfg/backups/pre-install-x")
	end)

	helpers.it("refuses a release without the Linux bundle, keeping the backup", function()
		local ctx = harness()
		ctx.bridge.on_message({ action = "install_release", tag = "v0.0.0-dev.141", channel = "dev" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(table.concat(ctx.events, ","), "backup")
		local last = progress(ctx)[#progress(ctx)]
		helpers.assert_eq(last.phase, "failed")
		helpers.assert_eq(last.reason_key, "changelog_window.install_error_no_asset")
		helpers.assert_eq(last.backup_path, "/cfg/backups/pre-install-x")
	end)

	helpers.it("never installs an archive whose checksum does not match", function()
		local ctx = harness({ digest = string.rep("00", 32) })
		ctx.bridge.on_message({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(#ctx.installs, 0)
		helpers.assert_nil(index_of(ctx.events, "restart"))
		local last = progress(ctx)[#progress(ctx)]
		helpers.assert_eq(last.reason_key, "changelog_window.install_error_verify")
		helpers.assert_eq(last.backup_path, "/cfg/backups/pre-install-x")
		helpers.assert_true(ctx.manager.get_state() ~= "downloading", "the updater is free for Retry")
	end)

	helpers.it("downloads nothing when the backup fails", function()
		local ctx = harness({ backup_fails = true })
		ctx.bridge.on_message({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(table.concat(ctx.events, ","), "backup")
		helpers.assert_eq(progress(ctx)[#progress(ctx)].reason_key, "changelog_window.install_error_backup")
	end)

	helpers.it("greys a source run and refuses its request without a backup", function()
		local ctx = harness({ version = "local", source_run = true })
		ctx.bridge.on_message({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(ctx.initial.install.blocked_key, "changelog_window.install_blocked_source")
		helpers.assert_eq(#ctx.events, 0)
		helpers.assert_eq(progress(ctx)[1].phase, "failed")
	end)

	helpers.it("greys a system-package installation", function()
		local ctx = harness({ kind = "package" })
		ctx.restore_modules()
		helpers.assert_eq(ctx.initial.install.blocked_key, "changelog_window.install_blocked_package")
	end)

	helpers.it("refuses to install from the Atom feed, which lists no files", function()
		local ctx = harness({ feed = true })
		ctx.bridge.on_message({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(#ctx.events, 0)
		helpers.assert_eq(progress(ctx)[1].reason_key, "changelog_window.install_error_no_details")
	end)

	helpers.it("restores a backup and restarts the daemon on it", function()
		local ctx = harness()
		local answer = ctx.bridge.on_message({ action = "restore_backup", id = "pre-install-x" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(answer.phase, "restored")
		helpers.assert_eq(table.concat(ctx.events, ","), "restore:pre-install-x,restart:configuration restored")
	end)

	helpers.it("names why a restore failed and keeps the replaced configuration's backup", function()
		local ctx = harness({ restore_fails = "write" })
		local answer = ctx.bridge.on_message({ action = "restore_backup", id = "pre-install-x" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(answer.phase, "failed")
		helpers.assert_eq(answer.reason_key, "changelog_window.restore_error_unexpected")
		helpers.assert_eq(answer.backup_path, "/cfg/backups/pre-restore-y")
		helpers.assert_nil(index_of(ctx.events, "restart"), "a failed restore restarts nothing")
	end)
end)

helpers.describe("updater: nothing installs without a click (Linux)", function()
	helpers.it("a background check announces a newer release and downloads nothing", function()
		local Fakes = helpers.load_module("tests.fakes")
		local saved = {}
		for _, name in ipairs({ "adapters.timer_scheduler", "adapters.storage", "modules.updater.manager" }) do
			saved[name] = package.loaded[name]
		end
		local timers = {}
		package.loaded["adapters.timer_scheduler"] = {
			HAS_ASYNC = true,
			after = function(delay, fn)
				local handle = { armed = true, delay = delay, fn = fn }
				timers[#timers + 1] = handle
				return handle
			end,
			cancel = function(handle) handle.armed = false; return true end,
		}
		package.loaded["adapters.storage"] = Fakes.storage({ initial = {} })
		package.loaded["modules.updater.manager"] = nil
		local M = require("modules.updater.manager")
		local Installer = require("modules.updater.installer")
		local real_install = Installer.install
		local effects, announced = {}, {}
		Installer.install = function() effects[#effects + 1] = "install"; return true end
		M._http_client = {
			get = function(_, _, _, callback)
				callback({ ok = true, status = 200, body = Json.encode({ release("v0.0.0-dev.999", true) }) })
				return true
			end,
			download = function() effects[#effects + 1] = "download"; return true end,
			cancel = function() return true end,
		}
		M._file_digest = { sha256 = function() effects[#effects + 1] = "digest"; return true end,
			cancel = function() return true end }
		M.current_version = function() return "0.0.0-dev.1" end
		local now = 1700000000
		M._now = function() return now end
		local config_path = os.tmpname()
		pcall(os.remove, config_path)
		-- An installed build: the checkout the suite runs from checks for nothing.
		local Installation = require("infra.installation")
		local real_is_source_run = Installation.is_source_run
		Installation.is_source_run = function() return false end
		local ok, err = pcall(function()
			M.init({ config_path = config_path, channel = "dev", is_paused = function() return false end,
				on_available = function(found) announced[#announced + 1] = found.tag; return true end })
			for _ = 1, 6 do
				local pending = timers[#timers]
				if pending and pending.armed then
					pending.armed = false
					now = now + pending.delay
					pending.fn()
				end
			end
		end)
		Installer.install = real_install
		Installation.is_source_run = real_is_source_run
		pcall(M.stop_background_checks)
		pcall(os.remove, config_path)
		for name, value in pairs(saved) do package.loaded[name] = value end
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(table.concat(announced, ","), "v0.0.0-dev.999", "the newer release is announced")
		helpers.assert_eq(#effects, 0, "no download, digest or install without a click: " .. table.concat(effects, ","))
		helpers.assert_eq(M.get_state(), "available")
	end)
end)
