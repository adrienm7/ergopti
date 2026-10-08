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
