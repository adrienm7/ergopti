--- apps/encryptor.lua
-- The application-owned child is invoked directly, without a global Lua init.
local literal_driver = os.getenv("ERGOPTI_LITERAL_DRIVER_ROOT")
if literal_driver and literal_driver ~= "" then
	local literal_shared = assert(os.getenv("ERGOPTI_LITERAL_SHARED_ROOT"), "literal shared root unavailable")
	assert(loadfile(literal_driver .. "/infra/literal_module_loader.lua"))().install(literal_driver, literal_shared, os.getenv("ERGOPTI_RUNTIME_PREFIX"), os.getenv("ERGOPTI_LITERAL_DIRECT") == "1" and "child-direct" or (os.getenv("ERGOPTI_LITERAL_DAEMON") == "1" and "daemon" or nil))
end


--- ==============================================================================
--- MODULE: Encryptor (Linux)
--- DESCRIPTION:
--- The Linux Encryptor program: encrypts or decrypts the files it is given
--- (dropped on its desktop entry, or « Open with ») and asks for one when it is
--- given none (Applications > Encryptor in the tray). The work is
--- apps/encryptor_core.lua; this file reads the command line and wires the
--- real dialogs, strings and openssl into it.
---
--- Usage: encryptor.lua --locales-dir DIR [--locale CODE] [--] [FILE…]
--- ==============================================================================

local M = {}

--- Reads the command line.
--- @param argv table
--- @return table|nil options { locale, locales_dir, files }
--- @return string|nil reason
function M.parse_arguments(argv)
	local options, index = { files = {} }, 1
	while index <= #argv do
		local word = argv[index]
		if word == "--" then
			for rest = index + 1, #argv do options.files[#options.files + 1] = argv[rest] end
			break
		elseif word == "--locale" or word == "--locales-dir" then
			local value = argv[index + 1]
			if type(value) ~= "string" or value == "" then return nil, word .. " needs a value" end
			options[word == "--locale" and "locale" or "locales_dir"] = value
			index = index + 2
		elseif word:sub(1, 2) == "--" then
			return nil, "unknown option " .. word
		else
			options.files[#options.files + 1] = word
			index = index + 1
		end
	end
	if not options.locales_dir then return nil, "--locales-dir is required" end
	return options
end

--- Opens the folder holding a path in the desktop's file manager.
--- @param path string
local function reveal(path)
	local folder = path:match("^(.*)/[^/]*$")
	if not folder or folder == "" then folder = "/" end
	os.execute("setsid xdg-open " .. require("text_utils").shell_quote(folder) .. " >/dev/null 2>&1 &")
end

--- Runs the program.
--- @param argv table
--- @return number status
function M.main(argv)
	local options, reason = M.parse_arguments(argv)
	if not options then
		io.stderr:write("encryptor.lua: ", reason, "\n")
		return 64
	end
	local Core = require("apps.encryptor_core")
	local t = require("apps.app_strings").load(options.locales_dir, options.locale)
	local dialogs = require("apps.dialogs").new()
	-- The private runtime's openssl, never a host copy (resolve: a child logs nothing).
	local openssl = require("infra.owned_programs").resolve("openssl")
	local quote = require("text_utils").shell_quote
	local probe = openssl:sub(1, 1) == "/" and ("test -x " .. quote(openssl)) or ("command -v " .. quote(openssl) .. " >/dev/null")
	if require("ui.native_dialog").exit_code(os.execute(probe)) ~= 0 then
		dialogs.message("error", t("apps.encryptor.title_encrypt"), t("apps.encryptor.err_cipher_unavailable"))
		return 69
	end
	Core.run(options.files, {
		dialogs = dialogs, t = t, format = Core.load_format(), openssl = openssl, reveal = reveal,
	})
	return 0
end

if type(arg) == "table" and type(arg[0]) == "string" and require("native_path").basename(arg[0]) == "encryptor.lua" then
	local argv = {}
	for index = 1, #arg do argv[index] = arg[index] end
	os.exit(M.main(argv))
end

return M
