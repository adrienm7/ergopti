--- tests/unit/modules/llm/brands/test_backend_brands.lua

--- ==============================================================================
--- MODULE: Linux AI Backend Brands
--- DESCRIPTION:
--- The tray's model button reads "<emoji> <model>" from the shared
--- _shared/modules/llm/backends.json (maintainer, 2026-10-27): "🦙 qwen3:4b",
--- "🌐 OpenAI/gpt-4o-mini". These cases read the real shared file, so a second
--- copy of an emoji in this driver cannot pass.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The shared file, decoded independently of the module under test.
local function shared_brands()
	local Json = require("json")
	local path = require("infra.paths").shared("modules/llm/backends.json")
	local fh = assert(io.open(path, "r"))
	local root = Json.decode(fh:read("*a"))
	fh:close()
	return root.backends
end

helpers.describe("Linux AI backend brands", function()
	local Brands = helpers.load_module("modules.llm.backend_brands")
	Brands._reset()
	local shared = shared_brands()

	helpers.it("names each backend with the shared brand and emoji", function()
		for _, id in ipairs({ "ollama", "mlx", "api" }) do
			assert(Brands.emoji(id) == shared[id].emoji, id .. " emoji")
			assert(Brands.label(id) == shared[id].brand .. " " .. shared[id].emoji, id .. " label")
			-- model-selector-single-emoji: the page writes the emoji itself.
			assert(Brands.brand(id) == shared[id].brand, id .. " bare brand")
			assert(not Brands.brand(id):find(shared[id].emoji, 1, true), id .. " brand carries no emoji")
		end
	end)

	helpers.it("puts the emoji first on the model button, for every backend form", function()
		assert(Brands.selector_caption("ollama", "qwen3:4b") == shared.ollama.emoji .. " qwen3:4b")
		assert(Brands.selector_caption("mlx", "Qwen3-4B") == shared.mlx.emoji .. " Qwen3-4B")
		assert(Brands.selector_caption("api", "OpenAI/gpt-4o-mini") == shared.api.emoji .. " OpenAI/gpt-4o-mini")
	end)

	helpers.it("names the API button after the provider's display name and model", function()
		local saved = { package.loaded["modules.llm.api_remote"], package.loaded["modules.llm.api_entries"] }
		local active = { id = "e1", provider = "openai", model = "gpt-4o-mini", base_url = "" }
		package.loaded["modules.llm.api_remote"] = {
			provider = function(id)
				return id == "openai" and { label = "OpenAI", default_model = "gpt-4.1-mini" } or nil
			end,
		}
		package.loaded["modules.llm.api_entries"] = {
			active = function() return active end,
			list = function() return { active } end,
		}
		local ok, err = pcall(function()
			local Rows = helpers.load_module("ui.menu.llm_backend_rows")
			local llm = { get_backend = function() return "api" end }
			assert(Rows.caption(llm) == shared.api.emoji .. " OpenAI/gpt-4o-mini", "provider display name, then model")
			active.model = ""
			assert(Rows.caption(llm) == shared.api.emoji .. " OpenAI/gpt-4.1-mini", "the model the requests use")
			local local_llm = { get_backend = function() return "ollama" end,
				get_current_model = function() return "qwen3:4b" end }
			assert(Rows.caption(local_llm) == shared.ollama.emoji .. " qwen3:4b")
		end)
		package.loaded["modules.llm.api_remote"], package.loaded["modules.llm.api_entries"] = saved[1], saved[2]
		package.loaded["ui.menu.llm_backend_rows"] = nil
		assert(ok, err)
	end)

	helpers.it("refuses an unknown backend and an empty model text", function()
		assert(not pcall(Brands.emoji, "kanata"))
		assert(not pcall(Brands.selector_caption, "ollama", ""))
	end)
end)
