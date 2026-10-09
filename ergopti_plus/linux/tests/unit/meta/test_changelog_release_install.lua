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

--- Explicit unit-only artifact/receipt ports. These model physical ACKs;
--- they do not qualify native FD sealing, HTTP, hashing or tar installation.
local function native_fixture(ctx, options)
	local dependency = {}
	for _, name in ipairs({ "infra.archive_output", "infra.monotonic" }) do
		dependency[name] = { value = package.loaded[name] }
	end
	local owners, now = {}, 0.25
	local function operation(dispatch)
		local physical, listeners = false, {}
		local work = { started = false }
		local function ack()
			physical = true
			local pending = listeners; listeners = {}
			for _, listener in ipairs(pending) do listener() end
		end
		function work:is_settled() return physical end
		function work:on_settled(listener)
			assert(type(listener) == "function")
			if physical then listener() else listeners[#listeners + 1] = listener end
			return true
		end
		function work:request_cancel() ack(); return true end
		work.started = dispatch(ack) == true
		return work
	end
	local function remove_owned(owner)
		if not owner.path_live then return true end
		local removed = os.remove(owner.path)
		if removed ~= true then return false end
		owner.path_live = false
		return true
	end
	local function make_artifact(name)
		assert(name == ASSET)
		local factory, owner = {}, nil
		local function exact(brand)
			assert(owner and rawequal(brand, owner.brand), "foreign fixture artifact")
			return owner
		end
		function factory.reserve_transfer(meta, token, lineage, current, deadline)
			assert(owner == nil and type(token) == "table" and lineage() == true and current() == true)
			assert(type(meta.tag) == "string" and deadline > now)
			local path = os.tmpname()
			local handle = assert(io.open(path, "wb"))
			assert(handle:close())
			owner = { brand = {}, target = {}, token = token, lineage = lineage, current = current,
				path = path, path_live = true, transfer_closed = false, listeners = {} }
			owners[#owners + 1] = owner
			return owner.brand, owner.target
		end
		function factory.bind_checksum(brand, expected)
			local state = exact(brand)
			assert(state.expected == nil and state.current() == true and expected == DIGEST)
			state.expected = expected
			return true
		end
		function factory.seal_and_adopt(brand, completion, expected, deadline, done)
			local state = exact(brand)
			assert(rawequal(completion, state.completion) and state.expected == expected)
			assert(state.current() == true and deadline > now and not state.transfer_closed)
			return operation(function(ack)
				return ctx.manager._file_digest.sha256(state.path, "updater", function(actual, failure)
					state.transfer_closed = true -- All fixture transport handles are closed.
					if actual == expected and failure == nil then
						state.adopted = true; done(state.path)
					else done(nil, failure or "checksum mismatch") end
					ack()
				end)
			end)
		end
		function factory.cancel_transfer(brand)
			local state = exact(brand)
			if not remove_owned(state) then return false end
			state.transfer_closed = true
			local listeners = state.listeners; state.listeners = {}
			for _, listener in ipairs(listeners) do listener() end
			return true
		end
		function factory.transfer_settled(brand) return exact(brand).transfer_closed end
		function factory.on_transfer_settled(brand, listener)
			local state = exact(brand)
			if state.transfer_closed then listener() else state.listeners[#state.listeners + 1] = listener end
			return true
		end
		function factory.retire_artifact(brand)
			local state = exact(brand)
			if state.install then return false end
			return remove_owned(state)
		end
		function factory.artifact_settled(brand) return not exact(brand).path_live end
		function factory.on_artifact_settled(brand, listener)
			if factory.artifact_settled(brand) then listener(); return true end
			return false -- No fabricated namespace-close ACK.
		end
		function factory.begin_install(brand, token, _, admission, execution)
			local state = exact(brand)
			assert(rawequal(token, state.token) and state.transfer_closed and state.adopted)
			assert(state.install == nil and admission() == true and execution() == true)
			state.install = { execution = execution }
			return state.install
		end
		function factory.install_current(reservation)
			return owner and rawequal(reservation, owner.install) and owner.path_live and reservation.execution() == true
		end
		function factory.install_feed() error("unit installer never starts native tar") end
		function factory.finish_install(reservation)
			assert(factory.install_current(reservation))
			if not remove_owned(owner) then return false end
			owner.install = nil
			return true
		end
		ctx.native_factory = factory
		return factory
	end
	-- Literal portable clock port, isolated to this model's module cache.
	-- The production monotonic backend is neither replaced globally nor qualified here.
	package.loaded["infra.monotonic"] = { has_hires = function() return true end,
		backend = function() return "luv.hrtime" end, now_ms = function() return now end }
	package.loaded["infra.archive_output"] = { native_artifact = make_artifact }
	ctx.manager._http_client.get_owned = function(url, headers, opts, done)
		assert(opts.owner == "updater" and opts.authorized() == true and opts.absolute_deadline_ms > now)
		return operation(function(ack)
			return ctx.manager._http_client.get(url, headers, opts.timeout_ms, function(result)
				done(result); ack()
			end)
		end)
	end
	ctx.manager._http_client.download_output_owned = function(url, headers, target, opts, done)
		assert(#owners == 1 and rawequal(target, owners[1].target))
		local state = owners[1]
		assert(opts.owner == "updater" and opts.authorized() == true and opts.absolute_deadline_ms > now)
		return operation(function(ack)
			return ctx.manager._http_client.download(url, headers, state.path, opts.timeout_ms, function(result)
				state.completion = {}; done(result, state.completion); ack()
			end)
		end)
	end
	local original_install_owned = ctx.Installer.install_owned
	ctx.Installer.install_owned = function(args, done)
		assert(rawequal(args.factory, ctx.native_factory) and args.factory.install_current(args.reservation) == true)
		return operation(function(ack)
			local completed = ctx.Installer.install(args) == true
			local retired = args.factory.finish_install(args.reservation) == true
			if not retired then return false end
			done(completed); ack(); return true
		end)
	end
	return {
		bind_document_clock = function()
			-- The authentic document fixture owns this clock after its handshake.
			-- Delegate that same model time to the unit-only native capability port.
			local clock = package.loaded["infra.monotonic"]
			assert(type(clock) == "table")
			local read, hires = rawget(clock, "now_ms"), rawget(clock, "has_hires")
			assert(type(read) == "function" and type(hires) == "function" and hires() == true)
			now = read()
			assert(type(now) == "number" and now >= 0 and now < math.huge)
			package.loaded["infra.monotonic"] = {
				has_hires = hires,
				backend = function() return "luv.hrtime" end, -- Explicit modeled capability, not native evidence.
				now_ms = function() now = read(); return now end,
			}
		end,
		close = function()
			for _, owner in ipairs(owners) do assert(remove_owned(owner), "fixture artifact cleanup refused") end
			ctx.Installer.install_owned = original_install_owned
			for name, snapshot in pairs(dependency) do package.loaded[name] = snapshot.value end
		end,
	}
end

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
	ctx.native_fixture = native_fixture(ctx, opts)
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
					if opts.backup_probe then opts.backup_probe(ctx) end
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
		ctx.native_fixture.close()
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
	ctx.native_fixture.bind_document_clock()
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
		M._http_client = require("tests.support.release_http_fixture").attach(M._http_client)
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

helpers.describe("changelog_bridge: captured post-backup resolver lineage", function()
	helpers.it("resolves a missing asset only after preserving the actual configuration backup", function()
		local ctx = harness()
		local resolve = ctx.manager.release_record
		ctx.manager.release_record = function(chunk)
			helpers.assert_eq(ctx.events[1], "backup", "asset inspection cannot precede the backup")
			return resolve(chunk)
		end
		ctx.bridge.on_message({ action = "install_release", tag = "v0.0.0-dev.141", channel = "dev" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(table.concat(ctx.events, ","), "backup")
		helpers.assert_eq(progress(ctx)[#progress(ctx)].reason_key, "changelog_window.install_error_no_asset")
		helpers.assert_eq(progress(ctx)[#progress(ctx)].backup_path, "/cfg/backups/pre-install-x")
	end)

	helpers.it("a resolver replaced during backup cannot supply successor asset authority", function()
		local replaced = 0
		local ctx = harness({ backup_probe = function(context)
			context.manager.release_record = function() replaced = replaced + 1; error("foreign resolver") end
		end })
		ctx.bridge.on_message({ action = "install_release", tag = "v0.0.0-dev.139", channel = "dev" }, ctx.state)
		ctx.restore_modules()
		helpers.assert_eq(table.concat(ctx.events, ","), "backup")
		helpers.assert_eq(replaced, 0, "the captured resolver cannot borrow a later replacement")
		helpers.assert_eq(#ctx.installs, 0)
		helpers.assert_nil(index_of(ctx.events, "restart"))
		helpers.assert_eq(progress(ctx)[#progress(ctx)].backup_path, "/cfg/backups/pre-install-x")
	end)
end)
