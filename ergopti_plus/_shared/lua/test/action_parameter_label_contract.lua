--- _shared/lua/test/action_parameter_label_contract.lua

--- Replays literal binding labels across all shipped action translations.
return function(helpers, json, shared_root)
	local Labels = require("action_parameter_label")
	local function read_json(relative)
		local file = assert(io.open(shared_root .. "/" .. relative, "rb"))
		local text = file:read("*a")
		file:close()
		return json.decode(text)
	end
	helpers.describe("configured action labels", function()
		helpers.it("replaces the marker in all parameterized actions and locales (action-parameter-label)", function()
			local locales = read_json("data/locale_order.json").order
			helpers.assert_eq(#locales, 21)
			for _, locale in ipairs(locales) do
				local strings = read_json("data/locales/" .. locale .. ".json")
				for _, id in ipairs({ "open_url", "search_web", "wrap_selection", "send_text", "send_key", "send_shortcut" }) do
					local label = strings["sg_actions." .. id]
					local prefix = assert(label:match("^(.-)%[[^%[%]]*%]$"), locale .. ": " .. id)
					helpers.assert_eq(Labels.format(label, ""), label)
					for _, value in ipairs({ "https://apple.com", "https://example.org/?q=%s", "[x] 50% & café" }) do
						helpers.assert_eq(Labels.format(label, value), prefix .. "[" .. value .. "]", locale .. ": " .. id)
					end
				end
			end
		end)
	end)
end
