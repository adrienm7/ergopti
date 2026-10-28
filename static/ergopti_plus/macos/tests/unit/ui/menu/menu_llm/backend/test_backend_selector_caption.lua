--- tests/unit/ui/menu/menu_llm/backend/test_backend_selector_caption.lua

--- ==============================================================================
--- MODULE: The Model Button Reads The Backend Emoji First
--- DESCRIPTION:
--- Regression model-button-emoji-first. The maintainer replaced the model list
--- with one tray button on 2026-10-27: the backend's emoji, then the model it
--- runs — « 🦙 qwen3:4b », « 🚀 Qwen3-4B », « 🌐 OpenAI/gpt-4o-mini ». The emoji
--- comes from _shared/modules/llm/backends.json, which Windows, Linux and the
--- selector page read too; these cases read that real file.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Decodes the shared brand file independently of the module under test.
local function shared_brands()
	local JsonCodec = require("adapters.json_codec")
	local fh = assert(io.open(helpers.shared("modules/llm/backends.json"), "r"))
	local decoded = JsonCodec.decode(fh:read("*a"))
	fh:close()
	return decoded.backends
end

helpers.describe("the model button reads the backend emoji first", function()
	local shared = shared_brands()

	helpers.it("composes each backend form with the shared emoji", function()
		helpers.with_fresh_modules({ "ui.menu.menu_llm.backend_labels" }, function()
			local Labels = require("ui.menu.menu_llm.backend_labels")
			helpers.assert_eq(Labels.selector_caption("ollama", "qwen3:4b"), shared.ollama.emoji .. " qwen3:4b")
			helpers.assert_eq(Labels.selector_caption("mlx", "Qwen3-4B"), shared.mlx.emoji .. " Qwen3-4B")
			helpers.assert_eq(Labels.selector_caption("api", "OpenAI/gpt-4o-mini"),
				shared.api.emoji .. " OpenAI/gpt-4o-mini")
		end)
	end)

	helpers.it("keeps the Backend option brand from the same file", function()
		helpers.with_fresh_modules({ "ui.menu.menu_llm.backend_labels" }, function()
			local Labels = require("ui.menu.menu_llm.backend_labels")
			for _, id in ipairs({ "ollama", "mlx", "api" }) do
				helpers.assert_eq(Labels.brand(id), shared[id].brand .. " " .. shared[id].emoji)
				helpers.assert_eq(Labels.emoji(id), shared[id].emoji)
			end
		end)
	end)

	helpers.it("refuses an unknown backend and an empty model text", function()
		helpers.with_fresh_modules({ "ui.menu.menu_llm.backend_labels" }, function()
			local Labels = require("ui.menu.menu_llm.backend_labels")
			helpers.assert_eq(pcall(Labels.selector_caption, "kanata", "x"), false)
			helpers.assert_eq(pcall(Labels.selector_caption, "ollama", ""), false)
		end)
	end)
end)
