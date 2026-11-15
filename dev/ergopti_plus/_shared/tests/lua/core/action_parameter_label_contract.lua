--- _shared/tests/lua/core/action_parameter_label_contract.lua

--- Replays literal binding labels across all shipped action translations.
return function(helpers, json, shared_root)
	local Labels = require("shortcuts.engine.action_parameter_label")
	local function read_json(relative)
		local file = assert(io.open(shared_root .. "/" .. relative, "rb"))
		local text = file:read("*a")
		file:close()
		return json.decode(text)
	end
	helpers.describe("configured action labels", function()
		helpers.it("replaces the marker in all parameterized actions and locales (action-parameter-label)", function()
			local locales = read_json("core/i18n/data/locale_order.json").order
			helpers.assert_eq(#locales, 21)
			for _, locale in ipairs(locales) do
				local strings = read_json("core/i18n/data/locales/" .. locale .. ".json")
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
		helpers.it("shows a user action's safe summary, never a command (action-parameter-label-user)", function()
			local strings = read_json("core/i18n/data/locales/en.json")
			local command = '{"version":1,"command":"echo s3cr3t","mode":"hidden","output":"none"}'
			local shortcut = '{"version":1,"id":"1B2C3D4E-5F60-4718-9A0B-C1D2E3F40516","name":"Resize Image",'
				.. '"input":"none","output":"none"}'
			local run, open, apple = strings["sg_actions.run_command"], strings["sg_actions.open_path"],
				strings["sg_actions.run_apple_shortcut"]
			helpers.assert_eq(Labels.for_spec(run, "command", command), run)
			local function marked(label, text) return (label:gsub("%[[^%]]*%]$", function() return "[" .. text .. "]" end)) end
			helpers.assert_eq(Labels.for_spec(open, "path", "/home/me/Projets/"), marked(open, "Projets"))
			helpers.assert_eq(Labels.for_spec(open, "path", "/Users/me/Rapport.pdf"),
				marked(open, "Rapport.pdf"))
			helpers.assert_eq(Labels.for_spec(open, "path", "relative"), open)
			helpers.assert_eq(Labels.for_spec(apple, "apple_shortcut", shortcut), marked(apple, "Resize Image"))
			local registry = { get_action_parameter_spec = function() return "command" end,
				get_action_parameter = function() return command end }
			helpers.assert_eq(Labels.for_binding(run, registry, "tap_3", "run_command"), run)
		end)
	end)
end
