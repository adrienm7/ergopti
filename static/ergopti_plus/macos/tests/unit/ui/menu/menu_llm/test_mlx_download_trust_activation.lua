--- tests/unit/ui/menu/menu_llm/test_mlx_download_trust_activation.lua

--- ==============================================================================
--- MODULE: MLX Downloader System Trust Admission
--- DESCRIPTION:
--- Receives the actual downloader and its independent session metadata, and
--- preserves the original process-failure window and model/server verdict.
--- ==============================================================================

local helpers = require("tests.helpers")
local receiver = require("tests.support.mlx_truststore_fixture")
local support = require("tests.support.mlx_download_fixture")

helpers.describe("MLX downloader system trust admission", function()
	helpers.it("admits the managed receiver before emitting the native downloader", function()
		local calls = 0
		local network = {
			managed_http_prelude = function(tag)
				helpers.assert_eq(tag, "MLX")
				calls = calls + 1
				return "# qualified managed MLX receiver", nil
			end,
			opaque_prelude = function() error("Managed MLX must not require opaque PAC admission") end,
		}
		support.with_fixture({network_env = network}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			helpers.assert_eq(calls, 1)
			local launchers = 0
			for path, body in pairs(fixture.controls.files) do
				if path:match("%.sh$") then
					launchers = launchers + 1
					local runtime = assert(body:find("PYTHON_BIN=", 1, true))
					local admission = assert(body:find("# qualified managed MLX receiver", 1, true))
					helpers.assert_true(runtime < admission, "The receiver uses the pinned interpreter")
				end
			end
			helpers.assert_eq(launchers, 1)
		end)
	end)

	helpers.it("refuses missing managed admission without an opaque fallback or child", function()
		local network = {
			managed_http_prelude = function() return nil, "native receiver unavailable" end,
			opaque_prelude = function() error("A managed refusal must not start an opaque client") end,
		}
		support.with_fixture({network_env = network}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			support.assert_cancelled(fixture, "network_policy_missing")
			helpers.assert_eq(#fixture.controls.tasks.launcher, 0)
			helpers.assert_eq(fixture.records.server_starts, 0)
			helpers.assert_eq(fixture.records.successes, 0)
		end)
	end)

	helpers.it("captures the actual emitted source and exact published exit owner", function()
		local packet = receiver.capture()
		helpers.assert_type(packet.source, "string")
		helpers.assert_type(packet.expected_exit_path, "string")
		helpers.assert_eq(packet.expected_exit_path, packet.log_path .. ".exit")
	end)

	helpers.it("keeps failed trust activation on the existing process failure window", function()
		support.with_fixture({}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			support.launch_detached_download(fixture)
			fixture.controls.finish_download(1)
			support.assert_cancelled(fixture, "process_failed")
			helpers.assert_eq(fixture.records.server_starts, 0)
			helpers.assert_eq(fixture.records.successes, 0)
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.completions[1][1], false)
			helpers.assert_nil(fixture.records.completions[1][3], "trust activation is no gated-model receipt")
		end)
	end)
end)
