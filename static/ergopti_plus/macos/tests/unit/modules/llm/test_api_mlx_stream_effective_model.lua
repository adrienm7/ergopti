--- tests/unit/modules/llm/test_api_mlx_stream_effective_model.lua

--- ==============================================================================
--- MODULE: Regression — MLX streaming effective_model keeps the model_hf_path tier
--- DESCRIPTION:
--- Audit finding F-H4. When api_mlx_inference.lua was split out, the STREAMING
--- effective_model chain was written with only three fallback tiers
--- (read_active_model_arg / server_model_id / model_name) while the non-streaming
--- twin and warmup keep the full four-tier chain including _ctx.model_hf_path().
--- server_model_id() is permanently nil and read_active_model_arg() is nil whenever
--- /tmp/mlx_active_model.txt is absent (tmp reaping / a reload that adopts a running
--- server), so the streaming default path then sent the SHORT model name, which
--- mlx-lm 0.26+ rejects with a 404 → no streamed prediction.
---
--- Single-source-of-truth invariant (rule 5.2), encoded at source because the 404
--- only reproduces against a live server: EVERY effective_model resolution chain in
--- this file must include the _ctx.model_hf_path() tier — streaming and non-streaming
--- must not drift.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("MLX inference effective_model parity (streaming vs non-streaming)", function()
	helpers.it("every effective_model chain includes the model_hf_path() fallback tier", function()
		local path = helpers.driver_root() .. "modules/llm/api_mlx_inference.lua"
		local fh = assert(io.open(path, "r"))
		local src = fh:read("*a"); fh:close()

		local chains = {}
		for line in src:gmatch("[^\n]+") do
			if line:find("effective_model%s*=") and line:find("read_active_model_arg", 1, true) then
				chains[#chains + 1] = line
			end
		end

		-- There are two resolution sites (streaming + non-streaming); both must exist
		-- and both must consult model_hf_path() before collapsing to the short name.
		helpers.assert_true(#chains >= 2,
			"expected at least two effective_model resolution chains (streaming + non-streaming)")
		for _, chain in ipairs(chains) do
			helpers.assert_true(chain:find("model_hf_path", 1, true) ~= nil,
				"an effective_model chain is missing the model_hf_path() tier: " .. chain)
			-- model_hf_path must come BEFORE the bare model_name fallback in the or-chain.
			local hf   = chain:find("model_hf_path", 1, true)
			local name = chain:find("or model_name", 1, true) or chain:find("model_name", 1, true)
			helpers.assert_true(hf ~= nil and name ~= nil and hf < name,
				"model_hf_path() must precede the short model_name fallback")
		end
	end)
end)
