--- tests/unit/ui/test_menu_about_update_integrity.lua
---
--- ============================================================================
--- MODULE: Menu About Self-Update Integrity Regression Tests
--- DESCRIPTION:
--- Drives the real one-click cached-update action and proves unsafe metadata or
--- a mismatched archive digest cannot reach disk or the unzip/install boundary.
--- ============================================================================

local helpers = require("tests.helpers")

local DIGEST = string.rep("a", 64)
local OTHER_DIGEST = string.rep("b", 64)
local TAG = "v2.0.0"
local VALID_URL = "https://github.com/adrienm7/ergopti/releases/download/"
	.. TAG .. "/ErgoptiPlus.app.zip"


--- Runs the cached-update menu action with controlled integrity boundaries.
--- @param opts table Fixture controls.
--- @return table result Observed HTTP, write, and install counts.
local function run_cached_update(opts)
	helpers.load_with_stubs("infra.logger", {
		processInfo = {
			bundleID = "com.ergopti.app",
			bundlePath = "/Applications/ErgoptiPlus.app",
			version = "1.0.0",
		},
		fs = {
			temporaryDirectory = function() return "/tmp/" end,
			attributes = function() return { mode = "directory" } end,
		},
	})

	local observed = {
		http = 0,
		writes = 0,
		install_tasks = 0,
		started_tasks = 0,
		alerts = 0,
		notifications = {},
		menu_updates = 0,
	}
	local update_state = "available"
	local cached = opts.cached
	local install_token = nil

	package.loaded["modules.updater"] = {
		INTERVAL_PRESETS = {},
		get_check_interval = function() return 3600 end,
		is_local_source = function() return false end,
		current_version = function() return "1.0.0" end,
		get_update_state = function() return update_state end,
		get_update_menu_label = function() return "update" end,
		get_cached_release = function() return cached end,
		set_update_state = function(value) update_state = value end,
		begin_install = function()
			if install_token ~= nil then return nil end
			install_token = {}
			update_state = "installing"
			return install_token
		end,
		is_install_current = function(token) return token == install_token end,
		finish_install = function(token, value)
			if token ~= install_token then return false end
			install_token = nil
			update_state = value
			return true
		end,
		validate_install_asset = function() return opts.metadata_valid == true, "unsafe metadata" end,
		clear_cached_release = function() cached = nil end,
		release_api_url = function() return "https://api.github.test/releases/latest" end,
		releases_page_url = function() return "https://github.test/releases" end,
	}
	package.loaded["adapters.crypto"] = {
		sha256_bytes = function(body)
			helpers.assert_eq(body, opts.body)
			return opts.actual_digest
		end,
	}
	package.loaded["infra.dialog_util"] = {
		block_alert = function() observed.alerts = observed.alerts + 1 end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(title, body, kind)
			observed.notifications[#observed.notifications + 1] = {
				title = title,
				body = body,
				kind = kind,
			}
			if opts.notification_throw then error("notification sentinel") end
			if opts.notification_result ~= nil then
				return opts.notification_result, "notification refusal"
			end
			return true
		end,
	}
	package.loaded["ui.changelog"] = { open = function() end }
	package.loaded["infra.manifest_menu"] = {
		build = function(_, _, _, _, _, providers)
			return providers.about_updates()
		end,
	}
	package.loaded["adapters.task_lifecycle"] = {
		native = function()
			observed.install_tasks = observed.install_tasks + 1
			return {}
		end,
		start = function()
			observed.started_tasks = observed.started_tasks + 1
			return true
		end,
	}

	_G.hs.http = {
		asyncGet = function(url, _, callback)
			observed.http = observed.http + 1
			observed.url = url
			callback(200, opts.body, {})
		end,
	}

	package.loaded["ui.menu.menu_about"] = nil
	local About = require("ui.menu.menu_about")
	local built = About.build({
		state = { update_channel = "main", update_check_interval_seconds = 3600 },
		updateMenu = function() observed.menu_updates = observed.menu_updates + 1 end,
	})
	local update_action
	for _, row in ipairs(built.submenu) do
		if type(row.action) == "function" then update_action = row.action end
	end
	helpers.assert_type(update_action, "function", "cached update action must be rendered")

	local saved_open = io.open
	local ok, err = xpcall(function()
		io.open = function(_, mode)
			helpers.assert_eq(mode, "wb")
			observed.writes = observed.writes + 1
			return {
				write = function(_, body) observed.written_body = body return true end,
				close = function() return true end,
			}
		end
		update_action()
	end, debug.traceback)
	io.open = saved_open
	if not ok then error(err, 0) end
	observed.state = update_state
	return observed
end


helpers.describe("menu_about: self-update archive integrity", function()
	helpers.it("keeps HTTP and task completion paths free of blocking modals", function()
		local source = helpers.read_driver_source("local function get_update_menu_label")
		helpers.assert_not_nil(source,
			"the production update-flow source must be discoverable")
		helpers.assert_true(source:find("hs.http.asyncGet", 1, true) ~= nil,
			"the source guard must still cover the native HTTP completion boundary")
		helpers.assert_true(source:find("TaskLifecycle.native", 1, true) ~= nil,
			"the source guard must still cover the native task completion boundary")
		helpers.assert_nil(source:find("block_alert", 1, true),
			"an async update completion must never enter a nested modal run loop")
		helpers.assert_true(source:find("local function notify_update", 1, true) ~= nil,
			"the async outcome must retain a non-blocking user-visible surface")
	end)

	helpers.it("refuses unsafe cached metadata before dispatching a download", function()
		local result = run_cached_update({
			cached = { tag = TAG, zip_url = "https://evil.test/archive.zip", sha256 = DIGEST },
			metadata_valid = false,
			body = "archive",
			actual_digest = DIGEST,
		})

		helpers.assert_eq(result.http, 0)
		helpers.assert_eq(result.writes, 0)
		helpers.assert_eq(result.install_tasks, 0)
		helpers.assert_eq(result.state, "available")
		helpers.assert_eq(result.alerts, 0,
			"metadata refusal must never open a modal from the update action")
		helpers.assert_eq(#result.notifications, 1,
			"metadata refusal must remain visible through one non-blocking notification")
		helpers.assert_eq(result.notifications[1].kind, "error")
	end)

	helpers.it("rejects a digest mismatch before writing or unzipping the archive", function()
		local result = run_cached_update({
			cached = { tag = TAG, zip_url = VALID_URL, sha256 = DIGEST },
			metadata_valid = true,
			body = "substituted archive",
			actual_digest = OTHER_DIGEST,
		})

		helpers.assert_eq(result.http, 1)
		helpers.assert_eq(result.url, VALID_URL)
		helpers.assert_eq(result.writes, 0)
		helpers.assert_eq(result.install_tasks, 0)
		helpers.assert_eq(result.state, "available")
		helpers.assert_eq(result.alerts, 0,
			"digest failure inside asyncGet must never park the main run loop")
		helpers.assert_eq(#result.notifications, 1,
			"digest failure must remain visible without a modal")
		helpers.assert_eq(result.notifications[1].kind, "error")
	end)

	helpers.it("settles the updater even when non-blocking notification raises", function()
		local result = run_cached_update({
			cached = { tag = TAG, zip_url = "https://evil.test/archive.zip", sha256 = DIGEST },
			metadata_valid = false,
			body = "archive",
			actual_digest = DIGEST,
			notification_throw = true,
		})

		helpers.assert_eq(result.state, "available",
			"notification failure must not strand the exact install owner")
		helpers.assert_eq(result.alerts, 0,
			"notification failure must never fall back to a modal")
		helpers.assert_eq(#result.notifications, 1,
			"the non-blocking notification boundary must be attempted exactly once")
	end)

	helpers.it("writes and starts installation only after the digest matches", function()
		local body = "verified\0archive"
		local result = run_cached_update({
			cached = { tag = TAG, zip_url = VALID_URL, sha256 = DIGEST },
			metadata_valid = true,
			body = body,
			actual_digest = DIGEST,
		})

		helpers.assert_eq(result.http, 1)
		helpers.assert_eq(result.writes, 1)
		helpers.assert_eq(result.written_body, body)
		helpers.assert_eq(result.install_tasks, 1)
		helpers.assert_eq(result.started_tasks, 1)
		helpers.assert_eq(result.alerts, 0)
		helpers.assert_eq(#result.notifications, 0,
			"a successful verified dispatch must not emit a failure notification")
	end)
end)
