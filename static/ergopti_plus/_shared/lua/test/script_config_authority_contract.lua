--- _shared/lua/test/script_config_authority_contract.lua

--- ==============================================================================
--- MODULE: Script Config Authority Contract
--- DESCRIPTION:
--- Replays, on each Lua driver, the rule that config.toml's [script] rows win
--- over the saved native values at start, and that a change rewrites the row
--- the file holds so the next start keeps it. Real manifest reader, real TOML
--- writer and a real file; only the native store is an in-memory table.
--- ==============================================================================

local M = {}
local Authority = require("script_config_authority")

--- Writes a scratch config.toml and returns its path.
--- @param content string|nil Nil leaves no file behind.
--- @return string path
local function scratch(content)
	local path = os.tmpname()
	os.remove(path)
	path = path .. "_config.toml"
	if content then
		local handle = assert(io.open(path, "wb"))
		handle:write(content)
		handle:close()
	end
	return path
end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

--- A native store seeded with saved values, recording each write.
local function store(seed)
	local values, writes = {}, 0
	for key, value in pairs(seed) do values[key] = value end
	return { values = values, writes = function() return writes end,
		get = function(key) return values[key] end,
		set = function(key, value) values[key] = value; writes = writes + 1; return true end }
end

local function silent()
	local logged = {}
	local function sink(level)
		return function(_, fmt, ...) logged[#logged + 1] = level .. ":" .. string.format(fmt, ...) end
	end
	return { error = sink("error"), warn = sink("warn"), info = sink("info"), debug = sink("debug"),
		trace = sink("trace"), logged = logged }
end

--- Runs every case.
--- @param helpers table Driver test helpers (describe, it, assert_eq, assert_true).
--- @param options table { platform, manifest, aliases (script_scope.alias_names()), file_adapter }.
function M.run(helpers, options)
	local aliases, manifest, platform = options.aliases, options.manifest, options.platform
	local locale_alias = aliases["script.locale"].alias
	local level_alias = aliases["script.log_level"].alias
	local dialog_alias = aliases["script.show_error_dialog"].alias
	local function adopt(path, native, logger)
		return Authority.adopt({ path = path, file_adapter = options.file_adapter, manifest = manifest,
			platform = platform, aliases = aliases, storage = native, logger = logger or silent(), log = "test" })
	end

	helpers.describe("config.toml [script] wins at start (" .. platform .. ")", function()
		helpers.it("adopts every configured row over the saved value (script-config-wins-at-start)", function()
			local path = scratch('[script]\nlocale = "en"\nlog_level = "ERROR"\nshow_error_dialog = false\n')
			local native = store({ [locale_alias] = "fr", [level_alias] = "DEBUG", [dialog_alias] = true })
			local adopted = adopt(path, native)
			os.remove(path)
			helpers.assert_eq(native.values[locale_alias], "en", "the configured locale wins")
			helpers.assert_eq(native.values[level_alias], "ERROR", "the configured log level wins")
			helpers.assert_eq(native.values[dialog_alias], false, "the configured error window switch wins")
			helpers.assert_eq(adopted["script.locale"], "en")
		end)

		helpers.it("leaves the saved values alone without a [script] row: no migration (script-config-no-migration)", function()
			for _, content in ipairs({ false, "[hotstrings]\nenabled = true\n" }) do
				local path = scratch(content or nil)
				local native = store({ [locale_alias] = "de", [level_alias] = "INFO" })
				local adopted = adopt(path, native)
				local after = read(path)
				os.remove(path)
				helpers.assert_eq(native.writes(), 0, "nothing is copied between the stores")
				helpers.assert_eq(native.values[locale_alias], "de")
				helpers.assert_eq(next(adopted), nil)
				helpers.assert_eq(after, content or nil, "the file is never written at start")
			end
		end)

		-- Windows' loader admits an enum's case variant (AHK's = compares without
		-- case) and keeps the manifest spelling. A hand-written « debug » did
		-- nothing on the Lua drivers and was offered for deletion (CFS-001,
		-- script-config-enum-case).
		helpers.it("adopts an enum value in another case as its manifest spelling (script-config-enum-case)", function()
			local path = scratch('[script]\nlog_level = "debug"\n')
			local native = store({ [level_alias] = "INFO" })
			local logger = silent()
			local adopted = adopt(path, native, logger)
			os.remove(path)
			helpers.assert_eq(native.values[level_alias], "DEBUG", "the level is the manifest's DEBUG")
			helpers.assert_eq(adopted["script.log_level"], "DEBUG")
			for _, line in ipairs(logger.logged) do
				helpers.assert_true(line:find("^warn:") == nil, "and nothing is reported as outdated: " .. line)
			end
			path = scratch('[script]\nlog_level = "verbose"\n')
			native = store({ [level_alias] = "INFO" })
			adopt(path, native)
			os.remove(path)
			helpers.assert_eq(native.values[level_alias], "INFO", "a value no case of which is listed is still refused")
		end)

		helpers.it("refuses an undeclared value and a malformed file (script-config-refusals)", function()
			local path = scratch('[script]\nlocale = "xx"\n')
			local native = store({ [locale_alias] = "fr" })
			local logger = silent()
			adopt(path, native, logger)
			os.remove(path)
			helpers.assert_eq(native.values[locale_alias], "fr", "an unknown locale is not adopted")
			path = scratch('[script\nlocale = "en"\n')
			native = store({ [locale_alias] = "fr" })
			logger = silent()
			local adopted = adopt(path, native, logger)
			os.remove(path)
			helpers.assert_eq(adopted, nil, "a malformed file adopts nothing")
			helpers.assert_eq(native.values[locale_alias], "fr")
			helpers.assert_true(#logger.logged > 0 and logger.logged[1]:find("^error:") ~= nil, "and says so")
		end)

		helpers.it("rewrites only a row the file holds (script-config-change-rewrite)", function()
			local path = scratch('[script]\nlocale = "fr"\n\n\n\n\n\n[hotstrings]\nenabled = true\n')
			local committed = Authority.rewrite({ path = path, file_adapter = options.file_adapter,
				manifest = manifest, key = "script.locale", value = "en" })
			local after = read(path)
			helpers.assert_true(committed, "the held row is rewritten")
			helpers.assert_true(after:find('locale = "en"', 1, true) ~= nil, "the next start reads the new choice")
			helpers.assert_true(after:find("[hotstrings]", 1, true) ~= nil, "the rest of the file stays")
			local native = store({ [locale_alias] = "en" })
			adopt(path, native)
			helpers.assert_eq(native.values[locale_alias], "en", "the start no longer undoes the menu change")
			os.remove(path)
			local bare = "[hotstrings]\nenabled = true\n"
			path = scratch(bare)
			committed = Authority.rewrite({ path = path, file_adapter = options.file_adapter,
				manifest = manifest, key = "script.log_level", value = "ERROR" })
			after = read(path)
			os.remove(path)
			helpers.assert_true(committed)
			helpers.assert_eq(after, bare, "a file without the row is not touched")
			path = scratch(nil)
			committed = Authority.rewrite({ path = path, file_adapter = options.file_adapter,
				manifest = manifest, key = "script.locale", value = "en" })
			helpers.assert_true(committed)
			helpers.assert_eq(read(path), nil, "an absent file is not created")
		end)
	end)
end

return M
