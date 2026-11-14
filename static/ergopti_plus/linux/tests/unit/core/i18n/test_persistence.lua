--- tests/unit/core/i18n/test_persistence.lua
---
--- Integration tests for i18n locale persistence and discovery.
--- Verifies that the i18n module loads, persists locale changes via storage,
--- discovers available locale files, and exposes the expected API surface.

local helpers = require("tests.helpers")

-- The application folder under every XDG base, from the shared registry.
local FOLDER = require("core.fs.engine.app_dirs").linux.folder_name

helpers.describe("i18n persistence", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("i18n exports the expected methods", function()
      local i18n = helpers.load_module("core.i18n.engine.i18n")
      helpers.assert_true(type(i18n.get)         == "function", "get")
      helpers.assert_true(type(i18n.get_locale)  == "function", "get_locale")
      helpers.assert_true(type(i18n.set_locale)  == "function", "set_locale")
      helpers.assert_true(type(i18n.list_locales)== "function", "list_locales")
      helpers.assert_true(type(i18n.display_name)== "function", "display_name")
      helpers.assert_true(type(i18n.set_trigger_provider) == "function", "set_trigger_provider")
      helpers.assert_true(type(i18n.init)        == "function", "init")
    end)

    helpers.it("locale module exports set_trigger_provider", function()
      local loc = helpers.load_module("core.i18n.engine.locale")
      helpers.assert_true(type(loc.set_trigger_provider) == "function", "locale.set_trigger_provider")
    end)
  end)

  -- ==========================================================================
  -- 2. Locale discovery
  -- ==========================================================================

  helpers.describe("locale discovery", function()
    helpers.it("(locale-order-close) falls back when the order stream close is refused", function()
      local reader, directory, paths = require("core.fs.engine.regular_file_reader"), require("core.fs.engine.native_directory"), require("core.fs.engine.paths")
      local original_open, original_entries, original_shared = reader.open_source, directory.entries, paths.shared
      reader.open_source = function()
        return { read = function() return '{"order":["fr","en"]}' end, close = function() return nil, "close failed" end }
      end
      directory.entries = function() return { { name = "fr.json", kind = "file" }, { name = "en.json", kind = "file" } } end
      paths.shared = function(name) if name == "data" or name == "core/i18n/data/locales" then return "/synthetic" end; return original_shared(name) end
      local ok, err = pcall(function()
        local i18n = helpers.load_module("core.i18n.engine.i18n")
        helpers.assert_eq(i18n.list_locales(), { "en", "fr" })
      end)
      reader.open_source, directory.entries, paths.shared = original_open, original_entries, original_shared
      if not ok then error(err, 0) end
    end)
    helpers.it("native-locale-catalog: only actual locale files establish availability", function()
      local shell = require("adapters.shell_runner")
      helpers.assert_true(shell.has_command("python3") and shell.has_command("luajit"),
        "native locale catalog receipts require Python and LuaJIT")
      local quote = require("core.text.engine.utils_core").shell_quote
      local runtime = assert(shell.exec_line("command -v luajit"))
      local root = helpers.driver_root()
      local fixture = root .. "/tests/hardware/test_i18n_catalog.py"
      local status = os.execute("python3 " .. quote(fixture) .. " --runtime " .. quote(runtime)
        .. " --driver " .. quote(root))
      helpers.assert_true(status == true or status == 0,
        "complete native catalogs must preserve availability, refusal, cache and retry contracts")
    end)

    helpers.it("list_locales returns at least fr and en", function()
      local i18n = helpers.load_module("core.i18n.engine.i18n")
      i18n.init()
      local codes = i18n.list_locales()
      helpers.assert_true(type(codes) == "table" and #codes >= 2,
        string.format("list_locales: at least 2 codes (got %d)", #codes))

      -- fr and en should always be present.
      local has_fr = false
      local has_en = false
      for _, c in ipairs(codes) do
        if c == "fr" then has_fr = true end
        if c == "en" then has_en = true end
      end
      helpers.assert_true(has_fr, "fr is in available locales")
      helpers.assert_true(has_en, "en is in available locales")
    end)

    helpers.it("display_name returns human-readable names for known codes", function()
      local i18n = helpers.load_module("core.i18n.engine.i18n")
      helpers.assert_eq(i18n.display_name("fr"), "Français", "fr → Français")
      helpers.assert_eq(i18n.display_name("en"), "English",  "en → English")
      helpers.assert_eq(i18n.display_name("de"), "Deutsch",  "de → Deutsch")
    end)

    helpers.it("display_name returns code as-is for unknown locales", function()
      local i18n = helpers.load_module("core.i18n.engine.i18n")
      helpers.assert_eq(i18n.display_name("xx_UNKNOWN"), "xx_UNKNOWN",
        "unknown code returned as-is")
    end)
  end)

  -- ==========================================================================
  -- 3. Locale persistence (storage adapter)
  -- ==========================================================================

  helpers.describe("locale persistence", function()
    local function stub_scope_for_store()
      return {
        retry_locale = function() return true end,
        edit_locale = function(value)
          if require("core.fs.adapters.storage").set("locale", value) ~= true then return false end
          local native = require("core.i18n.engine.i18n")
          local token = { pending = function() return false end }
          assert(native.scope_acquire(token))
          local receipt = assert(native.scope_capture(token))
          local applied = native.scope_apply(token, receipt, value)
          assert(native.scope_release(token))
          assert(native.scope_forget(token, receipt))
          return applied
        end,
      }
    end
    helpers.it("set_locale + get_locale round-trips", function()
      -- An in-memory store that acknowledges every write: the round trip must
      -- not depend on whichever storage adapter an earlier test file left loaded.
      local saved_storage = package.loaded["core.fs.adapters.storage"]
      local saved_scope = package.loaded["infra.script_scope"]
      package.loaded["infra.script_scope"] = stub_scope_for_store()
      local stored = {}
      package.loaded["core.fs.adapters.storage"] = {
        get = function(key) return stored[key] end,
        set = function(key, value) stored[key] = value; return true end,
      }
      local ok, err = pcall(function()
        local i18n = helpers.load_module("core.i18n.engine.i18n")
        i18n.init()
        local before = i18n.get_locale()
        helpers.assert_true(type(before) == "string" and #before > 0,
          string.format("initial locale: %s", tostring(before)))

        -- Switch to "en" and verify.
        i18n.set_locale("en")
        helpers.assert_eq(i18n.get_locale(), "en", "locale changed to en")

        -- Switch back to the original and ensure it persists.
        i18n.set_locale(before)
        helpers.assert_eq(i18n.get_locale(), before, "locale restored")
      end)
      package.loaded["core.fs.adapters.storage"] = saved_storage
      package.loaded["infra.script_scope"] = saved_scope
      package.loaded["core.i18n.engine.i18n"] = nil
      if not ok then error(err, 0) end
    end)

		helpers.it("does not publish a locale whose durable write failed", function()
			local saved_storage = package.loaded["core.fs.adapters.storage"]
			local saved_scope = package.loaded["infra.script_scope"]
			package.loaded["infra.script_scope"] = stub_scope_for_store()
			package.loaded["core.fs.adapters.storage"] = {
				get = function() return "fr" end,
				set = function() return false end,
			}
			local ok, err = pcall(function()
				local i18n = helpers.load_module("core.i18n.engine.i18n")
				i18n.init()
				helpers.assert_eq(i18n.get_locale(), "fr")
				helpers.assert_eq(i18n.set_locale("en"), false,
					"a returned storage failure must reject the transition")
				helpers.assert_eq(i18n.get_locale(), "fr",
					"the active locale must remain aligned with durable storage")
			end)
			package.loaded["core.fs.adapters.storage"] = saved_storage
			package.loaded["infra.script_scope"] = saved_scope
			package.loaded["core.i18n.engine.i18n"] = nil
			if not ok then error(err, 0) end
		end)

		helpers.it("(lcy-002-system-locale) picks the session language as Windows and macOS do", function()
			local i18n = helpers.load_module("core.i18n.engine.i18n")
			local available = { "de", "en", "fr", "no" }
			local function env(values) return function(name) return values[name] end end
			helpers.assert_eq(i18n.detect_system_locale(available, env({ LANG = "de_DE.UTF-8" })), "de")
			helpers.assert_eq(i18n.detect_system_locale(available,
				env({ LC_ALL = "fr_FR.UTF-8", LC_MESSAGES = "de_DE", LANG = "en_US" })), "fr", "LC_ALL wins")
			helpers.assert_eq(i18n.detect_system_locale(available,
				env({ LC_MESSAGES = "nb_NO.UTF-8", LANG = "de_DE" })), "no", "bokmål reads the Norwegian catalogue")
			helpers.assert_eq(i18n.detect_system_locale(available, env({ LANG = "C" })), "en")
			helpers.assert_eq(i18n.detect_system_locale(available, env({ LANG = "ja_JP.UTF-8" })), "en",
				"a language without a catalogue reads English, not French")
			helpers.assert_eq(i18n.detect_system_locale(available, env({})), "en")
			package.loaded["core.i18n.engine.i18n"] = nil
		end)

		helpers.it("(lcy-002-system-locale) a first run and an unknown saved code follow the session language", function()
			local saved_storage = package.loaded["core.fs.adapters.storage"]
			local saved_scope = package.loaded["infra.script_scope"]
			local saved_getenv = os.getenv
			package.loaded["infra.script_scope"] = stub_scope_for_store()
			local ok, err = pcall(function()
				os.getenv = function(name) if name == "LANG" then return "de_DE.UTF-8" end return nil end
				for _, saved in ipairs({ false, "xx" }) do
					package.loaded["core.fs.adapters.storage"] = {
						get = function() return saved or nil end,
						set = function() return true end,
					}
					local i18n = helpers.load_module("core.i18n.engine.i18n")
					i18n.init()
					helpers.assert_eq(i18n.get_locale(), "de",
						"saved=" .. tostring(saved) .. " must follow the session language")
					package.loaded["core.i18n.engine.i18n"] = nil
				end
			end)
			os.getenv = saved_getenv
			package.loaded["core.fs.adapters.storage"] = saved_storage
			package.loaded["infra.script_scope"] = saved_scope
			package.loaded["core.i18n.engine.i18n"] = nil
			if not ok then error(err, 0) end
		end)

    -- Cleanup: ensure "fr" is the default for subsequent tests.
    helpers.it("_cleanup_reset_locale_to_fr", function()
      local i18n = helpers.load_module("core.i18n.engine.i18n")
      i18n.init()
      i18n.set_locale("fr")
    end)

    helpers.it("set_locale with unknown code is ignored", function()
      local i18n = helpers.load_module("core.i18n.engine.i18n")
      i18n.init()
      local before = i18n.get_locale()
      i18n.set_locale("xx_ZZ_INVALID")
      helpers.assert_eq(i18n.get_locale(), before,
        "locale unchanged after invalid code")
    end)

    helpers.it("set_locale with nil/empty is safe", function()
      local i18n = helpers.load_module("core.i18n.engine.i18n")
      i18n.init()
      local before = i18n.get_locale()
      i18n.set_locale(nil)
      helpers.assert_eq(i18n.get_locale(), before, "nil does not change locale")
      i18n.set_locale("")
      helpers.assert_eq(i18n.get_locale(), before, "empty string does not change locale")
    end)
  end)

  -- ==========================================================================
  -- 4. Trigger provider
  -- ==========================================================================

  helpers.describe("trigger provider", function()
    helpers.it("set_trigger_provider does not crash", function()
      local i18n = helpers.load_module("core.i18n.engine.i18n")
      -- Called directly. A setter that accepted the provider and then failed to
      -- use it would satisfy "does not crash" and leave every label showing the
      -- default trigger character.
      i18n.set_trigger_provider(function() return "\\" end)
      helpers.assert_eq(type(i18n.set_trigger_provider), "function",
        "and the setter must remain callable for the next provider")
    end)

    helpers.it("set_trigger_provider with nil is safe", function()
      local loc = helpers.load_module("core.i18n.engine.locale")
      -- nil means "go back to the default", not "break". The module must still be
      -- usable afterwards or the next real provider never lands.
      loc.set_trigger_provider(nil)
      helpers.assert_eq(type(loc.set_trigger_provider), "function",
        "clearing the provider must leave the setter callable")
    end)
  end)

  -- ==========================================================================
  -- 5. Menu builder language submenu
  -- ==========================================================================

  helpers.describe("menu language submenu", function()
    helpers.it("language submenu items have callbacks and valid shape", function()
      local mb = helpers.load_module("ui.menu.builder")
      local items = mb.build({ _version = "test", on_quit = function() end })

      local lang_section = nil
      for _, item in ipairs(items) do
        if type(item.title) == "string" and (
          item.title:find("Langue", 1, true) or item.title:find("Language", 1, true)
        ) then
          lang_section = item
          break
        end
      end

      helpers.assert_true(lang_section ~= nil, "Language section present")
      if lang_section then
        helpers.assert_true(type(lang_section.menu) == "table" and #lang_section.menu >= 2,
          string.format("Language submenu has %d items", #(lang_section.menu or {})))
        for _, sub in ipairs(lang_section.menu) do
          helpers.assert_true(type(sub.fn) == "function",
            "Language item '" .. (sub.title or "?") .. "' has callback")
        end
      end
    end)
  end)

end)

helpers.describe("i18n explicit wizard persistence", function()
	local function with_owned_store(options, body)
		local names = { "core.i18n.engine.i18n", "core.i18n.engine.locale", "core.fs.adapters.storage", "infra.config_paths", "infra.script_settings", "ui.error_dialog.bridge" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local root = os.tmpname()
		os.remove(root)
		local made = os.execute("mkdir -p " .. string.format("%q", root .. "/" .. FOLDER))
		helpers.assert_true(made == true or made == 0)
		local config = root .. "/config/config.toml"
		if options.config then
			local created = os.execute("mkdir -p " .. string.format("%q", root .. "/config"))
			assert(created == true or created == 0)
			local cf = assert(io.open(config, "wb")); assert(cf:write(options.config)); assert(cf:close())
		end
		local path = root .. "/" .. FOLDER .. "/storage.json"
		local seed = '{"locale":"zz_UNSUPPORTED","future":{"retained":true}}\n'
		local fh = assert(io.open(path, "wb"))
		assert(fh:write(seed)); assert(fh:close())
		local original_rename = os.rename
		local logger = require("core.logger.engine.shim")
		local original_level = logger.get_level()
		local attempts = 0
		local observations = nil
		local ok, err = xpcall(function()
			-- config() is where the locale owner rewrites a held [script] locale.
			-- default_config_dir() is where the storage adapter keeps storage.json.
			package.loaded["infra.config_paths"] = { config_home = function() return root end,
				default_config_dir = function() return root .. "/" .. FOLDER end,
				config = function(name) return root .. "/config/" .. name end }
			package.loaded["core.i18n.engine.locale"] = nil
			package.loaded["core.fs.adapters.storage"] = nil
			package.loaded["infra.script_settings"] = nil
			package.loaded["ui.error_dialog.bridge"] = nil
			package.loaded["core.i18n.engine.i18n"] = nil
			local i18n = require("core.i18n.engine.i18n")
			i18n.init()
			os.rename = function(from, to)
				if from == helpers.stage_path(path) and to == path then
					attempts = attempts + 1
					if options.on_publish then options.on_publish(config) end
					if options.rename == "throw" then error("owned rename refused") end
					if options.rename == "false" then return nil, "owned rename refused", 13 end
				end
				local renamed, detail, errno = original_rename(from, to)
				if renamed and from == helpers.stage_path(path) and to == path and options.after_publish then options.after_publish(config, path) end
				return renamed, detail, errno
			end
			observations = body(i18n, path, seed)
		end, debug.traceback)
		os.rename = original_rename
		logger.set_level(original_level)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		os.remove(helpers.stage_path(path)); os.remove(path)
		os.remove(config); os.execute("rm -f " .. string.format("%q", root .. "/config") .. "/*.bak")
		os.execute("rm -f " .. string.format("%q", root .. "/" .. FOLDER) .. "/*.bak")
		if options.config then os.execute("rmdir " .. string.format("%q", root .. "/config")) end
		os.execute("rmdir " .. string.format("%q", root .. "/" .. FOLDER))
		os.execute("rmdir " .. string.format("%q", root))
		if not ok then error(err, 0) end
		return observations, attempts
	end

	local function read(path)
		local fh = assert(io.open(path, "rb"))
		local raw = assert(fh:read("*a")); assert(fh:close())
		return raw
	end

	helpers.it("(error-dialog-atomic) keeps source and state on storage refusal", function()
		local initial = '[script]\nshow_error_dialog = true\n'
		local observed = with_owned_store({ config = initial, rename = "false" }, function(_, path)
			local dialog = require("ui.error_dialog.bridge")
			local before = dialog.is_enabled()
			local accepted = dialog.set_enabled(false)
			return { accepted = accepted, before = before, active = dialog.is_enabled(),
				config = read(require("infra.config_paths").config("config.toml")), stored = require("core.text.engine.json").decode(read(path))["script.show_error_dialog"] }
		end)
		helpers.assert_eq(observed, { accepted = false, before = true, active = true, config = initial })
	end)

	helpers.it("(error-dialog-atomic) disables an already scheduled report", function()
		local observed = with_owned_store({}, function()
			local dialog = require("ui.error_dialog.bridge")
			local scheduled
			dialog.defer = function(fn) scheduled = fn; return true end
			assert(dialog.init())
			dialog.on_error("fixture", "failure", "failure")
			local had_schedule = type(scheduled) == "function"
			local accepted = dialog.set_enabled(false)
			if scheduled then scheduled() end
			return { scheduled = had_schedule, accepted = accepted, enabled = dialog.is_enabled() }
		end)
		helpers.assert_eq(observed, { scheduled = true, accepted = true, enabled = false })
	end)

	helpers.it("(error-dialog-atomic) retains and settles a refused inverse", function()
		local initial, published = '[script]\nshow_error_dialog = true\n', nil
		local once = true
		local observed = with_owned_store({ config = initial, after_publish = function(config, path)
			if not once then return end
			once = false
			published = read(path)
			local cf = assert(io.open(config, "wb")); assert(cf:write(initial .. "# concurrent\n")); assert(cf:close())
			local sf = assert(io.open(path, "wb")); assert(sf:write('{"script.show_error_dialog":true}')); assert(sf:close())
		end }, function(_, path)
			local dialog = require("ui.error_dialog.bridge")
			local accepted = dialog.set_enabled(false)
			local pending = require("infra.scope_registry").pending()
			local config = read(require("infra.config_paths").config("config.toml"))
			local sf = assert(io.open(path, "wb")); assert(sf:write(published)); assert(sf:close())
			local recovered = dialog.set_enabled(false)
			return { accepted = accepted, pending = pending, config = config, recovered = recovered,
				still_pending = require("infra.scope_registry").pending() }
		end)
		helpers.assert_eq(observed, { accepted = false, pending = true, config = initial .. "# concurrent\n",
			recovered = true, still_pending = false })
	end)

	helpers.it("(error-dialog-atomic) publishes configured and stored state together", function()
		local initial = '[script]\nshow_error_dialog = true\n'
		local observed = with_owned_store({ config = initial }, function(_, path)
			local dialog = require("ui.error_dialog.bridge")
			local accepted = dialog.set_enabled(false)
			return { accepted = accepted, active = dialog.is_enabled(),
				config = read(require("infra.config_paths").config("config.toml")), stored = require("core.text.engine.json").decode(read(path))["script.show_error_dialog"] }
		end)
		helpers.assert_eq(observed, { accepted = true, active = false, config = '[script]\nshow_error_dialog = false\n', stored = false })
	end)

	helpers.it("(log-level-atomic) leaves the source and logger unchanged on storage refusal", function()
		local initial = '[script]\nlog_level = "INFO"\n'
		local observed = with_owned_store({ config = initial, rename = "false" }, function(_, path)
			local settings = require("infra.script_settings")
			local before = settings.current()
			local accepted = settings.set("ERROR")
			return { accepted = accepted, before = before, active = settings.current(),
				config = read(require("infra.config_paths").config("config.toml")), stored = require("core.text.engine.json").decode(read(path))["script.log_level"] }
		end)
		helpers.assert_eq(observed, { accepted = false, before = "INFO", active = "INFO", config = initial })
	end)

	helpers.it("(log-level-atomic) retains a failed inverse without overwriting concurrent data", function()
		local initial, published = '[script]\nlog_level = "INFO"\n', nil
		local once = true
		local observed = with_owned_store({ config = initial, after_publish = function(config, path)
			if not once then return end
			once = false
			published = read(path)
			local cf = assert(io.open(config, "wb")); assert(cf:write('[script]\nlog_level = "DEBUG"\n')); assert(cf:close())
			local sf = assert(io.open(path, "wb")); assert(sf:write('{"script.log_level":"WARNING"}')); assert(sf:close())
		end }, function(_, path)
			local settings = require("infra.script_settings")
			local accepted = settings.set("ERROR")
			local pending = require("infra.scope_registry").pending()
			local config = read(require("infra.config_paths").config("config.toml"))
			local sf = assert(io.open(path, "wb")); assert(sf:write(published)); assert(sf:close())
			local recovered = settings.set("ERROR")
			return { accepted = accepted, pending = pending, config = config, recovered = recovered,
				still_pending = require("infra.scope_registry").pending() }
		end)
		helpers.assert_eq(observed, { accepted = false, pending = true, config = '[script]\nlog_level = "DEBUG"\n',
			recovered = true, still_pending = false })
	end)

	helpers.it("(log-level-atomic) publishes configured and stored levels together", function()
		local initial = '[script]\nlog_level = "INFO"\n'
		local observed = with_owned_store({ config = initial }, function(_, path)
			local settings = require("infra.script_settings")
			local accepted = settings.set("ERROR")
			return { accepted = accepted, active = settings.current(),
				config = read(require("infra.config_paths").config("config.toml")), stored = require("core.text.engine.json").decode(read(path))["script.log_level"] }
		end)
		helpers.assert_eq(observed, { accepted = true, active = "ERROR", config = '[script]\nlog_level = "ERROR"\n', stored = "ERROR" })
	end)

	helpers.it("(locale-atomic) preserves a configured row when storage refuses", function()
		local initial = '[script]\nlocale = "fr"\n'
		local observed = with_owned_store({ config = initial, rename = "false" }, function(i18n)
			local accepted = i18n.persist_locale("en")
			return { accepted = accepted, active = i18n.get_locale(), config = read(require("infra.config_paths").config("config.toml")) }
		end)
		helpers.assert_eq(observed, { accepted = false, active = "fr", config = initial })
	end)

	helpers.it("(locale-atomic) commits both configured and stored locale", function()
		local initial = '[script]\nlocale = "fr"\n'
		local observed = with_owned_store({ config = initial }, function(i18n, path)
			local accepted = i18n.persist_locale("en")
			return { accepted = accepted, active = i18n.get_locale(),
				config = read(require("infra.config_paths").config("config.toml")), stored = require("core.text.engine.json").decode(read(path)).locale }
		end)
		helpers.assert_eq(observed, { accepted = true, active = "en", config = '[script]\nlocale = "en"\n', stored = "en" })
	end)

	helpers.it("(locale-atomic) never creates an absent source", function()
		local observed = with_owned_store({}, function(i18n)
			local accepted = i18n.persist_locale("en")
			local file = io.open(require("infra.config_paths").config("config.toml"), "rb")
			if file then file:close() end
			return { accepted = accepted, absent = file == nil, active = i18n.get_locale() }
		end)
		helpers.assert_eq(observed, { accepted = true, absent = true, active = "en" })
	end)

	helpers.it("(locale-atomic) leaves an existing source without a locale row unchanged", function()
		local initial = '[script]\nlog_level = "INFO"\n'
		local observed = with_owned_store({ config = initial }, function(i18n)
			local accepted = i18n.persist_locale("en")
			return { accepted = accepted, config = read(require("infra.config_paths").config("config.toml")), active = i18n.get_locale() }
		end)
		helpers.assert_eq(observed, { accepted = true, config = initial, active = "en" })
	end)

	helpers.it("(locale-atomic) preserves a concurrent edit and compensates storage", function()
		local initial, concurrent = '[script]\nlocale = "fr"\n', '[script]\nlocale = "de"\n'
		local observed = with_owned_store({ config = initial, on_publish = function(path)
			local file = assert(io.open(path, "wb")); assert(file:write(concurrent)); assert(file:close())
		end }, function(i18n, path, seed)
			local accepted = i18n.persist_locale("en")
			return { accepted = accepted, active = i18n.get_locale(), config = read(require("infra.config_paths").config("config.toml")), storage = read(path) == seed }
		end)
		helpers.assert_eq(observed, { accepted = false, active = "fr", config = concurrent, storage = true })
	end)

	helpers.it("(locale-atomic) retains compensation debt until the storage owner can restore", function()
		local initial, published = '[script]\nlocale = "fr"\n', nil
		local once = true
		local observed = with_owned_store({ config = initial, after_publish = function(config, path)
			if not once then return end
			once = false
			published = read(path)
			local cf = assert(io.open(config, "wb")); assert(cf:write('[script]\nlocale = "de"\n')); assert(cf:close())
			local sf = assert(io.open(path, "wb")); assert(sf:write('{"locale":"es"}')); assert(sf:close())
		end }, function(i18n, path)
			local rejected = i18n.persist_locale("en")
			local pending = require("infra.scope_registry").pending()
			local sf = assert(io.open(path, "wb")); assert(sf:write(published)); assert(sf:close())
			local recovered = i18n.persist_locale("en")
			return { rejected = rejected, pending = pending, recovered = recovered,
				still_pending = require("infra.scope_registry").pending() }
		end)
		helpers.assert_eq(observed, { rejected = false, pending = true, recovered = true, still_pending = false })
	end)

	for _, code in ipairs({ "fr", "en" }) do
		for _, mode in ipairs({ "false", "throw" }) do
			helpers.it("(wizard-locale-ack) refuses " .. code .. " after an actual " .. mode .. " rename", function()
				local observed, attempts = with_owned_store({ rename = mode }, function(i18n, path, seed)
					local before = i18n.get_locale()
					local accepted = i18n.persist_locale(code)
					return { before = before, after = i18n.get_locale(), accepted = accepted,
						unchanged = read(path) == seed }
				end)
				helpers.assert_eq(observed, { before = "fr", after = "fr", accepted = false, unchanged = true })
				helpers.assert_eq(attempts, 1, "explicit selection reaches the actual private storage owner")
			end)
		end
	end

	for _, code in ipairs({ "fr", "en" }) do
		helpers.it("(wizard-locale-ack) reads back the acknowledged " .. code .. " selection", function()
			local observed, attempts = with_owned_store({}, function(i18n, path)
				local accepted = i18n.persist_locale(code)
				return { accepted = accepted, locale = i18n.get_locale(),
					stored = require("core.text.engine.json").decode(read(path)) }
			end)
			helpers.assert_true(observed.accepted)
			helpers.assert_eq(observed.locale, code)
			helpers.assert_eq(observed.stored, { locale = code, future = { retained = true } })
			helpers.assert_eq(attempts, 1)
		end)
	end

	helpers.it("(wizard-locale-ack) rejects invalid input before publication", function()
		local observed, attempts = with_owned_store({}, function(i18n, path, seed)
			local rejected = { i18n.persist_locale(nil), i18n.persist_locale(""),
				i18n.persist_locale("xx_NOT_SUPPORTED"), i18n.persist_locale(false) }
			return { rejected = rejected, locale = i18n.get_locale(), unchanged = read(path) == seed }
		end)
		helpers.assert_eq(observed, { rejected = { false, false, false, false }, locale = "fr", unchanged = true })
		helpers.assert_eq(attempts, 0)
	end)

	helpers.it("(wizard-locale-ack) leaves the ordinary same-locale menu setter unchanged", function()
		local observed, attempts = with_owned_store({ rename = "false" }, function(i18n, path, seed)
			return { accepted = i18n.set_locale("fr"), unchanged = read(path) == seed }
		end)
		helpers.assert_eq(observed, { accepted = true, unchanged = true })
		helpers.assert_eq(attempts, 0)
	end)
end)
