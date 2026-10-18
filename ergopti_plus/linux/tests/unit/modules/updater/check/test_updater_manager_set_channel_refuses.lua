--- tests/unit/modules/updater/check/test_updater_manager_set_channel_refuses.lua

package.loaded["tests.support.modules.updater.check.updater_manager_fixture"] = nil
local Fixture = require("tests.support.modules.updater.check.updater_manager_fixture")
local helpers, Fakes, etag_response, with_config, read_config =
	Fixture.helpers, Fixture.Fakes, Fixture.etag_response, Fixture.with_config, Fixture.read_config




helpers.describe("modules/updater/manager.lua", function()
	local M = helpers.load_module("modules.updater.manager")

	-- Explicit portable native-port model only for the original controlled
	-- download tests below. Real Manager/Transfer execute their ownership laws.
	local function with_native_download_model(body)
		local previous = M
		local ok, failure = xpcall(function()
			require("tests.support.updater_native_model").with_fixture(function(fresh, prepare)
				M = fresh
				body(prepare)
			end)
		end, debug.traceback)
		M = previous
		if not ok then error(failure, 0) end
	end

	local function release(tag, prerelease)
		return string.format('{"tag_name":"%s","prerelease":%s,"assets":['
			.. '{"name":"%s","browser_download_url":"https://example.invalid/%s/bundle"},'
			.. '{"name":"%s","browser_download_url":"https://example.invalid/%s/sum"}]}',
			tag, tostring(prerelease), M.LINUX_ASSET_NAME, tag, M.LINUX_CHECKSUM_ASSET_NAME, tag)
	end

	helpers.it("set_channel refuses aliases and ids outside the registry", function()
		with_config(nil, function(fresh)
			local before = fresh.get_channel()
			for _, value in ipairs({ "stable", "unknown_channel", "Main" }) do
				helpers.assert_eq(fresh.set_channel(value), false, value .. " must be refused")
				helpers.assert_eq(fresh.get_channel(), before, value .. " must not change the channel")
			end
		end)
	end)

	helpers.it("init reads the persisted channel through the registry", function()
		with_config('[updater]\nchannel = "stable"\n', function(fresh)
			helpers.assert_eq(fresh.get_channel(), "main", "the old 'stable' spelling reads as main")
		end)
		with_config('[updater]\nchannel = "dev"\n', function(fresh)
			helpers.assert_eq(fresh.get_channel(), "dev")
		end)
		with_config('[updater]\nchannel = "beta"\n', function(fresh)
			helpers.assert_eq(fresh.get_channel(), fresh.installed_channel(),
				"an unknown value follows the installed build's channel")
		end)
	end)

	helpers.it("set_check_interval and get_check_interval round-trip through config.toml", function()
		with_config(nil, function(fresh, path)
			helpers.assert_true(fresh.set_check_interval(3600))
			helpers.assert_eq(fresh.get_check_interval(), 3600, "interval should be 3600")
			helpers.assert_eq(read_config(path).updater.check_interval_seconds, 3600,
				"the interval lives in config.toml like on the other drivers")
		end)
	end)

	helpers.it("set_check_interval rejects negative values", function()
		local orig = M.get_check_interval()
		M.set_check_interval(-10)
		helpers.assert_eq(M.get_check_interval(), orig, "interval should not change on negative")
	end)

	helpers.it("keeps the durable channel and interval when persistence fails", function()
		local previous_storage = package.loaded["adapters.storage"]
		local previous_manager = package.loaded["modules.updater.manager"]
		local storage = Fakes.storage({ writes_fail = true })
		package.loaded["adapters.storage"] = storage
		package.loaded["modules.updater.manager"] = nil
		local failing = require("modules.updater.manager")
		-- A config.toml whose directory does not exist: the writer must refuse.
		local unwritable = os.tmpname() .. "-missing-dir/config.toml"
		failing.init({ config_path = unwritable })
		local before = failing.get_channel()
		local target = before == "dev" and "main" or "dev"

		local channel_changed = failing.set_channel(target)
		local interval_changed = failing.set_check_interval(3600)
		local channel = failing.get_channel()
		local interval = failing.get_check_interval()
		failing.stop_background_checks()

		package.loaded["adapters.storage"] = previous_storage
		package.loaded["modules.updater.manager"] = previous_manager
		helpers.assert_eq(channel_changed, false)
		helpers.assert_eq(interval_changed, false)
		helpers.assert_eq(channel, before, "a failed write must not switch the live release feed")
		helpers.assert_eq(interval, failing.DEFAULT_INTERVAL_SEC, "a failed write must not change the live schedule")
	end)

	helpers.it("clear_cached_release resets state to idle", function()
		M.clear_cached_release()
		helpers.assert_eq(M.get_state(), "idle", "state should be idle after clear")
		helpers.assert_nil(M.get_cached_release(), "cached release should be nil after clear")
	end)

	helpers.it("refuses to download a release other than the one the user chose", function()
		M._test_set_cached_release({ tag = "v2", download_url = "https://example.invalid/2.tar.gz",
			checksum_url = "https://example.invalid/2.sha256" })
		local answered = nil
		local dispatched = M.download_update("https://example.invalid/1.tar.gz", function(path, err)
			answered = { path = path, err = err }
		end)
		helpers.assert_true(dispatched == false, "a stale consent must not start a download")
		helpers.assert_true(answered ~= nil and answered.path == nil, "the caller learns the download was refused")
		M.clear_cached_release()
	end)

	helpers.it("get_menu_label returns a string for every state", function()
		-- Should return a non-empty string even without having checked.
		local label = M.get_menu_label()
		helpers.assert_true(type(label) == "string", "menu label should be a string")
		helpers.assert_true(#label > 0, "menu label should not be empty")
	end)

	-- Every one of these labels was hardcoded French, so a user on any of the
	-- other 20 locales read French in the update menu. "not empty" above could
	-- never have caught that, and neither can it catch i18n.get echoing the raw
	-- key back on a miss.
	helpers.it("the idle label comes from the shared catalogue", function()
		local i18n = require("infra.i18n")
		M.clear_cached_release()
		local label = M.get_menu_label()
		-- The registry channel is displayed on its own checked row.
		local expected = i18n.get("menu.about.check_for_updates")
		helpers.assert_eq(label, expected,
			"the idle label must be whatever the catalogue says for the active locale")
		helpers.assert_true(label ~= "menu.about.check_for_updates",
			"an echoed key means the catalogue was never reached")
	end)

	-- The row this label names runs check_for_updates. With a release cached it
	-- read "Update to <tag>", so the user clicked what looked like the update and
	-- only got another check, next to the "Download and install <tag>" row that
	-- really installs it.
	helpers.it("the check row still names a check while a release is available", function()
		local i18n = require("infra.i18n")
		M._test_set_cached_release({ tag = "v9.9.9-100%", prerelease = false })
		local label = M.get_menu_label()
		local expected = i18n.get("menu.about.check_for_updates")
		M.clear_cached_release()
		helpers.assert_eq(label, expected,
			"the row runs a check, so it must be labelled as one whatever the cached release")
		helpers.assert_true(label:find("v9.9.9-100%", 1, true) == nil,
			"the release belongs to the install row, not to the check row")
	end)

	helpers.it("stop_background_checks is safe to call even without active timers", function()
		-- Should not error.
		M.stop_background_checks()
		helpers.assert_eq(type(M.start_background_checks), "function",
			"a stop with no timers armed must leave the checks restartable")
	end)

	helpers.it("reports unavailable background scheduling instead of silently dropping checks", function()
		local previous_timer = package.loaded["adapters.timer_scheduler"]
		local previous_manager = package.loaded["modules.updater.manager"]
		package.loaded["adapters.timer_scheduler"] = {
			HAS_ASYNC = false,
			cancel = function() end,
		}
		package.loaded["modules.updater.manager"] = nil
		local unavailable = require("modules.updater.manager")
		local started = unavailable.start_background_checks(nil, 60)

		package.loaded["adapters.timer_scheduler"] = previous_timer
		package.loaded["modules.updater.manager"] = previous_manager
		helpers.assert_eq(started, false,
			"missing luv must be a truthful unavailable capability, not a green schedule")
	end)

	helpers.it("reports a schedule whose timer was not armed", function()
		local previous_timer = package.loaded["adapters.timer_scheduler"]
		local previous_manager = package.loaded["modules.updater.manager"]
		local timer = { HAS_ASYNC = true }
		function timer.after() return { id = "refused", armed = false, fired = true } end
		function timer.cancel(handle)
			handle.armed = false
			return true
		end
		package.loaded["adapters.timer_scheduler"] = timer
		package.loaded["modules.updater.manager"] = nil
		local refused = require("modules.updater.manager")
		refused.current_version = function() return "1.0.0" end
		local started = refused.start_background_checks()

		package.loaded["adapters.timer_scheduler"] = previous_timer
		package.loaded["modules.updater.manager"] = previous_manager
		helpers.assert_eq(started, false, "a refused timer must not read as a running schedule")
	end)

	helpers.it("init loads persisted settings and initialises", function()
		local path = os.tmpname()
		pcall(os.remove, path)
		local expected = M.installed_channel()
		M.init({ config_path = path })
		helpers.assert_eq(M.get_channel(), expected,
			"init with no opts must not silently move the user off their release channel")
		-- Channel should still be the same.
		local ch = M.get_channel()
		helpers.assert_true(M.CHANNELS.channel(ch) ~= nil, "channel should be a registry channel after init")
	end)

	helpers.it("check_for_updates dispatches and publishes asynchronously", function()
		local real_fetch = M._fetch_releases
		local pending = nil
		M._fetch_releases = function(_, callback)
			pending = callback
			return true
		end
		M.clear_cached_release()
		local completions = 0
		local completion_error = nil
		local dispatched = M.check_for_updates("main", function(_, _, err)
			completions = completions + 1
			completion_error = err
		end)
		helpers.assert_eq(dispatched, true)
		helpers.assert_eq(completions, 0,
			"dispatch must return before the network completion")
		helpers.assert_eq(type(pending), "function")
		pending(nil, 0, "offline")
		M._fetch_releases = real_fetch
		helpers.assert_eq(completions, 1)
		helpers.assert_eq(completion_error, "offline")
		helpers.assert_eq(M.get_state(), "idle")
	end)

	for _, mode in ipairs({ "transport", "conditional-transport", "conditional-false", "conditional-number", "conditional-table", "http-error", "invalid-json", "wrong-root", "oversized-page", "entries-mismatch", "dispatch-refusal", "cancel" }) do
		helpers.it("linux-updater-etag: " .. mode .. " forces a fresh page after an unknown native validator", function()
			local previous_fs, previous_manager = package.loaded["adapters.file_system"], package.loaded["modules.updater.manager"]
			local real_fs = require("adapters.file_system")
			package.loaded["adapters.file_system"] = setmetatable({ exists = function() return true end }, { __index = real_fs })
			package.loaded["modules.updater.manager"] = nil
			local loaded, fresh = pcall(require, "modules.updater.manager")
			package.loaded["adapters.file_system"], package.loaded["modules.updater.manager"] = previous_fs, previous_manager
			helpers.assert_true(loaded and type(fresh) == "table", tostring(fresh))
			local old = '[{"tag_name":"v1.0.0"}]'
			local new = '[{"tag_name":"v2.0.0"}]'
			local too_many = {}
			for _ = 1, 21 do too_many[#too_many + 1] = '{"tag_name":"v2.0.0"}' end
			local failure = {
				transport = { ok = false, status = 200, body = "", error = "truncated native transfer" },
				["conditional-transport"] = { ok = false, status = 304, body = "", error = "HTTP 304" },
				["conditional-false"] = { ok = false, status = 304, body = "", error = "HTTP 304", error_body = false },
				["conditional-number"] = { ok = false, status = 304, body = "", error = "HTTP 304", error_body = 0 },
				["conditional-table"] = { ok = false, status = 304, body = "", error = "HTTP 304", error_body = {} },
				["http-error"] = { ok = false, status = 503, body = "", error = "HTTP 503" },
				["invalid-json"] = { ok = true, status = 200, body = "{malformed" },
				["wrong-root"] = { ok = true, status = 200, body = '{"tag_name":"v2.0.0"}' },
				["oversized-page"] = { ok = true, status = 200, body = "[" .. table.concat(too_many, ",") .. "]" },
				["entries-mismatch"] = { ok = true, status = 200, body = '["not a release object"]' },
			}
			local requests, completions = {}, {}
			fresh._http_client = {
				get = function(_, _, options, callback)
					requests[#requests + 1] = options
					if #requests == 1 then callback(etag_response({ ok = true, status = 200, body = old },
						"https://etag-fixture.invalid/releases/page-1", '"OLD"', false))
					elseif #requests == 2 then
						if mode == "dispatch-refusal" then return false end
						if mode == "cancel" then return true end
						callback(failure[mode])
					else callback(etag_response({ ok = true, status = 200, body = new },
						"https://etag-fixture.invalid/releases/page-1", '"NEW"', false)) end
					return true
				end,
				cancel = function() return true end,
			}
			fresh._http_client = require("tests.support.release_http_fixture").attach(fresh._http_client)
			fresh._file_digest = { cancel = function() return true end }
			for index = 1, 3 do
				local count = 0
				fresh._fetch_releases("main", function(body, status, err, reason)
					completions[index] = { body = body, status = status, error = err, reason = reason }; count = count + 1
				end)
				if mode == "cancel" and index == 2 then helpers.assert_true(fresh.cancel_update()) end
				helpers.assert_eq(count, 1)
			end
			helpers.assert_nil(requests[1].etag_compare)
			helpers.assert_eq(requests[1].etag_affinity, true, "cold pages explicitly request final-endpoint evidence")
			helpers.assert_true(requests[2].etag_compare ~= nil, "accepted page retains its conditional association")
			helpers.assert_nil(requests[3].etag_compare, "failed page cannot associate a changed validator with its old body")
			helpers.assert_eq(completions[1].body, old)
			helpers.assert_nil(completions[2].body)
			helpers.assert_true(type(completions[2].error) == "string")
			if mode:match("^conditional%-") then
				helpers.assert_eq(completions[2].status, 304)
				helpers.assert_eq(completions[2].reason, "no_connection")
			end
			helpers.assert_eq(completions[3].body, new)
			helpers.assert_eq(completions[3].status, 200)
		end)
	end
end)

