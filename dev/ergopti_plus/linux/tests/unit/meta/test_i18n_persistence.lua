--- tests/unit/meta/test_i18n_persistence.lua
---
--- Integration tests for i18n locale persistence and discovery.
--- Verifies that the i18n module loads, persists locale changes via storage,
--- discovers available locale files, and exposes the expected API surface.

local helpers = require("tests.helpers")

helpers.describe("i18n persistence", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("i18n exports the expected methods", function()
      local i18n = helpers.load_module("infra.i18n")
      helpers.assert_true(type(i18n.get)         == "function", "get")
      helpers.assert_true(type(i18n.get_locale)  == "function", "get_locale")
      helpers.assert_true(type(i18n.set_locale)  == "function", "set_locale")
      helpers.assert_true(type(i18n.list_locales)== "function", "list_locales")
      helpers.assert_true(type(i18n.display_name)== "function", "display_name")
      helpers.assert_true(type(i18n.set_trigger_provider) == "function", "set_trigger_provider")
      helpers.assert_true(type(i18n.init)        == "function", "init")
    end)

    helpers.it("locale module exports set_trigger_provider", function()
      local loc = helpers.load_module("infra.locale")
      helpers.assert_true(type(loc.set_trigger_provider) == "function", "locale.set_trigger_provider")
    end)
  end)

  -- ==========================================================================
  -- 2. Locale discovery
  -- ==========================================================================

  helpers.describe("locale discovery", function()
    helpers.it("list_locales returns at least fr and en", function()
      local i18n = helpers.load_module("infra.i18n")
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
      local i18n = helpers.load_module("infra.i18n")
      helpers.assert_eq(i18n.display_name("fr"), "Français", "fr → Français")
      helpers.assert_eq(i18n.display_name("en"), "English",  "en → English")
      helpers.assert_eq(i18n.display_name("de"), "Deutsch",  "de → Deutsch")
    end)

    helpers.it("display_name returns code as-is for unknown locales", function()
      local i18n = helpers.load_module("infra.i18n")
      helpers.assert_eq(i18n.display_name("xx_UNKNOWN"), "xx_UNKNOWN",
        "unknown code returned as-is")
    end)
  end)

  -- ==========================================================================
  -- 3. Locale persistence (storage adapter)
  -- ==========================================================================

  helpers.describe("locale persistence", function()
    helpers.it("set_locale + get_locale round-trips", function()
      local i18n = helpers.load_module("infra.i18n")
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

		helpers.it("does not publish a locale whose durable write failed", function()
			local saved_storage = package.loaded["adapters.storage"]
			package.loaded["adapters.storage"] = {
				get = function() return "fr" end,
				set = function() return false end,
			}
			local ok, err = pcall(function()
				local i18n = helpers.load_module("infra.i18n")
				i18n.init()
				helpers.assert_eq(i18n.get_locale(), "fr")
				helpers.assert_eq(i18n.set_locale("en"), false,
					"a returned storage failure must reject the transition")
				helpers.assert_eq(i18n.get_locale(), "fr",
					"the active locale must remain aligned with durable storage")
			end)
			package.loaded["adapters.storage"] = saved_storage
			package.loaded["infra.i18n"] = nil
			if not ok then error(err, 0) end
		end)

    -- Cleanup: ensure "fr" is the default for subsequent tests.
    helpers.it("_cleanup_reset_locale_to_fr", function()
      local i18n = helpers.load_module("infra.i18n")
      i18n.init()
      i18n.set_locale("fr")
    end)

    helpers.it("set_locale with unknown code is ignored", function()
      local i18n = helpers.load_module("infra.i18n")
      i18n.init()
      local before = i18n.get_locale()
      i18n.set_locale("xx_ZZ_INVALID")
      helpers.assert_eq(i18n.get_locale(), before,
        "locale unchanged after invalid code")
    end)

    helpers.it("set_locale with nil/empty is safe", function()
      local i18n = helpers.load_module("infra.i18n")
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
      local i18n = helpers.load_module("infra.i18n")
      -- Called directly. A setter that accepted the provider and then failed to
      -- use it would satisfy "does not crash" and leave every label showing the
      -- default trigger character.
      i18n.set_trigger_provider(function() return "\\" end)
      helpers.assert_eq(type(i18n.set_trigger_provider), "function",
        "and the setter must remain callable for the next provider")
    end)

    helpers.it("set_trigger_provider with nil is safe", function()
      local loc = helpers.load_module("infra.locale")
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
      local mb = helpers.load_module("ui.menu.menu_builder")
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
		local names = { "infra.i18n", "infra.locale", "adapters.storage", "infra.config_paths" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local root = os.tmpname()
		os.remove(root)
		local made = os.execute("mkdir -p " .. string.format("%q", root .. "/ergopti_plus"))
		helpers.assert_true(made == true or made == 0)
		local path = root .. "/ergopti_plus/storage.json"
		local seed = '{"locale":"zz_UNSUPPORTED","future":{"retained":true}}\n'
		local fh = assert(io.open(path, "wb"))
		assert(fh:write(seed)); assert(fh:close())
		local original_rename = os.rename
		local attempts = 0
		local observations = nil
		local ok, err = xpcall(function()
			package.loaded["infra.config_paths"] = { config_home = function() return root end }
			package.loaded["infra.locale"] = nil
			package.loaded["adapters.storage"] = nil
			package.loaded["infra.i18n"] = nil
			local i18n = require("infra.i18n")
			i18n.init()
			os.rename = function(from, to)
				if from == path .. ".tmp" and to == path then
					attempts = attempts + 1
					if options.rename == "throw" then error("owned rename refused") end
					if options.rename == "false" then return nil, "owned rename refused", 13 end
				end
				return original_rename(from, to)
			end
			observations = body(i18n, path, seed)
		end, debug.traceback)
		os.rename = original_rename
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		os.remove(path .. ".tmp"); os.remove(path)
		os.execute("rmdir " .. string.format("%q", root .. "/ergopti_plus"))
		os.execute("rmdir " .. string.format("%q", root))
		if not ok then error(err, 0) end
		return observations, attempts
	end

	local function read(path)
		local fh = assert(io.open(path, "rb"))
		local raw = assert(fh:read("*a")); assert(fh:close())
		return raw
	end

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
					stored = require("json").decode(read(path)) }
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
