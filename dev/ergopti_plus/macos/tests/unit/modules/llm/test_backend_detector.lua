--- tests/unit/modules/llm/test_backend_detector.lua

--- ==============================================================================
--- MODULE: llm.backend_detector Unit Tests
--- DESCRIPTION:
--- Verifies the auto-default rule matrix and the user-preference override
--- precedence by stubbing hs.execute and hs.settings responses.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fresh_detector()
	package.loaded["modules.llm.backend_detector"] = nil
	package.loaded["infra.logger"] = nil
	package.loaded["hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	return hs_stub, require("modules.llm.backend_detector")
end

helpers.describe("backend_detector.auto_default", function()
	helpers.it("returns mlx on arm64 + recent macOS", function()
		local hs_stub, det = fresh_detector()
		hs_stub.__set_exec("uname -m", "arm64\n")
		hs_stub.__set_exec("sw_vers -productVersion", "14.5\n")
		helpers.assert_eq(det.auto_default(), det.BACKEND_MLX)
	end)

	helpers.it("returns ollama on x86_64", function()
		local hs_stub, det = fresh_detector()
		hs_stub.__set_exec("uname -m", "x86_64\n")
		hs_stub.__set_exec("sw_vers -productVersion", "14.5\n")
		helpers.assert_eq(det.auto_default(), det.BACKEND_OLLAMA)
	end)

	helpers.it("returns ollama on too-old macOS", function()
		local hs_stub, det = fresh_detector()
		hs_stub.__set_exec("uname -m", "arm64\n")
		hs_stub.__set_exec("sw_vers -productVersion", "12.0\n")
		helpers.assert_eq(det.auto_default(), det.BACKEND_OLLAMA)
	end)

	-- "backend_detector is pure; the pause gate lives higher" was asserted with
	-- assert_true(true) and that sentence as the message. It is a true and useful
	-- claim, and none of it was being checked — the case passed whatever the
	-- module did. Check the claim.
	helpers.it("the pause gate is not in this module", function()
		local src = helpers.read_driver_source("function M.auto_default")
		helpers.assert_true(src ~= nil, "modules/llm/backend_detector.lua must be locatable")
		helpers.assert_true(src:find("paus") == nil,
			"detection must stay pure — a pause check here means the backend silently "
				.. "changes identity while paused, and the resume picks a different engine")
	end)

	helpers.it("a malformed uname still yields a valid backend, every time", function()
		local hs_stub, det = fresh_detector()
		hs_stub.__set_exec("uname -m", "garbage\n")
		-- The loop used to run and then assert true, which is the same test with
		-- the answers thrown away. What matters is that garbage in does not
		-- produce a THIRD answer, and does not produce a different one each call:
		-- effective_backend() only accepts these three, so a fourth value would be
		-- silently replaced by the auto-default on the next read.
		local first = det.auto_default()
		helpers.assert_true(first == det.BACKEND_MLX or first == det.BACKEND_OLLAMA,
			"auto_default must answer with a known backend even on unparseable input, got: "
				.. tostring(first))
		for _ = 1, 80 do
			helpers.assert_eq(det.auto_default(), first,
				"the same unparseable input must give the same answer — a detector that "
					.. "wobbles makes the engine restart at random")
		end
	end)
end)

helpers.describe("backend_detector.effective_backend", function()
	helpers.it("user preference wins over auto-default", function()
		local hs_stub, det = fresh_detector()
		hs_stub.__set_exec("uname -m", "arm64\n")
		hs_stub.__set_exec("sw_vers -productVersion", "14.5\n")
		hs_stub.settings.set("llm_backend", det.BACKEND_OLLAMA)
		helpers.assert_eq(det.effective_backend(), det.BACKEND_OLLAMA)
	end)

	helpers.it("ignores invalid stored preference", function()
		local hs_stub, det = fresh_detector()
		hs_stub.__set_exec("uname -m", "x86_64\n")
		hs_stub.__set_exec("sw_vers -productVersion", "14.5\n")
		hs_stub.settings.set("llm_backend", "garbage")
		-- Should fall back to auto_default == ollama
		helpers.assert_eq(det.effective_backend(), det.BACKEND_OLLAMA)
	end)
end)

helpers.describe("backend_detector.set_backend", function()
	helpers.it("persists valid backend choice", function()
		local hs_stub, det = fresh_detector()
		det.set_backend(det.BACKEND_MLX)
		helpers.assert_eq(hs_stub.settings.get("llm_backend"), det.BACKEND_MLX)
	end)

	helpers.it("refuses to persist invalid value", function()
		local hs_stub, det = fresh_detector()
		det.set_backend("garbage")
		helpers.assert_nil(hs_stub.settings.get("llm_backend"))
	end)
end)
