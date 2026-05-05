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
	package.loaded["lib.logger"] = nil
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
