--- ui/personal_info_editor/bridge_toml.lua

--- ==============================================================================
--- BRIDGE HANDLER: Personal Info TOML Editor
--- Handles JS->Lua messages from _shared/ui/personal_info_editor/ (TOML flavour).
--- Bridge name: "personal_toml_editor"
--- ==============================================================================

local M = {}
M.bridge_name = "personal_toml_editor"

local Logger = require("logger.shim")
local Shell = require("adapters.shell_runner")
local LOG = "bridge.personal_toml"

--- Candidate locations for personal_info.toml, most authoritative first.
--- @return table Array of absolute paths.
local function _candidate_paths()
	-- Try to read the actual personal_info.toml file.
	local home = require("infra.config_paths").home()
	local candidates = {
		home .. "/.config/ergopti/hotstrings/personal_info.toml",
	}

	-- Also check from the shared defaults.
	local ok_dh, dh = pcall(require, "modules.dynamic_hotstrings.manager")
	if ok_dh and dh and type(dh.get_config_path) == "function" then
		local path = dh.get_config_path()
		if path then
			table.insert(candidates, 1, path)
		end
	end
	return candidates
end

--- Builds the initial TOML payload showing raw personal_info.toml content.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state)
	local toml_content = ""
	local toml_path = ""

	for _, path in ipairs(_candidate_paths()) do
		local fh = io.open(path, "r")
		if fh then
			toml_content = fh:read("*a") or ""
			fh:close()
			toml_path = path
			break
		end
	end

	return {
		toml_content = toml_content,
		toml_path = toml_path,
		readonly = false,
	}
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Personal TOML editor UI ready.")
			return _build_initial_payload(state)
		end
		if payload == "refresh" then
			return _build_initial_payload(state)
		end
		if payload == "close" then
			Logger.info(LOG, "Personal TOML editor close requested.")
			return nil
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action

	if action == "save" then
		local content = payload.content
		if type(content) ~= "string" or content == "" then
			return { saved = false, error = "Nothing to save." }
		end
		-- Validate BEFORE touching the file: the previous code truncated it
		-- with io.open(path, "w") and then wrote whatever the editor sent, so
		-- one malformed save disabled every @-tag shortcut on the next load.
		-- Only the byte count reaches the log — the content is personal data.
		Logger.info(LOG, "Save TOML content (%d bytes).", #content)
		local ok_codec, TomlCodec = pcall(require, "toml_codec")
		local ok_decode, parsed = false, nil
		if ok_codec and TomlCodec and type(TomlCodec.decode) == "function" then
			ok_decode, parsed = pcall(TomlCodec.decode, content)
		end
		if not ok_decode or type(parsed) ~= "table" then
			Logger.warn(LOG, "Refusing to save malformed TOML — the previous file was kept.")
			return { saved = false, error = "Invalid TOML — the previous file was kept." }
		end
		local data = _build_initial_payload(state)
		local path = data.toml_path ~= "" and data.toml_path or _candidate_paths()[1]
		if type(path) ~= "string" or path == "" then
			return { saved = false, error = "No TOML path configured." }
		end
		-- Stage through a temporary file and rename: a crash mid-write must
		-- leave the previous file behind, not a truncated one.
		local parent = path:match("^(.*)/") or "."
		if not Shell.run("mkdir -p " .. Shell.quote(parent) .. " 2>/dev/null") then
			Logger.error(LOG, "Cannot create the config directory — nothing saved.")
			return { saved = false, error = "Could not write to TOML file." }
		end
		local temporary = path .. ".tmp"
		local open_ok, fh = pcall(io.open, temporary, "w")
		if not open_ok or not fh then
			Logger.error(LOG, "Cannot stage the TOML file — the previous file was kept.")
			return { saved = false, error = "Could not write to TOML file." }
		end
		local write_ok, written = pcall(fh.write, fh, content)
		local close_ok, closed = pcall(fh.close, fh)
		if not write_ok or written == nil or written == false or not close_ok or closed ~= true then
			pcall(os.remove, temporary)
			Logger.error(LOG, "Cannot stage the TOML file — the previous file was kept.")
			return { saved = false, error = "Could not write to TOML file." }
		end
		local rename_ok, renamed = pcall(os.rename, temporary, path)
		if not rename_ok or renamed ~= true then
			-- rename() over an EXISTING file succeeds on POSIX and fails on
			-- Windows, so replacing personal data would always fail exactly
			-- where it matters. Remove the target and retry rather than
			-- trusting the overwrite.
			pcall(os.remove, path)
			rename_ok, renamed = pcall(os.rename, temporary, path)
		end
		if not rename_ok or renamed ~= true then
			pcall(os.remove, temporary)
			Logger.error(LOG, "Cannot publish the TOML file — the previous file was kept.")
			return { saved = false, error = "Could not write to TOML file." }
		end
		return { saved = true, path = path }
	end

	if action == "reload" then
		-- Reload the dynamic hotstrings engine so changes take effect.
		local ok_dh, dh = pcall(require, "modules.dynamic_hotstrings.manager")
		if ok_dh and dh and type(dh.reload) == "function" then
			pcall(dh.reload)
		end
		return _build_initial_payload(state)
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

return M
