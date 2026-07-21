--- tests/unit/modules/llm/test_retry_policy_shared_across_backends.lua

--- ==============================================================================
--- MODULE: Regression — every backend must retry on the shared policy
--- DESCRIPTION:
--- A failed MLX prediction retried with an effectively identical request, so the
--- retry failed the same way and the user simply waited twice as long for
--- nothing.
---
--- ROOT CAUSE ENCODED:
--- ApiCommon.get_retry_policy() returns three values — max multiplier, temperature
--- step, extra tokens — sourced from the shared inference manifest so the AHK and
--- macOS drivers stay in lock-step. api_ollama and api_remote destructure all
--- three. api_mlx_fetch bound only the first and then hardcoded its own `+ 5`
--- tokens and `+ 0.10` temperature, under a `math.min(0.60, …)` ceiling its
--- siblings set at 1.30.
---
--- The ceiling is what made it a defect rather than a style difference: a profile
--- configured at or above 0.60 — which the temperature menu allows — clamped to
--- its own starting temperature, so the retry re-sent the same prompt at the same
--- temperature to the same model. Retrying an identical request is not a retry.
---
--- WHY IT WAS SILENT:
--- Nothing errors. The retry is dispatched, logged, and returns the same failure,
--- which reads as "the model could not answer" rather than "we never actually
--- varied the request". Tuning the shared manifest also silently did nothing on
--- MLX, so the two drivers drifted apart with no signal.
---
--- This is a CLASS guard: it walks EVERY retry site in the driver rather than
--- pinning the one that was wrong, so a fourth backend cannot reintroduce the
--- drift. read_driver_source concatenates every file containing the anchor, so
--- one read covers all of them.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Retry temperature ceiling shared by every backend. Above this a local model's
-- output stops being a prediction and becomes noise.
local RETRY_TEMP_CEILING = "1.30"

-- Backends that dispatch a prediction and retry it on failure. Used only to
-- assert the scan is not vacuous — the assertions themselves are site-driven.
local EXPECTED_RETRY_SITES = 3





-- ============================================
-- ============================================
-- ======= 1/ One Policy, Every Backend =======
-- ============================================
-- ============================================

--- Returns every `local retry_temp = …` line across the driver.
--- @return table Array of statement strings.
local function retry_temp_sites()
	-- Selected by a declaration rather than by path, so moving or splitting a
	-- backend module cannot turn this invariant into a path error. Every file
	-- containing the anchor is concatenated into one blob.
	local src = helpers.read_driver_source("local retry_temp")
	helpers.assert_true(src ~= nil, "no driver source computes a retry temperature")
	if not src then return {} end

	local sites = {}
	for line in src:gmatch("local retry_temp[^\n]*") do
		sites[#sites + 1] = line
	end
	return sites
end

helpers.describe("every LLM backend retries on the shared policy", function()
	helpers.it("finds a retry site in each backend", function()
		local sites = retry_temp_sites()
		helpers.assert_true(#sites >= EXPECTED_RETRY_SITES, string.format(
			"expected at least %d retry sites (MLX, Ollama, remote), found %d — a scan that "
			.. "finds nothing would make every assertion below vacuous",
			EXPECTED_RETRY_SITES, #sites))
	end)

	helpers.it("derives the retry temperature from the policy step, not a literal", function()
		local offenders = {}
		for _, line in ipairs(retry_temp_sites()) do
			if not line:find("TEMP_STEP", 1, true) then
				offenders[#offenders + 1] = line:gsub("%s+", " ")
			end
		end

		helpers.assert_true(#offenders == 0, string.format(
			"%d retry site(s) add a hardcoded temperature increment instead of the shared "
			.. "policy step: %s. A literal cannot be tuned from the inference manifest, so that "
			.. "backend silently stops tracking the manifest the AHK driver reads from",
			#offenders, table.concat(offenders, " | ")))
	end)

	helpers.it("uses the same retry temperature ceiling everywhere", function()
		local wrong = {}
		for _, line in ipairs(retry_temp_sites()) do
			local ceiling = line:match("math%.min%(%s*([%d%.]+)")
			if ceiling ~= RETRY_TEMP_CEILING then
				wrong[#wrong + 1] = (line:gsub("%s+", " "))
			end
		end

		helpers.assert_true(#wrong == 0, string.format(
			"every retry must clamp at %s; %d site(s) differ: %s. A LOWER ceiling is not the "
			.. "safer choice — it silently disables the retry for any profile already configured "
			.. "at or above it, so the retry re-sends the same prompt at the same temperature "
			.. "and fails identically. That is exactly what the MLX backend did at 0.60",
			RETRY_TEMP_CEILING, #wrong, table.concat(wrong, " | ")))
	end)

	helpers.it("derives the retry token budget from the policy too", function()
		local src = helpers.read_driver_source("local retry_tokens")
		helpers.assert_true(src ~= nil, "no driver source computes a retry token budget")
		if not src then return end

		local offenders = {}
		for line in src:gmatch("local retry_tokens[^\n]*") do
			if not line:find("EXTRA_TOKENS", 1, true) then
				offenders[#offenders + 1] = (line:gsub("%s+", " "))
			end
		end

		helpers.assert_true(#offenders == 0, string.format(
			"%d retry site(s) hardcode their extra-token budget: %s. It belongs to the same "
			.. "shared policy as the temperature step — splitting them is how one backend ends "
			.. "up retrying differently from its siblings without anyone noticing",
			#offenders, table.concat(offenders, " | ")))
	end)
end)
