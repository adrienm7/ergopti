--- _shared/tests/lua/settings/script_config_authority_contract.lua

--- ==============================================================================
--- MODULE: Script Config Authority Contract
--- DESCRIPTION:
--- Replays, on each Lua driver, the rule that config.toml's [script] rows win
--- over the saved native values at start, that a row the file lacks clears its
--- saved value (the locale excepted), and that a change writes the row so the
--- next start keeps it. Real manifest reader, real TOML writer and a real file;
--- only the native store is an in-memory table.
--- ==============================================================================

local M = {}
local Authority = require("settings.engine.scope.script_config_authority")

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
		set = function(key, value) values[key] = value; writes = writes + 1; return true end,
		delete = function(key) values[key] = nil; writes = writes + 1; return true end }
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
	local font_alias = aliases["script.reading_font"].alias
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

		-- A restored or hand-edited file without a row kept the saved value on
		-- macOS and Linux, where Windows (the file is its only store) reads the
		-- default (configuration follow-up, script-config-absent-row-resets).
		helpers.it("clears the saved value of a row the file lacks (script-config-absent-row-resets)", function()
			for _, content in ipairs({ false, "[hotstrings]\nenabled = true\n" }) do
				local path = scratch(content or nil)
				local native = store({ [level_alias] = "DEBUG", [dialog_alias] = false, [font_alias] = "dyslexic" })
				local adopted, _, cleared = adopt(path, native)
				local after = read(path)
				os.remove(path)
				helpers.assert_eq(native.values[level_alias], nil, "the log level reads its default again")
				helpers.assert_eq(native.values[dialog_alias], nil, "the error window switch reads its default again")
				helpers.assert_eq(native.values[font_alias], nil, "the reading font reads its default again")
				helpers.assert_eq(next(adopted), nil)
				helpers.assert_eq(cleared["script.log_level"], true)
				helpers.assert_eq(after, content or nil, "the file is never written at start")
			end
			local path = scratch("[script]\nshow_error_dialog = false\n")
			local native = store({ [dialog_alias] = false })
			local _, _, cleared = adopt(path, native)
			os.remove(path)
			helpers.assert_eq(native.writes(), 0, "an already empty or configured alias is not written")
			helpers.assert_eq(next(cleared), nil)
		end)

		-- Every driver reads an absent locale as the system language, while the
		-- sparse writer deletes a chosen "fr" as neutral: clearing it would lose
		-- an explicit French choice (script-config-locale-kept-when-absent).
		helpers.it("keeps the saved locale without a row (script-config-locale-kept-when-absent)", function()
			local path = scratch("[hotstrings]\nenabled = true\n")
			local native = store({ [locale_alias] = "de" })
			adopt(path, native)
			os.remove(path)
			helpers.assert_eq(native.writes(), 0, "the locale is not copied between the stores")
			helpers.assert_eq(native.values[locale_alias], "de")
		end)

		helpers.it("logs a start whose alias cannot be cleared (script-config-absent-clear-refused)", function()
			local path = scratch("")
			local native = store({ [dialog_alias] = false })
			native.delete = function() return false end
			local logger = silent()
			local _, _, cleared = adopt(path, native, logger)
			os.remove(path)
			helpers.assert_eq(cleared["script.show_error_dialog"], nil)
			local said = false
			for _, line in ipairs(logger.logged) do said = said or line:find("^error:.*could not be cleared") ~= nil end
			helpers.assert_true(said, "the refused clear is logged as an error")
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

		helpers.it("rewrites a held row, and writes an absent one unless it is the locale (script-config-change-rewrite)", function()
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
			helpers.assert_true(committed)
			helpers.assert_true(after:find('log_level = "ERROR"', 1, true) ~= nil,
				"an absent row is written, so the next start keeps the change")
			native = store({ [level_alias] = "ERROR" })
			adopt(path, native)
			helpers.assert_eq(native.values[level_alias], "ERROR", "and the start does not clear it")
			os.remove(path)
			path = scratch(bare)
			committed = Authority.rewrite({ path = path, file_adapter = options.file_adapter,
				manifest = manifest, key = "script.show_error_dialog", value = true })
			after = read(path)
			helpers.assert_true(committed)
			helpers.assert_eq(after, bare, "an absent row already reads as the neutral default")
			committed = Authority.rewrite({ path = path, file_adapter = options.file_adapter,
				manifest = manifest, key = "script.locale", value = "en" })
			after = read(path)
			os.remove(path)
			helpers.assert_true(committed)
			helpers.assert_eq(after, bare, "an absent locale row is not written")
			path = scratch(nil)
			committed = Authority.rewrite({ path = path, file_adapter = options.file_adapter,
				manifest = manifest, key = "script.locale", value = "en" })
			helpers.assert_true(committed)
			helpers.assert_eq(read(path), nil, "an absent file is not created for the locale")
			local owned_committed = Authority.rewrite_owned({ path = path, file_adapter = options.file_adapter,
				manifest = manifest, key = "script.log_level", value = "ERROR" })
			helpers.assert_eq(owned_committed, false, "an owned change without a file has no receipt and is refused")
			helpers.assert_eq(read(path), nil, "and creates nothing")
		end)
	end)
end

return M
