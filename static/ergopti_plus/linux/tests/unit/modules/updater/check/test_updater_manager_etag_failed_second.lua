--- tests/unit/modules/updater/check/test_updater_manager_etag_failed_second.lua

package.loaded["tests.support.modules.updater.check.updater_manager_fixture"] = nil
local Fixture = require("tests.support.modules.updater.check.updater_manager_fixture")
local helpers, Installer, Fs, etag_response, shell_quote, command_ok, write_file, read_file =
	Fixture.helpers, Fixture.Installer, Fixture.Fs, Fixture.etag_response, Fixture.shell_quote, Fixture.command_ok, Fixture.write_file, Fixture.read_file




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

	helpers.it("linux-updater-etag: a failed second page keeps the accepted first-page association", function()
		local previous_fs, previous_manager = package.loaded["adapters.file_system"], package.loaded["modules.updater.manager"]
		local real_fs = require("adapters.file_system")
		package.loaded["adapters.file_system"] = setmetatable({ exists = function() return true end }, { __index = real_fs })
		package.loaded["modules.updater.manager"] = nil
		local loaded, fresh = pcall(require, "modules.updater.manager")
		package.loaded["adapters.file_system"], package.loaded["modules.updater.manager"] = previous_fs, previous_manager
		helpers.assert_true(loaded and type(fresh) == "table", tostring(fresh))
		local entries = {}
		for index = 1, 20 do entries[index] = '{"tag_name":"v1.0.' .. index .. '"}' end
		local first_page = "[" .. table.concat(entries, ",") .. "]"
		local final_page = '[{"tag_name":"v2.0.0"}]'
		local responses = {
			{ ok = true, status = 200, body = first_page }, { ok = true, status = 200, body = '[{"tag_name":"v1.0.21"}]' },
			{ ok = false, status = 304, body = "", error = "HTTP 304", error_body = "" }, { ok = false, status = 200, body = "", error = "truncated page" },
			{ ok = false, status = 304, body = "", error = "HTTP 304", error_body = "" }, { ok = true, status = 200, body = final_page },
		}
		local page_one, page_two = "https://etag-fixture.invalid/releases/page-1", "https://etag-fixture.invalid/releases/page-2"
		etag_response(responses[1], page_one, '"PAGE-ONE"', false)
		etag_response(responses[2], page_two, '"PAGE-TWO"', false)
		etag_response(responses[3], page_one, '"PAGE-ONE"', true)
		etag_response(responses[5], page_one, '"PAGE-ONE"', true)
		etag_response(responses[6], page_two, '"PAGE-TWO-NEW"', false)
		local requests, results = {}, {}
		fresh._http_client = { get = function(_, _, options, callback)
			requests[#requests + 1] = options; callback(assert(table.remove(responses, 1))); return true
		end }
		fresh._http_client = require("tests.support.release_http_fixture").attach(fresh._http_client)
		for index = 1, 3 do
			local callbacks = 0
			helpers.assert_true(fresh._fetch_releases("main", function(body, status, err)
				results[index] = { body = body, status = status, error = err }; callbacks = callbacks + 1
			end))
			helpers.assert_eq(callbacks, 1)
		end
		helpers.assert_eq(#requests, 6)
		helpers.assert_nil(results[2].body)
		helpers.assert_true(type(results[2].error) == "string")
		helpers.assert_true(requests[5].etag_compare ~= nil, "an accepted earlier page keeps its own validator")
		helpers.assert_nil(requests[6].etag_compare, "the failed page alone must refetch fully")
		helpers.assert_true(results[3].body:find("v1.0.20", 1, true) ~= nil and results[3].body:find("v2.0.0", 1, true) ~= nil)
		helpers.assert_eq(results[3].status, 200)
	end)

	-- GitHub answers 304 Not Modified, with no body, when the list is unchanged
	-- since the ETag curl saved. check_for_updates cleared the cached release
	-- before fetching and a 304 then read as "nothing available": an update
	-- vanished at the next check, and a manual check said there was none.
	helpers.it("a 304 keeps the release the previous 200 found available", function()
		local real_fs = require("adapters.file_system")
		local previous_fs = package.loaded["adapters.file_system"]
		local previous_manager = package.loaded["modules.updater.manager"]
		-- The ETag cache directory exists, so the request is conditional as soon
		-- as the list it names is held.
		package.loaded["adapters.file_system"] = setmetatable({
			exists = function() return true end,
		}, { __index = real_fs })
		package.loaded["modules.updater.manager"] = nil
		local fresh = require("modules.updater.manager")
		package.loaded["adapters.file_system"] = previous_fs
		package.loaded["modules.updater.manager"] = previous_manager

		local list = "[" .. release("v0.0.0-dev.140", true) .. "," .. release("v1.2.0", false) .. "]"
		local responses = {
			{ ok = true, status = 200, body = list },
			{ ok = false, status = 304, body = "", error = "HTTP 304", error_body = "" },
		}
		etag_response(responses[1], "https://etag-fixture.invalid/releases/page-1", '"AVAILABLE"', false)
		etag_response(responses[2], "https://etag-fixture.invalid/releases/page-1", '"AVAILABLE"', true)
		local requests = {}
		fresh._http_client = {
			get = function(_, _, options, callback)
				requests[#requests + 1] = options
				callback(table.remove(responses, 1))
				return true
			end,
			cancel = function() return true end,
		}
		fresh._http_client = require("tests.support.release_http_fixture").attach(fresh._http_client)
		fresh.current_version = function() return "local" end

		local results = {}
		for _ = 1, 2 do
			fresh.check_for_updates("main", function(available, release, err)
				results[#results + 1] = { available = available, tag = release and release.tag, err = err }
			end)
		end

		helpers.assert_eq(#requests, 2, "two checks, two requests")
		helpers.assert_nil(requests[1].etag_compare,
			"without the list an ETag names, the first request must be unconditional")
		helpers.assert_true(requests[1].etag_save ~= nil, "the first answer's ETag is saved")
		helpers.assert_true(requests[2].etag_compare ~= nil, "the second request is conditional")
		helpers.assert_eq(results[1].available, true, "the 200 finds the release")
		helpers.assert_eq(results[2].available, true, "the 304 keeps it available")
		helpers.assert_eq(results[2].tag, results[1].tag, "the same release stays cached")
		helpers.assert_eq(fresh.get_state(), "available")
		helpers.assert_eq(fresh.get_cached_release().tag, "v1.2.0")
	end)

	helpers.it("builds a bounded HTTPS release request for the updater owner", function()
		helpers.assert_true(type(M._build_fetch_request) == "function")
		local url, headers, options = M._build_fetch_request("main")
		helpers.assert_contains(url, "https://api.github.com/")
		helpers.assert_eq(headers.Accept, "application/vnd.github+json")
		helpers.assert_eq(options.owner, "updater")
		helpers.assert_eq(options.https_only, true)
		helpers.assert_eq(options.follow_redirects, true)
		helpers.assert_true(options.timeout_ms > 0)
		helpers.assert_true(options.max_body_bytes >= 1024)
	end)

	-- ========================================
	-- ======= 1b/ install_update transaction =
	-- ========================================

	helpers.it("accepts only a checksum record bound to the canonical filename", function()
		local expected = string.rep("ab", 32)
		local parsed = M._parse_checksum(expected .. "  " .. M.LINUX_ASSET_NAME .. "\n")
		helpers.assert_eq(parsed, expected)
		local wrong, wrong_error = M._parse_checksum(expected .. "  unrelated.tar.gz\n")
		helpers.assert_nil(wrong)
		helpers.assert_contains(wrong_error, "canonical Linux bundle")
		local extra = M._parse_checksum(expected .. "  " .. M.LINUX_ASSET_NAME
			.. "\n" .. expected .. "  second.tar.gz\n")
		helpers.assert_nil(extra, "a multi-record manifest must not be partially trusted")
	end)

	helpers.it("refuses to install a local archive that bypassed verification", function()
		local archive = os.tmpname()
		write_file(archive, "unverified fixture")
		M._test_set_cached_release({ tag = "v4.0.0", prerelease = false })
		local installed = M.install_update(archive)
		local content = read_file(archive)
		Fs.delete(archive)
		M.clear_cached_release()
		helpers.assert_eq(installed, false)
		helpers.assert_eq(content, "unverified fixture",
			"refusal must happen before the installer can mutate the archive")
	end)

	for _, suffix in ipairs({ ".tar.gz", ".tar.gz.part" }) do
		for _, alias in ipairs({ "regular", "dangling" }) do
			helpers.it("linux-updater-temp-ownership: preserves unrelated " .. alias .. " " .. suffix, function()
				with_native_download_model(function(prepare_owned_http)
				M.cancel_update()
				local base = os.tmpname()
				local candidate, target = base .. suffix, base .. ".missing"
				local history = "Retained unrelated temporary bytes"
				if alias == "regular" then write_file(candidate, history)
				else helpers.assert_true(command_ok("ln -s -- " .. shell_quote(target) .. " " .. shell_quote(candidate))) end
				local real_tmpname, real_http = os.tmpname, M._http_client
				local callbacks, completion_error = 0, nil
				os.tmpname = function() return base end
				M._http_client = {
					get = function(_, _, _, callback)
						callback({ ok = false, status = 503, error = "synthetic checksum failure" })
						return true
					end,
					download = function() error("failed checksum must not download an archive") end,
					cancel = function() return true end,
				}
				prepare_owned_http()
				local ok, err = xpcall(function()
					helpers.assert_true(M.download_release({ tag = "v4.0.0", download_url = "https://example.invalid/archive",
						checksum_url = "https://example.invalid/checksum" }, function(path, failure)
						callbacks = callbacks + 1; completion_error = failure; helpers.assert_nil(path)
					end))
					helpers.assert_eq(callbacks, 1)
					helpers.assert_eq(completion_error, "synthetic checksum failure")
					if alias == "regular" then helpers.assert_eq(read_file(candidate), history)
					else
						helpers.assert_true(command_ok("test -L " .. shell_quote(candidate)))
						helpers.assert_nil(io.open(target, "r"))
					end
					helpers.assert_eq(M.get_state(), "idle")
					helpers.assert_eq(Fs.exists(base), false)
				end, debug.traceback)
				os.tmpname, M._http_client = real_tmpname, real_http
				M.cancel_update()
				os.remove(base); os.remove(candidate); os.remove(target)
				helpers.assert_true(ok, tostring(err))
				end)
			end)
		end
	end

	for _, api in ipairs({ "update", "release" }) do
		for _, wants_callback in ipairs({ true, false }) do
			helpers.it("linux-updater-temp-allocation: " .. api .. " acknowledges allocator refusal with callback " .. tostring(wants_callback), function()
				with_native_download_model(function(prepare_owned_http)
				M.cancel_update()
				local release = { tag = "v4.0.0", download_url = "https://example.invalid/archive",
					checksum_url = "https://example.invalid/checksum" }
				M._test_set_cached_release(release)
				local real_tmpname, real_http = os.tmpname, M._http_client
				os.tmpname = function() error("synthetic native allocator refusal") end
				M._http_client = { get = function() error("allocation refusal must precede HTTP") end, cancel = function() return true end }
				local callbacks, received_error = 0, nil
				local callback
				if wants_callback then callback = function(path, err) callbacks = callbacks + 1; received_error = err; helpers.assert_nil(path) end end
				prepare_owned_http()
				local ok, err = xpcall(function()
					local dispatched
					if api == "update" then dispatched = M.download_update(nil, callback)
					else dispatched = M.download_release(release, callback) end
					helpers.assert_eq(dispatched, false)
					helpers.assert_eq(callbacks, wants_callback and 1 or 0)
					if wants_callback then helpers.assert_eq(received_error, "temporary path unavailable") end
					helpers.assert_eq(M.get_state(), "available")
					helpers.assert_eq(M.get_cached_release().tag, release.tag)
				end, debug.traceback)
				os.tmpname, M._http_client = real_tmpname, real_http
				M.cancel_update()
				helpers.assert_true(ok, tostring(err))
				end)
			end)
		end
	end

	helpers.it("linux-digest-owner: downloads and hashes a verified archive under the updater owner", function()
		with_native_download_model(function(prepare_owned_http)
		local real_http = M._http_client
		local real_digest = M._file_digest
		local expected = string.rep("cd", 32)
		local downloaded_part = nil
		local http = {}
		function http.get(_, _, _, callback)
			callback({
				ok = true,
				status = 200,
				body = expected .. "  " .. M.LINUX_ASSET_NAME .. "\n",
			})
			return true
		end
		function http.download(_, _, destination, _, callback)
			downloaded_part = destination
			write_file(destination, "verified fixture archive")
			callback({ ok = true, status = 200, body = "" })
			return true
		end
		function http.cancel() return true end
		local digest = {
			sha256 = function(path, options, callback)
				helpers.assert_eq(path, downloaded_part)
				helpers.assert_eq(options.owner, "updater", "the archive digest must have the same owner as cancellation")
				callback(expected, nil)
				return true
			end,
			cancel = function() return true end,
		}
		M._http_client = http
		M._file_digest = digest
		M._test_set_cached_release({
			tag = "v4.0.0",
			prerelease = false,
			download_url = "https://example.invalid/" .. M.LINUX_ASSET_NAME,
			checksum_url = "https://example.invalid/" .. M.LINUX_CHECKSUM_ASSET_NAME,
		})
		local verified_path = nil
		local completion_error = nil
		prepare_owned_http()
		local ok, dispatched = pcall(M.download_update, nil, function(path, err)
			verified_path = path
			completion_error = err
		end)
		M._http_client = real_http
		M._file_digest = real_digest

		helpers.assert_true(ok, "verified download raised: " .. tostring(dispatched))
		helpers.assert_eq(dispatched, true)
		helpers.assert_eq(completion_error, nil)
		helpers.assert_true(type(verified_path) == "string" and Fs.exists(verified_path))
		helpers.assert_true(not Fs.exists(downloaded_part),
			"the owned partial path must be renamed after verification")
		helpers.assert_eq(M.get_state(), "available")
		Fs.delete(verified_path)
		M.clear_cached_release()
		end)
	end)

	helpers.it("removes a downloaded archive when SHA-256 does not match", function()
		with_native_download_model(function(prepare_owned_http)
		local real_http = M._http_client
		local real_digest = M._file_digest
		local expected = string.rep("ef", 32)
		local downloaded_part = nil
		local http = {}
		function http.get(_, _, _, callback)
			callback({ ok = true, status = 200,
				body = expected .. "  " .. M.LINUX_ASSET_NAME .. "\n" })
			return true
		end
		function http.download(_, _, destination, _, callback)
			downloaded_part = destination
			write_file(destination, "tampered fixture archive")
			callback({ ok = true, status = 200, body = "" })
			return true
		end
		function http.cancel() return true end
		local digest = {
			sha256 = function(_, _, callback)
				callback(string.rep("00", 32), nil)
				return true
			end,
			cancel = function() return true end,
		}
		M._http_client = http
		M._file_digest = digest
		M._test_set_cached_release({
			tag = "v4.0.0",
			prerelease = false,
			download_url = "https://example.invalid/" .. M.LINUX_ASSET_NAME,
			checksum_url = "https://example.invalid/" .. M.LINUX_CHECKSUM_ASSET_NAME,
		})
		local verified_path = nil
		local completion_error = nil
		prepare_owned_http()
		local ok, dispatched = pcall(M.download_update, nil, function(path, err)
			verified_path = path
			completion_error = err
		end)
		M._http_client = real_http
		M._file_digest = real_digest

		helpers.assert_true(ok, "checksum rejection raised: " .. tostring(dispatched))
		helpers.assert_eq(dispatched, true)
		helpers.assert_nil(verified_path)
		helpers.assert_contains(completion_error, "checksum mismatch")
		helpers.assert_true(not Fs.exists(downloaded_part),
			"a mismatched partial archive must be removed")
		helpers.assert_true(not Fs.exists(downloaded_part .. ".tar.gz"),
			"a mismatched archive must never be published")
		helpers.assert_eq(M.get_state(), "idle")
		M.clear_cached_release()
		end)
	end)

	helpers.it("cancel-update: a verified archive does not survive cancellation", function()
		-- Regression: cancel_update() cleared partial downloads but left a
		-- verified archive on disk with state "available", so install_update()
		-- still succeeded after the user — or the shutdown coordinator —
		-- requested cancellation.
		local real_http = M._http_client
		local real_digest = M._file_digest
		M._http_client = { cancel = function() return true end }
		M._file_digest = { cancel = function() return true end }
		local archive = os.tmpname()
		write_file(archive, "verified fixture archive")
		local ok, err = pcall(function()
			M._test_set_verified_archive(archive)
			helpers.assert_eq(M.get_state(), "available",
				"precondition: the archive is verified and installable")
			helpers.assert_true(M.cancel_update(), "cancel must succeed")
			helpers.assert_eq(M.get_state(), "idle",
				"cancel must leave no available update behind")
			helpers.assert_true(not Fs.exists(archive),
				"the verified archive must be deleted with the cancellation")
			helpers.assert_eq(M.install_update(archive), false,
				"a cancelled archive must no longer install")
		end)
		M._http_client = real_http
		M._file_digest = real_digest
		Fs.delete(archive)
		M.clear_cached_release()
		if not ok then error(err, 0) end
	end)

	helpers.it("normalises LuaJIT numeric process failures", function()
		helpers.assert_eq(Installer._status_ok(0), true)
		helpers.assert_eq(Installer._status_ok(256), false,
			"a numeric non-zero shell status is truthy in Lua but must remain failure")
		helpers.assert_eq(Installer._status_ok(true, "exit", 0), true)
		helpers.assert_eq(Installer._status_ok(nil, "exit", 1), false)
	end)
end)

