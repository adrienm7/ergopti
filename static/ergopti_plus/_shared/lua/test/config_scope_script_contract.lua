--- _shared/lua/test/config_scope_script_contract.lua

--- Exercises the direct script owner with real native scalar consumers.
return function(helpers, driver)
	local initial = '# retained comment\n[script]\nlocale = "en"\nlog_level = "DEBUG"\nshow_error_dialog = false\n[future]\nopaque = [1,2]\n'
	local function fixture(callback, settings)
		settings = settings or {}
		local saved = {}
		for name, value in pairs(package.loaded) do saved[name] = value end
		local names = { "adapters.storage", "infra.script_scope", "infra.i18n", "infra.locale", "locale.core",
			"infra.script_settings", "infra.logger", "infra.preferences", "ui.error_dialog", "ui.error_dialog.bridge",
			"script_scope_runtime", "toml_codec.writer", "config_migrate", "config_scope_transaction", "ui.menu.scoped_preferences",
			"ui.menu.preferences_transaction" }
		for _, name in ipairs(names) do package.loaded[name] = nil end
		local prefix = assert(os.tmpname()); os.remove(prefix)
		local quote = require("text_utils").shell_quote
		local function shell(command) local result = os.execute(command); assert(result == true or result == 0) end
		shell("mkdir -p -- " .. quote(prefix .. "/ergopti_plus"))
		local function write(path, bytes) local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close()) end
		local function read(path) local file = io.open(path, "rb"); if not file then return nil end
			local bytes = file:read("*a"); file:close(); return bytes end
		local path = prefix .. "/config.toml"
		local source = settings.source or initial
		write(path, source)
		local previous_settings = driver == "macos" and hs.settings or nil
		local previous_config_home, paths
		local called, failure = xpcall(function()
			local store, files, cells
			if driver == "linux" then
				paths = require("infra.config_paths"); previous_config_home = paths.config_home
				paths.config_home = function() return prefix end
				write(prefix .. "/ergopti_plus/storage.json", settings.storage or
					'{"locale":"en","script.log_level":"DEBUG","script.show_error_dialog":false,"foreign":[1,2]}')
				store, files = require("adapters.storage"), require("adapters.file_system")
			else
				cells = { ["ergopti.i18n_locale"] = "en", ["ergopti.log_level"] = "DEBUG",
					["ergopti.script.show_error_dialog"] = false, ["ergopti.foreign"] = { 1, 2 } }
				hs.settings = { get = function(key) return cells[key] end,
					set = function(key, value) cells[key] = value; return true end,
					clear = function(key) cells[key] = nil; return true end,
					getKeys = function() local keys = {}; for key in pairs(cells) do keys[#keys + 1] = key end; return keys end }
				store = require("adapters.storage")
				files = { read_with_status = function(name) local bytes = read(name); return bytes, bytes and "ok" or "absent" end,
					write = function(name, bytes) write(name, bytes); return true end,
					write_if_unchanged = function(name, bytes, expected)
						local before = read(name)
						if (before and expected.status ~= "ok") or (not before and expected.status ~= "absent")
							or (before and before ~= expected.content) then return false end
						write(name, bytes); return true
					end,
					delete = function(name) os.remove(name); return true end }
				package.loaded["adapters.file_system"] = files
			end
			local i18n, backend = require("infra.i18n"), require("infra.locale")
			if driver == "macos" then i18n.set_locale_injector(backend.set_locale) end
			i18n.init()
			local logger = require(driver == "linux" and "infra.script_settings" or "infra.logger")
			if driver == "linux" then assert(logger.apply()) else logger.set_level("DEBUG") end
			local dialog = require(driver == "linux" and "ui.error_dialog.bridge" or "ui.error_dialog")
			local function create(overrides)
				local options = { path = path, files = files, is_paused = function() return false end,
					backup_path = path .. ".bak", storage_backup_path = path .. ".settings.bak" }
				if driver == "macos" then
					local preferences = require("infra.preferences")
					local _, status = preferences.load(path); assert(status == "ok", status)
					local state = {}
					local _, checkpoint = require("ui.menu.preferences_transaction").bind(preferences,
						{ state = state, initial_state = {}, initial_preferences = {} })
					options = { path = path, files = files, state = state, preferences = preferences, checkpoint = checkpoint,
						capture_preferences = function() return preferences.snapshot(state, {}, {}) end,
						admission = function(_, work) return work() == true end, paused = function() return false end,
						backup_path = function() return path .. ".bak" end,
						storage_backup_path = function() return path .. ".settings.bak" end }
				end
				for key, value in pairs(overrides or {}) do options[key] = value end
				return require("infra.script_scope").new(options)
			end
			callback({ create = create, path = path, source = source, store = store, files = files,
				read = read, write = write, i18n = i18n, backend = backend, logger = logger, dialog = dialog, cells = cells })
		end, debug.traceback)
		if paths then paths.config_home = previous_config_home end
		if driver == "macos" then hs.settings = previous_settings end
		for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(saved) do package.loaded[name] = value end
		shell("rm -rf -- " .. quote(prefix))
		if not called then error(failure, 0) end
	end
	local locale_alias = driver == "linux" and "locale" or "i18n_locale"
	local log_alias = driver == "linux" and "script.log_level" or "log_level"
	local function restored(ctx)
		helpers.assert_eq(ctx.read(ctx.path), ctx.source)
		helpers.assert_eq(ctx.i18n.get_locale(), "en")
		helpers.assert_eq(ctx.backend.current_locale(), "en")
		helpers.assert_eq(ctx.dialog.is_enabled(), false)
		helpers.assert_eq(ctx.store.get(locale_alias), "en")
		helpers.assert_eq(ctx.store.get(log_alias), "DEBUG")
		helpers.assert_eq(ctx.store.get("script.show_error_dialog"), false)
	end
	helpers.describe("direct script scope native composition", function()
		for _, mode in ipairs({ "recommended", "clear" }) do
			helpers.it("publishes only its declared " .. mode .. " rows and restores actual consumers", function()
				fixture(function(ctx)
					local owner = ctx.create()
					local committed, detail = owner.apply(mode)
					helpers.assert_eq(committed, true, detail)
					helpers.assert_eq(owner.pending(), false)
					local document = assert(require("toml_codec").decode(ctx.read(ctx.path)))
					helpers.assert_eq(document.future.opaque, { 1, 2 })
					helpers.assert_eq(ctx.read(ctx.path .. ".bak"), ctx.source)
					helpers.assert_true(ctx.read(ctx.path .. ".settings.bak") ~= nil)
					helpers.assert_eq(ctx.i18n.get_locale(), "fr")
					helpers.assert_eq(ctx.backend.current_locale(), "fr")
					helpers.assert_eq(ctx.dialog.is_enabled(), true)
					helpers.assert_eq(ctx.store.get(locale_alias), "fr")
					helpers.assert_eq(ctx.store.get(log_alias), "INFO")
					helpers.assert_eq(ctx.store.get("script.show_error_dialog"), true)
					helpers.assert_eq(owner.revert(), true)
					restored(ctx)
					helpers.assert_eq(owner.release(), true)
				end)
			end)
		end
		helpers.it("reconstructs actual native consumers from aliases after a sparse canonical clear", function()
			fixture(function(ctx)
				local owner = ctx.create()
				helpers.assert_eq(owner.apply("clear"), true)
				helpers.assert_eq(owner.release(), true)
				local locale_name, log_name = "infra.i18n", driver == "linux" and "infra.script_settings" or "infra.logger"
				local dialog_name = driver == "linux" and "ui.error_dialog.bridge" or "ui.error_dialog"
				package.loaded[locale_name], package.loaded[log_name], package.loaded[dialog_name] = nil, nil, nil
				local locale, logger, dialog = require(locale_name), require(log_name), require(dialog_name)
				if driver == "macos" then locale.set_locale_injector(ctx.backend.set_locale) end
				locale.init()
				if driver == "linux" then helpers.assert_eq(logger.apply(), true)
				else logger.set_level(ctx.store.get(log_alias)) end
				helpers.assert_eq(locale.get_locale(), "fr")
				helpers.assert_eq(ctx.backend.current_locale(), "fr")
				if driver == "linux" then helpers.assert_eq(logger.current(), "INFO")
				else helpers.assert_eq(logger.current_level, 20) end
				helpers.assert_eq(dialog.is_enabled(), true)
				local document = assert(require("toml_codec").decode(ctx.read(ctx.path)))
				helpers.assert_eq(document.script.locale, nil, "native persistence must not make canonical defaults explicit")
				helpers.assert_eq(document.script.log_level, nil)
				helpers.assert_eq(document.script.show_error_dialog, nil)
				helpers.assert_eq(document.future.opaque, { 1, 2 })
			end)
		end)
		helpers.it("honors the actual boot schema refusal before any backup or native alias write", function()
			fixture(function(ctx)
				local migrate = require("config_migrate")
				require("toml_codec.writer").refuse_writes(ctx.path, "invalid schema")
				helpers.assert_eq(migrate.read_only_reason(ctx.path), "invalid schema")
				local owner = ctx.create()
				helpers.assert_eq(owner.apply("recommended"), false)
				helpers.assert_eq(owner.pending(), false)
				helpers.assert_eq(ctx.read(ctx.path .. ".bak"), nil)
				helpers.assert_eq(ctx.read(ctx.path .. ".settings.bak"), nil)
				restored(ctx)
			end)
		end)
		helpers.it("refuses paused and invalid requests before source or alias mutation", function()
			fixture(function(ctx)
				local owner = ctx.create(driver == "linux" and { is_paused = function() return nil end }
					or { paused = function() return nil end })
				helpers.assert_eq(owner.apply("recommended"), false)
				helpers.assert_eq(owner.apply("invalid"), false)
				helpers.assert_eq(ctx.read(ctx.path .. ".bak"), nil)
				helpers.assert_eq(ctx.read(ctx.path .. ".settings.bak"), nil)
				restored(ctx)
			end)
		end)
		for _, line in ipairs({ 'locale = false', 'log_level = 2', 'show_error_dialog = "false"' }) do
			helpers.it("refuses an existing wrong-kind script source: " .. line, function()
				fixture(function(ctx)
					local owner = ctx.create()
					helpers.assert_eq(owner.apply("recommended"), false)
					helpers.assert_eq(owner.pending(), false)
					helpers.assert_eq(ctx.read(ctx.path .. ".bak"), nil)
					helpers.assert_eq(ctx.read(ctx.path .. ".settings.bak"), nil)
					restored(ctx)
				end, { source = "[script]\n" .. line .. "\n[future]\nopaque = [1,2]\n" })
			end)
		end
		helpers.it("refuses a same-valued declaration owner replacement before file or aliases are written", function()
			fixture(function(ctx)
				local owner = ctx.create()
				local manifest = require("infra.manifest_reader")
				local original = manifest.direct_scope_plan
				manifest.direct_scope_plan = function(...) return original(...) end
				local called, failure = pcall(function()
					helpers.assert_eq(owner.apply("recommended"), false)
					helpers.assert_eq(owner.pending(), false)
					helpers.assert_eq(ctx.read(ctx.path .. ".bak"), nil)
					helpers.assert_eq(ctx.read(ctx.path .. ".settings.bak"), nil)
					restored(ctx)
				end)
				manifest.direct_scope_plan = original
				if not called then error(failure) end
			end)
		end)
		helpers.it("refuses a same-valued declaration successor interposed by the real config read", function()
			fixture(function(ctx)
				local manifest = require("infra.manifest_reader")
				local planner, reader = manifest.direct_scope_plan, ctx.files.read_with_status
				local armed = false
				ctx.files.read_with_status = function(path)
					local bytes, status, detail = reader(path)
					if armed and path == ctx.path then
						armed = false
						manifest.direct_scope_plan = function(...) return planner(...) end
					end
					return bytes, status, detail
				end
				local called, failure = pcall(function()
					local owner = ctx.create()
					armed = true
					helpers.assert_eq(owner.apply("recommended"), false)
					helpers.assert_eq(armed, false, "the actual source read must interpose the successor")
					helpers.assert_eq(owner.pending(), false)
					helpers.assert_eq(ctx.read(ctx.path .. ".bak"), nil)
					helpers.assert_eq(ctx.read(ctx.path .. ".settings.bak"), nil)
					restored(ctx)
				end)
				ctx.files.read_with_status, manifest.direct_scope_plan = reader, planner
				if not called then error(failure) end
			end)
		end)
		helpers.it("refuses changed declaration metadata before file or aliases are written", function()
			fixture(function(ctx)
				local owner = ctx.create()
				local manifest = require("infra.manifest_reader")
				local entry = (manifest.find_declared_entry_by_path or manifest.find_entry_by_path)("script.locale")
				local original = entry.platforms
				entry.platforms = { "ahk" }
				local called, failure = pcall(function()
					helpers.assert_eq(owner.apply("recommended"), false)
					helpers.assert_eq(owner.pending(), false)
					helpers.assert_eq(ctx.read(ctx.path .. ".bak"), nil)
					restored(ctx)
				end)
				entry.platforms = original
				if not called then error(failure) end
			end)
		end)
		helpers.it("compensates a real partially applied translation backend that explicitly refuses", function()
			fixture(function(ctx)
				local setter = ctx.backend.set_locale
				ctx.backend.set_locale = function(value)
					setter(value)
					if value == "fr" then return false end
				end
				if driver == "macos" then ctx.i18n.set_locale_injector(ctx.backend.set_locale) end
				local called, failure = pcall(function()
					local owner = ctx.create()
					helpers.assert_eq(owner.apply("recommended"), false)
					helpers.assert_eq(owner.pending(), false)
					helpers.assert_eq(ctx.read(ctx.path .. ".bak"), ctx.source)
					helpers.assert_true(ctx.read(ctx.path .. ".settings.bak") ~= nil)
					restored(ctx)
					helpers.assert_eq(owner.release(), true)
				end)
				ctx.backend.set_locale = setter
				if not called then error(failure) end
			end)
		end)
		helpers.it("retains the real participant through composition finalization without replay", function()
			fixture(function(ctx)
				local owner = ctx.create()
				local participant = require("config_scope_participant").synchronous({
					apply = function(mode) return owner.apply(mode) end, owner = function() return owner end })
				local composition = require("config_scope_composition").new({ manifest = require("infra.manifest_reader"),
					scope = "global", logger = require(driver == "linux" and "logger.shim" or "infra.logger"),
					participants = function() return { global = participant } end })
				local committed, report
				composition.apply("recommended", function(ok, result) committed, report = ok, result end)
				helpers.assert_eq(committed, true, report and report.detail)
				helpers.assert_eq(report.applied, { "global" })
				helpers.assert_eq(composition.pending(), false)
				helpers.assert_eq(ctx.store.set(locale_alias, "en"), true, "finalization releases native alias admission")
				helpers.assert_eq(ctx.i18n.set_locale_injector(ctx.backend.set_locale), nil)
			end)
		end)
	end)
end
