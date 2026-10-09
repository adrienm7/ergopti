--- ui/menu/llm_scope.lua

--- Applies the complete LLM preference scope through its native terminal owner.
local M = {}
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.preferences")
local Transaction = require("config_scope_transaction")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

--- Creates the AI preference transaction without touching credentials or models.
--- @param options table Common transaction options, runtime and profile registry.
--- @return table owner Scoped publication and retained compensation.
function M.new(options)
	local ports = {}
	for key, value in pairs(options) do ports[key] = value end
	ports.scope, ports.demotion_feature = "llm", "ai"
	ports.demotion_keys = function(rows)
		local keys = {}
		for _, row in ipairs(rows) do
			local key = Preferences.flat_key_for(row.section .. "." .. row.key)
			if key then keys[key] = true end
		end
		return keys
	end
	ports.transaction_factory = function(transaction_options)
		local source
		transaction_options.owned_paths = function()
			local content, status = Writer.read_classified(options.path, options.files)
			assert(status == "ok" or status == "absent", "LLM preference source is unavailable")
			source = { content = content, status = status }
			local decoded = Codec.decode(content or "")
			local llm = decoded.llm or {}
			local profiles = llm.profiles or {}
			assert(type(profiles) == "table", "LLM profile preferences are malformed")
			local ids, paths = {}, {}
			local registered = options.profiles()
			assert(type(registered) == "table", "LLM profile ownership is unavailable")
			for _, list in ipairs({ registered, profiles.user_profiles or {}, options.state.llm_user_profiles or {} }) do
				assert(type(list) == "table", "LLM profile ownership is unavailable")
				for _, profile in ipairs(list) do
					assert(type(profile) == "table" and type(profile.id) == "string"
						and profile.id ~= "" and not profile.id:find(".", 1, true), "invalid LLM profile identity")
					ids[profile.id] = true
				end
			end
			for _, shortcuts in ipairs({ profiles.shortcuts or {}, options.state.llm_profile_shortcuts or {} }) do
				assert(type(shortcuts) == "table", "LLM profile shortcut inventory is malformed")
				for id, shortcut in pairs(shortcuts) do
					if ids[id] then
						assert(type(shortcut) == "table", "owned LLM profile shortcut is malformed")
						for _, key in ipairs({ "mods", "key" }) do
							paths[#paths + 1] = "llm.profiles.shortcuts." .. id .. "." .. key
						end
					end
				end
			end
			return Manifest.scope_inventory("llm", { profiles = function() return paths end })
		end
		transaction_options.prepare_batch = function(path, rows, files)
			return Writer.prepare_batch(path, Preferences.prepare_llm_updates(source, rows), files, source)
		end
		return Transaction.new(transaction_options)
	end
	return require("ui.menu.scoped_preferences").new(ports)
end

return M
