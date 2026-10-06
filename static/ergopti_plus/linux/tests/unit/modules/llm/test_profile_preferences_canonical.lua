--- tests/unit/modules/llm/test_profile_preferences_canonical.lua

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Toml = require("toml_codec")
local Json = require("json")
local Base64 = require("compat.base64")

local function with_config(source, body)
	Sandbox.with_config(source, function(path)
		local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.profile_settings", "adapters.storage" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = require("tests.fakes").storage({ initial = {
				["llm.profiles.active"] = "raw", ["llm.profiles.num_predictions"] = 9,
			} })
			body(require("modules.llm.profile_settings"), path)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

local function profile()
	return { id = "user_canonical", label = "Canonical", system_single = "Continue {context}", batch = false }
end

helpers.describe("canonical Linux prompt profiles", function()
	helpers.it("keeps empty stop arrays typed while preserving object and null entries", function()
		local raw = '[{"id":"user_array","label":"Array","system_single":"Continue","batch":false,"stop_sequences":[]},'
			.. '{"id":"user_object","label":"Object","system_single":"Continue","batch":false,"stop_sequences":{}},'
			.. '{"id":"user_null","label":"Null","system_single":"Continue","batch":false,"stop_sequences":null}]'
		with_config('[llm]\nuser_profiles = "v1:' .. Base64.encode(raw) .. '"\n', function(settings, path)
			helpers.assert_eq(#settings.list_user(), 1)
			helpers.assert_true(Json.is_array(settings.list_user()[1].stop_sequences))
			local added = profile(); added.id = "user_second"
			helpers.assert_true(settings.save_user_profile(added, false, false))
			local stored = require("modules.llm.profile_registry_codec").decode(Toml.decode(Sandbox.read_bytes(path)).llm.user_profiles)
			helpers.assert_true(Json.is_array(stored[1].stop_sequences))
			helpers.assert_eq(Json.is_array(stored[3].stop_sequences), false)
			helpers.assert_eq(Json.is_null(stored[3].stop_sequences), false)
			helpers.assert_true(Json.is_null(stored[4].stop_sequences))
		end)
	end)

	helpers.it("refuses a stale deletion without resetting an externally selected profile", function()
		local first, second = profile(), profile(); second.id = "user_external"
		local initial = "v1:" .. Base64.encode(Json.encode({ first }))
		with_config('[llm]\nuser_profiles = "' .. initial .. '"\n[llm.profiles]\nactive = "' .. first.id .. '"\n', function(settings, path)
			helpers.assert_eq(settings.get("active"), first.id)
			local external = '[llm]\nuser_profiles = "v1:' .. Base64.encode(Json.encode({ first, second }))
				.. '"\n[llm.profiles]\nactive = "' .. second.id .. '"\n'
			Sandbox.write_bytes(path, external)
			helpers.assert_eq(settings.delete_user_profile(first.id), false)
			helpers.assert_eq(Sandbox.read_bytes(path), external)
			helpers.assert_true(settings.delete_user_profile(first.id))
			helpers.assert_eq(settings.get("active"), second.id)
			helpers.assert_eq(settings.list_user()[1].id, second.id)
		end)
	end)

	helpers.it("refuses a cached registry after an external edit and admits a fresh retry", function()
		local first, second = profile(), profile()
		second.id = "user_external"
		local initial = "v1:" .. Base64.encode(Json.encode({ first }))
		with_config('[llm]\nuser_profiles = "' .. initial .. '"\n[llm.profiles]\nactive = "' .. first.id .. '"\n', function(settings, path)
			helpers.assert_eq(#settings.list_user(), 1)
			helpers.assert_eq(settings.get("active"), first.id)
			local external = '[llm]\nuser_profiles = "v1:' .. Base64.encode(Json.encode({ first, second }))
				.. '"\n[llm.profiles]\nactive = "' .. second.id .. '"\n'
			Sandbox.write_bytes(path, external)
			local added = profile(); added.id = "user_third"
			helpers.assert_eq(settings.save_user_profile(added, false, false), false)
			helpers.assert_eq(Sandbox.read_bytes(path), external)
			helpers.assert_true(settings.save_user_profile(added, false, false))
			helpers.assert_eq(#settings.list_user(), 3)
			helpers.assert_eq(settings.get("active"), second.id)
		end)
	end)

	helpers.it("preserves explicit wrong-type optional profile fields as opaque entries", function()
		local first, second = profile(), profile()
		first.system_multi = false
		second.id = "user_wrong_template"; second.system_multi_template = { future = 1 }
		local payload = "v1:" .. Base64.encode(Json.encode({ first, second }))
		with_config('[llm]\nuser_profiles = "' .. payload .. '"\n', function(settings, path)
			helpers.assert_eq(#settings.list_user(), 0)
			local added = profile(); added.id = "user_valid"
			helpers.assert_true(settings.save_user_profile(added, false, false))
			local stored = require("modules.llm.profile_registry_codec").decode(Toml.decode(Sandbox.read_bytes(path)).llm.user_profiles)
			helpers.assert_eq(stored[2].system_multi, false)
			helpers.assert_eq(stored[3].system_multi_template, { future = 1 })
		end)
	end)

	helpers.it("refuses sparse registries and sparse profile stop sequences", function()
		local codec = require("modules.llm.profile_registry_codec")
		local sparse = { profile(), profile(), profile() }
		sparse[2] = nil
		local failure = helpers.assert_throws(function() codec.encode(sparse) end)
		helpers.assert_contains(failure, "user profile registry must")
		with_config('[llm]\nfuture = "keep"\n', function(settings, path)
			local item = profile()
			item.stop_sequences = { "FIRST", "SECOND", "THIRD" }
			item.stop_sequences[2] = nil
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq(settings.save_user_profile(item, true, false), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
		end)
	end)

	helpers.it("uses strict canonical base64 for the versioned envelope", function()
		for _, pair in ipairs({ { "", "" }, { "f", "Zg==" }, { "fo", "Zm8=" }, { "foo", "Zm9v" },
			{ "foob", "Zm9vYg==" }, { "fooba", "Zm9vYmE=" }, { "foobar", "Zm9vYmFy" } }) do
			helpers.assert_eq(Base64.encode(pair[1]), pair[2])
			helpers.assert_eq(Base64.decode(pair[2]), pair[1])
		end
		for _, invalid in ipairs({ "Zg", "Zg=", "Zg===", "Zg==AAAA", "Zg=Z", "Zh==", "Zm9=", " Zg==", "!!!!", "====" }) do
			helpers.assert_nil(Base64.decode(invalid), invalid)
		end
		local codec = require("modules.llm.profile_registry_codec")
		for _, row in ipairs({
			{ "v2:W10=", "unknown user profile registry version" },
			{ "v1:e30=", "user profile JSON must be an array" },
			{ "v1:bnVsbA==", "user profile JSON must be an array" },
			{ "v1:Ww==", "user profile registry must be an array" },
		}) do
			local failure = helpers.assert_throws(function() codec.decode(row[1]) end, row[1])
			helpers.assert_contains(failure, row[2])
		end
	end)

	helpers.it("reads an older build's registry as no user profile, warns and offers it (config-outdated-llm-profiles)", function()
		local source = "[llm]\nuser_profiles = '[{\"id\":\"user_old\"}]'\n[llm.profiles]\nactive = \"basic\"\n"
		with_config(source, function(settings)
			require("config_outdated").reset_for_tests()
			local reported = require("config_outdated").collect_reports(function()
				helpers.assert_eq(settings.get("active"), "basic", "the menu and typing paths never raise")
				helpers.assert_eq(settings.list_user(), {})
			end)
			helpers.assert_eq(reported, { ["llm.user_profiles"] = true })
		end)
		local scan = require("config_unused_keys").find_in_source(source, require("ui.menu.unused_keys_cleanup").collect)
		helpers.assert_eq(#scan.keys, 1, "the cleanup offers the registry the reader ignores")
		helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key }, { "llm", "user_profiles" })
	end)

	for _, stored in ipairs({ "user_profiles = '[{\"id\":\"user_old\"}]'", "user_profiles = [\"user_old\"]" }) do
		helpers.it("never overwrites an older build's registry: " .. stored .. " (config-outdated-llm-profiles-write)",
			function()
				-- Read as no user profile, it was replaced by the next save or delete,
				-- erasing every prompt the user had written.
				local source = "[llm]\n" .. stored .. "\n"
				with_config(source, function(settings, path)
					local Logger = require("logger.shim")
					local real_error, errors = Logger.error, {}
					Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
					local ok, err = pcall(function()
						helpers.assert_eq(settings.list_user(), {})
						helpers.assert_eq(settings.save_user_profile(profile(), true, false), false)
						helpers.assert_eq(settings.delete_user_profile("user_old"), false)
						helpers.assert_eq(Sandbox.read_bytes(path), source, "the old registry is left byte for byte")
						helpers.assert_eq(#errors, 2, "each refused write is one named ERROR: " .. table.concat(errors, " | "))
						for _, line in ipairs(errors) do helpers.assert_contains(line, "llm.user_profiles") end
					end)
					Logger.error = real_error
					if not ok then error(err, 0) end
				end)
			end)
	end

	helpers.it("warns once, never an ERROR, about a stored profile it cannot offer (config-outdated-llm-profiles)", function()
		local stale = profile(); stale.id = "user_stale"; stale.retired_field = 1
		local registry = "v1:" .. Base64.encode(Json.encode({ profile(), stale }))
		with_config('[llm]\nuser_profiles = "' .. registry .. '"\n', function(settings, path)
			local Logger = require("logger.shim")
			local real_error, real_warn, errors, warnings = Logger.error, Logger.warn, {}, {}
			Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			local ok, err = pcall(function()
				helpers.assert_eq(#settings.list_user(), 1, "the readable profile is still offered")
				settings.reload_configuration()
				helpers.assert_eq(#settings.list_user(), 1)
				helpers.assert_eq(errors, {}, "an outdated stored profile is never an ERROR")
				helpers.assert_eq(#warnings, 1, "named once however often the registry is read")
				helpers.assert_contains(warnings[1], "index 2")
				local added = profile(); added.id = "user_added"
				helpers.assert_true(settings.save_user_profile(added, false, false))
				local stored = require("modules.llm.profile_registry_codec").decode(Toml.decode(Sandbox.read_bytes(path)).llm.user_profiles)
				helpers.assert_eq(stored[#stored].retired_field, 1, "the outdated profile is kept on write")
			end)
			Logger.error, Logger.warn = real_error, real_warn
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("reads declared canonical choices without importing legacy storage", function()
		with_config('[llm.profiles]\nactive = "basic"\nnum_predictions = 5\nauto_profile_for_model = false\n', function(settings)
			helpers.assert_eq(settings.get("active"), "basic")
			helpers.assert_eq(settings.get("num_predictions"), 5)
			helpers.assert_eq(settings.get("auto_profile_for_model"), false)
		end)
	end)

	helpers.it("persists a profile and its active identity together and reloads exact Unicode", function()
		with_config('[llm]\nfuture = "keep"\n', function(settings, path)
			local item = profile()
			item.label = "Écriture 日本語"
			item.system_multi = "Multi"
			item.raw_prompt = "Raw"
			item.stop_sequences = { "STOP", "END" }
			helpers.assert_true(settings.save_user_profile(item, true, false))
			local stored = Toml.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(stored.llm.future, "keep")
			helpers.assert_eq(stored.llm.profiles.active, item.id)
			helpers.assert_eq(stored.llm.profiles.auto_profile_for_model, false)
			helpers.assert_eq(stored.llm.user_profiles:sub(1, 3), "v1:")
			package.loaded["modules.llm.profile_settings"] = nil
			local fresh = require("modules.llm.profile_settings")
			helpers.assert_eq(fresh.list_user()[1].label, item.label)
			helpers.assert_eq(fresh.list_user()[1].system_multi, "Multi")
			helpers.assert_eq(fresh.list_user()[1].raw_prompt, "Raw")
			local detached = fresh.list_user()[1]
			detached.stop_sequences[1] = "foreign edit"
			helpers.assert_eq(fresh.list_user()[1].stop_sequences, item.stop_sequences)
			helpers.assert_eq(fresh.get("active"), item.id)
			helpers.assert_true(fresh.delete_user_profile(item.id))
			local cleared = Toml.decode(Sandbox.read_bytes(path))
			helpers.assert_nil(cleared.llm.user_profiles)
			helpers.assert_nil(cleared.llm.profiles.active)
		end)
	end)

	helpers.it("reads the versioned Windows JSON envelope and preserves unreadable entries", function()
		local good, broken = profile(), { id = "user_broken", label = "", batch = "invalid" }
		local payload = "v1:" .. Base64.encode(Json.encode({ good, broken }))
		with_config('[llm]\nuser_profiles = "' .. payload .. '"\n', function(settings, path)
			helpers.assert_eq(#settings.list_user(), 1)
			local another = profile(); another.id = "user_second"
			helpers.assert_true(settings.save_user_profile(another, false, false))
			local stored = require("modules.llm.profile_registry_codec").decode(Toml.decode(Sandbox.read_bytes(path)).llm.user_profiles)
			helpers.assert_eq(#stored, 3)
			helpers.assert_eq(stored[3], broken)
		end)
	end)

	helpers.it("refuses a corrupt registry repeatedly without caching an empty replacement", function()
		with_config('[llm]\nuser_profiles = "v1:not-base64"\n', function(settings, path)
			local before = Sandbox.read_bytes(path)
			for _ = 1, 2 do
				local failure = helpers.assert_throws(settings.list_user)
				helpers.assert_contains(failure, "invalid user profile base64 envelope")
			end
			local failure = helpers.assert_throws(function() settings.save_user_profile(profile(), true, false) end)
			helpers.assert_contains(failure, "invalid user profile base64 envelope")
			helpers.assert_eq(Sandbox.read_bytes(path), before)
		end)
	end)

	helpers.it("cleanup retains profile choices and the versioned registry", function()
		local payload = "v1:" .. Base64.encode(Json.encode({ profile() }))
		with_config('[llm]\nuser_profiles = "' .. payload .. '"\n[llm.profiles]\nnum_predictions = 5\nfuture = 42\n', function(_, path)
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(scan.status, "ok")
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].key, "future")
		end)
	end)

	helpers.it("publishes no registry or active identity when exact-source publication refuses", function()
		with_config('[llm.profiles]\nactive = "raw"\n', function(settings, path)
			local writer = require("toml_codec.writer")
			local original = writer.batch_write
			local before, called = Sandbox.read_bytes(path), false
			writer.batch_write = function() called = true; return false, "fixture refusal" end
			local ok, err = pcall(function()
				helpers.assert_eq(settings.save_user_profile(profile(), true, false), false)
				helpers.assert_true(called)
				helpers.assert_eq(#settings.list_user(), 0)
				helpers.assert_eq(settings.get("active"), "raw")
				helpers.assert_eq(Sandbox.read_bytes(path), before)
			end)
			writer.batch_write = original
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("preserves an external edit arriving after its registry candidate was read", function()
		with_config('[llm.profiles]\nactive = "raw"\n', function(settings, path)
			local writer = require("toml_codec.writer")
			local original = writer.batch_write
			local changed = Sandbox.read_bytes(path) .. '# external owner\n'
			writer.batch_write = function(...)
				Sandbox.write_bytes(path, changed)
				return original(...)
			end
			local ok, err = pcall(function()
				helpers.assert_eq(settings.save_user_profile(profile(), true, false), false)
				helpers.assert_eq(#settings.list_user(), 0)
				helpers.assert_eq(settings.get("active"), "raw")
				helpers.assert_eq(Sandbox.read_bytes(path), changed)
			end)
			writer.batch_write = original
			if not ok then error(err, 0) end
		end)
	end)
end)

-- Actual canonical files and native profile transactions remain the callback owners.
helpers.describe("shared custom profile child: canonical Linux native owner", function()
	local function shared(relative)
		return helpers.driver_root():gsub("/linux$", "/_shared/") .. relative
	end
	local function read_json(relative)
		local f = assert(io.open(shared(relative), "rb")); local raw = f:read("*a"); f:close()
		return Json.decode(raw)
	end
	local expected = read_json("tests/corpus/menus/custom_profile_children.json")
	local function with_child(body)
		local initial = '[llm]\nfuture = "keep"\nuser_profiles = "v1:' .. Base64.encode(Json.encode({ profile() }))
			.. '"\n[llm.profiles]\nactive = "basic"\nauto_profile_for_model = false\n'
		with_config(initial, function(settings, path)
			local names = { "infra.manifest_menu", "ui.menu.menu_builder", "ui.prompt_editor.bridge" }
			local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local ok, err = pcall(function()
				local document = read_json("modules/menu/menu_manifest.json")
				local translator = { get = function(key) return key end }
				local native_translator = require("infra.i18n")
				translator.locale = native_translator.locale
				translator.section = native_translator.section
				local renderer = assert(require("menu.renderer").new({ platform = "linux",
					manifest_path = function() return shared("modules/menu/menu_manifest.json") end,
					json_decode = function() return document end, i18n = translator, logger = require("logger.shim"),
				}))
				package.loaded["infra.manifest_menu"] = renderer
				local opened, editor_calls, rebuilds, confirmations = nil, 0, 0, 0
				local accepted, confirmed = true, true
				package.loaded["ui.prompt_editor.bridge"] = { open = function(existing, on_save, opts)
					editor_calls = editor_calls + 1; opened = {existing=existing,on_save=on_save,opts=opts}; return accepted
				end }
				local ctx = { is_paused = function() return false end, llm = {
					is_enabled = function() return true end, get_models = function() return {} end,
					get_current_model = function() return "small" end, get_prediction_model = function() return "small" end,
				}, on_menu_changed = function() rebuilds = rebuilds + 1 end,
				confirm_profile_delete = function(id, label)
					confirmations = confirmations + 1
					helpers.assert_eq({id,label}, {"user_canonical","Canonical"}); return confirmed
				end }
				local builder = helpers.load_module("ui.menu.menu_builder")
				local function find(rows)
					for _, row in ipairs(rows or {}) do
						if row.title == "Canonical" then return row.menu or {} end
						local nested = find(row.menu); if nested then return nested end
					end
				end
				local function child() return assert(find(builder.build(ctx)), "actual native parent missing") end
				body({settings=settings,path=path,initial=initial,document=document,child=child,ctx=ctx,i18n=translator,
					opened=function() return opened end, counts=function() return {rebuilds,editor_calls,confirmations} end,
					accept=function(value) accepted=value end, confirm=function(value) confirmed=value end})
			end)
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			if not ok then error(err, 0) end
		end)
	end
	local function captions(rows)
		local result = {}; for _, row in ipairs(rows) do result[#result+1]=row.title end; return result
	end
	helpers.it("custom-profile-child: canonical Use persists, refreshes and supplies the fresh checkbox", function()
		with_child(function(f)
			helpers.assert_eq(f.document[expected.section], expected.declaration)
			helpers.assert_eq(captions(f.child()), {"menu.profiles.use_profile","menu.profiles.edit_profile","menu.profiles.delete_profile"})
			helpers.assert_eq(f.child()[1].checked, false)
			helpers.assert_eq(f.child()[1].fn(), true)
			helpers.assert_eq(f.settings.get("active"), "user_canonical")
			helpers.assert_eq(f.child()[1].checked, true)
			helpers.assert_eq(Toml.decode(Sandbox.read_bytes(f.path)).llm.future, "keep")
			helpers.assert_eq(f.counts(), {1,0,0})
		end)
	end)
	helpers.it("custom-profile-child: native Edit refuses and retries its real canonical save", function()
		with_child(function(f)
			f.accept(false); helpers.assert_eq(f.child()[2].fn(), false)
			f.accept(true); helpers.assert_eq(f.child()[2].fn(), true)
			helpers.assert_eq(f.opened().existing.id, "user_canonical")
			local successor = f.initial:gsub('future = "keep"', 'future = "successor"')
			Sandbox.write_bytes(f.path, successor)
			local edited = profile(); edited.label = "Edited"
			helpers.assert_eq(f.opened().on_save(edited), false)
			helpers.assert_eq(Sandbox.read_bytes(f.path), successor)
			helpers.assert_eq(f.counts(), {0,2,0})
			helpers.assert_eq(f.opened().on_save(edited), true)
			helpers.assert_eq(f.settings.list_user()[1].label, "Edited")
			helpers.assert_eq(Toml.decode(Sandbox.read_bytes(f.path)).llm.future, "successor")
			helpers.assert_eq(f.counts(), {1,2,0})
		end)
	end)
	helpers.it("custom-profile-child: native Delete cancellation, stale refusal and fresh retry preserve source", function()
		with_child(function(f)
			local held = f.child()[3]; f.confirm(false)
			helpers.assert_eq(held.fn(), false); helpers.assert_eq(Sandbox.read_bytes(f.path), f.initial)
			f.confirm(true)
			local successor = f.initial:gsub('future = "keep"', 'future = "successor"')
			Sandbox.write_bytes(f.path, successor)
			helpers.assert_eq(held.fn(), false); helpers.assert_eq(Sandbox.read_bytes(f.path), successor)
			helpers.assert_eq(f.counts(), {0,0,2})
			helpers.assert_eq(held.fn(), true); helpers.assert_eq(f.settings.list_user(), {})
			helpers.assert_eq(Toml.decode(Sandbox.read_bytes(f.path)).llm.future, "successor")
			helpers.assert_eq(f.counts(), {1,0,3})
		end)
	end)
	helpers.it("custom-profile-child: actual native child follows shared order and caption", function()
		with_child(function(f)
			local records=f.document[expected.section]; records[1].i18n="button.cancel"
			records[4],records[5]=records[5],records[4]
			helpers.assert_eq(captions(f.child()), {"button.cancel","menu.profiles.delete_profile","menu.profiles.edit_profile"})
			helpers.assert_eq(f.child()[1].fn(), true); helpers.assert_eq(f.settings.get("active"),"user_canonical")
		end)
	end)
	for _, mutation in ipairs({"missing", "wrong command", "hidden"}) do
		helpers.it("custom-profile-child: Linux refuses actual publication " .. mutation, function()
			with_child(function(f)
				if mutation=="missing" then f.document[expected.section]=nil
				elseif mutation=="wrong command" then f.document[expected.section][1].id="absent_profile_owner"
				else for _, row in ipairs(f.document[expected.section]) do row.platforms={"hs"} end end
				helpers.assert_eq(f.child(),{}); helpers.assert_eq(f.counts(),{0,0,0})
				helpers.assert_eq(Sandbox.read_bytes(f.path),f.initial)
			end)
		end)
	end
	helpers.it("custom-profile-child: held leaves refuse withdrawn source without native effects", function()
		with_child(function(f)
			local held=f.child(); f.document[expected.section]=nil
			for _,row in ipairs(held) do helpers.assert_eq(row.fn(),false) end
			helpers.assert_eq(f.counts(),{0,0,0}); helpers.assert_eq(Sandbox.read_bytes(f.path),f.initial)
		end)
	end)
	for _, mutation in ipairs({"missing", "throw", "removed", "duplicate"}) do
		helpers.it("custom-profile-child: held leaves refuse current registry " .. mutation, function()
			with_child(function(f)
				local held=f.child(); local original=f.settings.list_user
				if mutation=="missing" then f.settings.list_user=nil
				elseif mutation=="throw" then f.settings.list_user=function() error("registry refused") end
				elseif mutation=="removed" then f.settings.list_user=function() return {} end
				else f.settings.list_user=function() return {profile(),profile()} end end
				local ok,err=pcall(function()
					for _,row in ipairs(held) do helpers.assert_eq(row.fn(),false) end
					helpers.assert_eq(f.counts(),{0,0,0}); helpers.assert_eq(Sandbox.read_bytes(f.path),f.initial)
				end)
				f.settings.list_user=original; if not ok then error(err,0) end
			end)
		end)
	end
	helpers.it("custom-profile-child: Linux retains configuration access while paused", function()
		with_child(function(f)
			local held=f.child(); f.ctx.paused=true; f.ctx.is_paused=function() return true end
			helpers.assert_eq(held[2].fn(),true); helpers.assert_eq(f.counts(),{0,1,0})
		end)
	end)
	helpers.it("custom-profile-child: all 21 existing Linux captions are consumed without Mac shortcut", function()
		with_child(function(f)
			local languages=read_json("data/locale_order.json").order
			helpers.assert_eq(#languages,21)
			for _,language in ipairs(languages) do
				local values=read_json("data/locales/"..language..".json")
				f.i18n.get=function(key) return values[key] or key end
				helpers.assert_eq(captions(f.child()), {values["menu.profiles.use_profile"],values["menu.profiles.edit_profile"],values["menu.profiles.delete_profile"]},language)
			end
		end)
	end)
end)

-- Canonical configuration and native choices remain the production owners.
helpers.describe("shared profile section headings: actual canonical Linux provider", function()
	local function shared(relative) return helpers.driver_root():gsub("/linux$", "/_shared/") .. relative end
	local function read_json(relative)
		local file=assert(io.open(shared(relative),"rb"));local raw=file:read("*a");file:close();return Json.decode(raw)
	end
	local expected = read_json("tests/corpus/menus/profile_section_headings.json")
	local function with_headings(custom, body)
		local initial='[llm]\nfuture = "keep"\nuser_profiles = "v1:' .. Base64.encode(Json.encode(custom and {profile()} or Json.array({})))
			.. '"\n[llm.profiles]\nactive = "basic"\nauto_profile_for_model = false\n'
		with_config(initial,function(settings,path)
			local names={"infra.manifest_menu","infra.i18n","ui.menu.menu_builder"}
			local saved={};for _,name in ipairs(names) do saved[name]=package.loaded[name] end
			local ok,err=xpcall(function()
				local document=read_json("modules/menu/menu_manifest.json")
				local native_i18n=require("infra.i18n")
				local i18n=setmetatable({get=function(key) return key end}, {__index=native_i18n})
				package.loaded["infra.i18n"]=i18n
				local renderer=assert(require("menu.renderer").new({platform="linux",
					manifest_path=function() return shared("modules/menu/menu_manifest.json") end,
					json_decode=function() return document end,i18n=i18n,logger=require("logger.shim")}))
				package.loaded["infra.manifest_menu"]=renderer
				local redraws=0
				local ctx={is_paused=function() return false end,llm={is_enabled=function() return true end,
					get_models=function() return {} end,get_current_model=function() return "small" end,
					get_prediction_model=function() return "small" end},on_menu_changed=function() redraws=redraws+1 end}
				local builder=helpers.load_module("ui.menu.menu_builder")
				local function find(rows)
					for _,row in ipairs(rows or {}) do
						if row.menu then
							for _,child in ipairs(row.menu) do if child.title==i18n.get("menu.profiles.auto_detect") then return row.menu end end
							local result=find(row.menu);if result then return result end
						end
					end
				end
				body({document=document,i18n=i18n,heading_index=2,other_platform="hs",
					caption=function(key) return i18n.get(key) end,decorate=function(value) return value end,
					rows=function() return assert(find(builder.build(ctx)),"actual profile parent missing") end,
					untouched=function() helpers.assert_eq(Sandbox.read_bytes(path),initial);helpers.assert_eq(redraws,0) end,
					settings=settings,path=path,ctx=ctx,redraws=function() return redraws end})
			end,debug.traceback)
			for _,name in ipairs(names) do package.loaded[name]=saved[name] end
			if not ok then error(err,0) end
		end)
	end

	local function titles(rows)
		local result = {}
		for _, row in ipairs(rows) do result[#result + 1] = row.title end
		return result
	end
	local function position(rows, title)
		for index, row in ipairs(rows) do if row.title == title then return index, row end end
	end
	local sections = { "llm_profile_builtin_heading", "llm_profile_custom_heading" }
	helpers.it("profile-headings: handwritten shared declaration exactly matches the independent oracle", function()
		with_headings(true, function(f)
			for _, section in ipairs(sections) do helpers.assert_eq(f.document[section], expected.sections[section]) end
			local rows = f.rows()
			local builtin, builtin_row = position(rows, f.caption(expected.keys[1]))
			local custom, custom_row = position(rows, f.caption(expected.keys[2]))
			helpers.assert_type(builtin, "number"); helpers.assert_type(custom, "number")
			helpers.assert_true(builtin < custom)
			helpers.assert_true(builtin_row.disabled); helpers.assert_nil(builtin_row.fn)
			helpers.assert_true(custom_row.disabled); helpers.assert_nil(custom_row.fn)
			helpers.assert_eq(rows[custom - 1].title, "-")
			helpers.assert_eq(rows[custom + 1].title, "Canonical")
			f.untouched()
		end)
	end)
	helpers.it("profile-headings: empty native registry has no custom heading or custom separator", function()
		with_headings(false, function(f)
			local rows = f.rows()
			helpers.assert_not_nil(position(rows, f.caption(expected.keys[1])))
			helpers.assert_nil(position(rows, f.caption(expected.keys[2])))
			local before = titles(rows)
			f.document[sections[2]] = { {type="label",id="empty_registry_probe",i18n="button.cancel"} }
			helpers.assert_eq(titles(f.rows()), before, "custom presentation is conditional on the actual native registry")
			f.untouched()
		end)
	end)
	helpers.it("profile-headings: actual native menu consumes changed caption and shared custom source order", function()
		with_headings(true, function(f)
			local custom = f.document[sections[2]]
			local heading = custom[f.heading_index]
			heading.i18n = "button.cancel"
			custom[1], custom[f.heading_index] = heading, custom[1]
			local rows = f.rows()
			local index = position(rows, f.caption("button.cancel"))
			helpers.assert_type(index, "number")
			helpers.assert_eq(rows[index + 1].title, "-")
			helpers.assert_eq(rows[index + 2].title, "Canonical")
			helpers.assert_nil(position(rows, f.caption(expected.keys[2])))
			f.untouched()
		end)
	end)
	for _, mutation in ipairs({"missing", "empty", "invalid caption", "hidden platform"}) do
		helpers.it("profile-headings: no native fallback repairs " .. mutation .. " declaration", function()
			with_headings(true, function(f)
				for _, section in ipairs(sections) do
					if mutation == "missing" then f.document[section] = nil
					elseif mutation == "empty" then f.document[section] = {}
					elseif mutation == "invalid caption" then
						for _, row in ipairs(f.document[section]) do if row.i18n then row.i18n = false end end
					else for _, row in ipairs(f.document[section]) do row.platforms = {f.other_platform} end end
				end
				local rows = f.rows()
				helpers.assert_nil(position(rows, f.caption(expected.keys[1])))
				helpers.assert_nil(position(rows, f.caption(expected.keys[2])))
				helpers.assert_not_nil(position(rows, "Canonical"), "native data rows must survive absent presentation")
				f.untouched()
			end)
		end)
	end
	helpers.it("profile-headings: all 21 original caption pairs keep the platform decoration", function()
		with_headings(true, function(f)
			local count = 0
			for language, pair in pairs(expected.captions) do
				count = count + 1
				local values = read_json("data/locales/" .. language .. ".json")
				helpers.assert_eq({values[expected.keys[1]], values[expected.keys[2]]}, pair, language)
				f.i18n.get = function(key) return values[key] or key end
				local rows = f.rows()
				helpers.assert_not_nil(position(rows, f.decorate(pair[1])), language)
				helpers.assert_not_nil(position(rows, f.decorate(pair[2])), language)
			end
			helpers.assert_eq(count, 21)
			f.untouched()
		end)
	end)

	helpers.it("profile-headings: withdrawing inert declarations keeps native automatic-profile persistence", function()
		with_headings(true,function(f)
			local _, held=position(f.rows(),"menu.profiles.auto_detect")
			for _,section in ipairs(sections) do f.document[section]=nil end
			helpers.assert_eq(held.fn(),true)
			helpers.assert_eq(f.settings.get("auto_profile_for_model"),true)
			helpers.assert_eq(Toml.decode(Sandbox.read_bytes(f.path)).llm.future,"keep")
			helpers.assert_eq(f.redraws(),1)
		end)
	end)
	helpers.it("profile-headings: current native pause still refuses held automatic-profile publication", function()
		with_headings(true,function(f)
			local _,held=position(f.rows(),"menu.profiles.auto_detect")
			f.ctx.is_paused=function() return true end
			helpers.assert_eq(held.fn(),false)
			f.untouched()
		end)
	end)
end)


helpers.describe("ordered child template native list and conditional include contract", function()
	local function with_frame(body)
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_template_api.json"
		local Menu = assert(require("menu.renderer").new({
			platform = "linux",
			manifest_path = function() return path end,
			json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end },
			logger = helpers.make_logger_stub(),
		}))
		local handle = assert(io.open(path, "rb"))
		local oracle = require("json").decode(handle:read("*a")); handle:close()
		local state = { ready = true, present = true, calls = 0, phases = {} }
		local function native_action() state.calls = state.calls + 1; return false end
		local builtin = { label = "Builtin native", checked = true, action = native_action }
		local custom = { label = "Custom native", items = { { label = "Native child", action = native_action } } }
		local getters = {
			ready = function() return state.ready end,
			custom_present = function() state.phases[#state.phases + 1] = "custom_present"; return state.present end,
		}
		local children = {
			builtins = function(...) helpers.assert_eq(select("#", ...), 0); state.phases[#state.phases + 1] = "builtins"; return { builtin } end,
			customs = function(...) helpers.assert_eq(select("#", ...), 0); state.phases[#state.phases + 1] = "customs"; return { custom } end,
		}
		body(Menu, { create = native_action, clone = native_action }, getters, children, state, oracle._expected, builtin, custom)
	end
	local function shape(rows)
		local labels = {}
		for _, row in ipairs(rows) do labels[#labels + 1] = row.separator and "---" or row.label end
		return table.concat(labels, "|")
	end
	helpers.it("splices real canonical data lazily at declaration positions and selects exact command order", function()
		with_frame(function(Menu, commands, getters, children, state, expected, builtin, custom)
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(shape(rows), table.concat(expected.present, "|"))
			helpers.assert_eq(table.concat(state.phases, "|"), table.concat(expected.phases, "|"))
			helpers.assert_true(rawequal(rows[2], builtin))
			helpers.assert_true(rawequal(rows[5], custom))
			helpers.assert_true(rawequal(rows[5].items, custom.items))
			local rendered = Menu.render_rows(rows, "frame")
			helpers.assert_eq(rendered[2].checked, true)
			helpers.assert_eq(rendered[5].menu[1].fn(), false)
			helpers.assert_eq(state.calls, 1)
			helpers.assert_eq(rows[6].action(), false)
			helpers.assert_eq(state.calls, 2)
			state.ready = false
			helpers.assert_eq(rows[6].action(), false)
			helpers.assert_eq(state.calls, 2, "existing command readiness remains live")
			state.ready = true
			Menu.get_array("commands")[2].id = "withdrawn"
			helpers.assert_eq(rows[6].action(), false)
			helpers.assert_eq(state.calls, 2, "selected command declaration withdrawal is effect free")
		end)
	end)
	helpers.it("a false presence getter skips the whole fragment without calling its native list", function()
		with_frame(function(Menu, commands, getters, children, state, expected)
			state.present = false
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(shape(rows), table.concat(expected.absent, "|"))
			helpers.assert_eq(table.concat(state.phases, "|"), "builtins|custom_present")
			helpers.assert_eq(state.calls, 0)
		end)
	end)
	helpers.it("empty native lists remain valid and legacy whole-section includes retain their order", function()
		with_frame(function(Menu, commands, getters, children)
			children.builtins, children.customs = function() return {} end, function() return {} end
			Menu.get_array("frame")[4].row_id = nil
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(shape(rows), "menu.profiles.header_default_profiles|---|menu.profiles.header_custom_profiles|menu.profiles.create_profile|menu.profiles.clone_builtin|---|menu.profiles.create_profile")
		end)
	end)
	helpers.it("platform filtering hides a selected original command without invoking another command", function()
		with_frame(function(Menu, commands, getters, children, state)
			Menu.get_array("commands")[2].platforms = { "hs" }
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(#rows, 7)
			helpers.assert_eq(rows[7].label, "menu.profiles.create_profile")
			helpers.assert_eq(state.calls, 0)
		end)
	end)
	helpers.it("lazy group children run after native lists and the actual check getter", function()
		with_frame(function(Menu, commands, getters, children, state)
			local declaration = Menu.get_array("frame")
			declaration[#declaration + 1] = { type = "check", id = "auto", i18n = "menu.profiles.auto_detect", checked_when = { "auto_checked" } }
			declaration[#declaration + 1] = { type = "group", id = "apps", i18n = "menu.profiles.per_app_overrides" }
			commands.auto = function() return false end
			getters.auto_checked = function() state.phases[#state.phases + 1] = "autodetect"; return true end
			local native = { label = "Native application", action = function() state.calls = state.calls + 1; return false end }
			children.apps = function(...)
				helpers.assert_eq(select("#", ...), 0)
				state.phases[#state.phases + 1] = "perapp"
				return { native }
			end
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(table.concat(state.phases, "|"), "builtins|custom_present|customs|autodetect|perapp")
			helpers.assert_eq(rows[9].checked, true)
			helpers.assert_true(rawequal(rows[10].items[1], native))
			local rendered = Menu.render_rows(rows, "native_phase_frame")
			helpers.assert_eq(rendered[10].menu[1].fn(), false)
			helpers.assert_eq(state.calls, 1)
		end)
	end)
	helpers.it("existing eager Array group identity and policy stay unchanged", function()
		with_frame(function(Menu, commands, getters, children)
			local declaration = Menu.get_array("frame")
			declaration[#declaration + 1] = { type = "group", id = "apps", i18n = "menu.profiles.per_app_overrides", disabled_when = { "group_ready" } }
			local native = { { label = "Existing application", action = function() return false end } }
			children.apps = native
			getters.group_ready = function() return false end
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_true(rawequal(rows[9].items, native))
			helpers.assert_eq(rows[9].disabled, true)
			helpers.assert_nil(rows[9].action)
		end)
	end)
	local group_refusals = {
		{ "missing", function() return nil end },
		{ "noncallable", function() return true end },
		{ "throw", function() return function() error("per-app native read refused") end end },
		{ "wrongtype", function() return function() return false end end },
		{ "sparse", function() return function() return { [2] = { label = "gap" } } end end },
		{ "scalar child", function() return function() return { false } end end },
		{ "driver dialect", function() return function() return { { title = "wrong", fn = function() end } } end end },
		{ "missing label", function() return function() return { { action = function() end } } end end },
		{ "empty label", function() return function() return { { label = "" } } end end },
		{ "wrong separator type", function() return function() return { { label = "Native", separator = "true" } } end end },
	}
	for _, refusal in ipairs(group_refusals) do
		helpers.it("refuses lazy group " .. refusal[1] .. " without returning a partial frame", function()
			with_frame(function(Menu, commands, getters, children, state)
				local declaration = Menu.get_array("frame")
				declaration[#declaration + 1] = { type = "group", id = "apps", i18n = "menu.profiles.per_app_overrides" }
				children.apps = refusal[2]()
				helpers.assert_nil(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(state.calls, 0)
			end)
		end)
	end
	local refusals = {
		{ "missing list provider", function(_, _, _, children) children.builtins = nil end },
		{ "noncallable list data", function(_, _, _, children) children.builtins = {} end },
		{ "throwing list provider", function(_, _, _, children) children.builtins = function() error("list refused") end end },
		{ "nil list result", function(_, _, _, children) children.builtins = function() end end },
		{ "nonarray list result", function(_, _, _, children) children.builtins = function() return false end end },
		{ "sparse list result", function(_, _, _, children) children.builtins = function() return { [2] = { label = "gap" } } end end },
		{ "metamethod forged dense array", function(_, _, _, children) children.builtins = function() return setmetatable({ [2] = { label = "gap" } }, { __len = function() return 1 end, __pairs = function() return ipairs({ { label = "forged" } }) end }) end end },
		{ "metamethod forged canonical label", function(_, _, _, children) children.builtins = function() return { setmetatable({}, { __index = { label = "forged" } }) } end end },
		{ "string keyed list result", function(_, _, _, children) children.builtins = function() return { bad = { label = "bad" } } end end },
		{ "scalar child", function(_, _, _, children) children.builtins = function() return { false } end end },
		{ "driver dialect child", function(_, _, _, children) children.builtins = function() return { { title = "wrong", fn = function() end } } end end },
		{ "missing canonical label", function(_, _, _, children) children.builtins = function() return { { action = function() end } } end end },
		{ "empty native label", function(_, _, _, children) children.builtins = function() return { { label = "" } } end end },
		{ "wrong native separator type", function(_, _, _, children) children.builtins = function() return { { label = "Native", separator = "true" } } end end },
		{ "missing presence getter", function(_, _, getters) getters.custom_present = nil end },
		{ "noncallable presence getter", function(_, _, getters) getters.custom_present = true end },
		{ "throwing presence getter", function(_, _, getters) getters.custom_present = function() error("presence refused") end end },
		{ "nil presence", function(_, _, getters) getters.custom_present = function() end end },
		{ "numeric presence", function(_, _, getters) getters.custom_present = function() return 1 end end },
		{ "string presence", function(_, _, getters) getters.custom_present = function() return "true" end end },
		{ "empty presence identity", function(Menu) Menu.get_array("frame")[3].present_when = "" end },
		{ "missing selected identity", function(Menu) Menu.get_array("frame")[4].row_id = "missing" end },
		{ "empty selected identity", function(Menu) Menu.get_array("frame")[4].row_id = "" end },
		{ "wrong type selected identity", function(Menu) Menu.get_array("frame")[4].row_id = false end },
		{ "duplicate selected identity", function(Menu) Menu.get_array("commands")[1].id = "clone" end },
		{ "missing include even when false", function(Menu, _, _, _, state) state.present = false; Menu.get_array("frame")[3].section = "missing" end },
		{ "unsupported include metadata", function(Menu) Menu.get_array("frame")[4].i18n = "native fallback" end },
		{ "fixed label disguised as list", function(Menu) Menu.get_array("frame")[2].i18n = "native fallback" end },
		{ "cyclic selected include", function(Menu) local row = Menu.get_array("commands")[2]; row.type, row.section = "include", "frame"; row.id = nil; Menu.get_array("frame")[4].row_id = nil end },
	}
	for _, refusal in ipairs(refusals) do
		helpers.it("refuses " .. refusal[1] .. " without a partial frame or a native command effect", function()
			with_frame(function(Menu, commands, getters, children, state)
				refusal[2](Menu, commands, getters, children, state)
				helpers.assert_nil(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(state.calls, 0)
			end)
		end)
	end
end)


helpers.describe("explicit inert presentation omission preserves actual native data", function()
	local function with_presentation(body)
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
		local state = { calls = 0, getters = 0, errors = {}, phases = {} }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) state.errors[#state.errors + 1] = string.format(fmt, ...) end
		local Menu = assert(require("menu.renderer").new({
			platform = "linux", manifest_path = function() return path end,
			json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger,
		}))
		local builtin = { label = "Builtin native", action = function() state.calls = state.calls + 1; return false end }
		local custom = { label = "Custom native", items = { { label = "Native child", action = function() state.calls = state.calls + 1 end } } }
		local children = {
			builtins = function() state.phases[#state.phases + 1] = "builtins"; return { builtin } end,
			customs = function() state.phases[#state.phases + 1] = "customs"; return { custom } end,
		}
		local getters = { forbidden = function() state.getters = state.getters + 1; return true end }
		body(Menu, { forbidden = builtin.action }, getters, children, state, builtin, custom)
	end
	local function labels(rows)
		local result = {}
		for _, row in ipairs(rows) do result[#result + 1] = row.separator and "---" or row.label end
		return table.concat(result, "|")
	end
	helpers.it("recursively composes valid inert presentation before unchanged native objects and callbacks", function()
		with_presentation(function(Menu, commands, getters, children, state, builtin, custom)
			local rows = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(labels(rows), "menu.profiles.header_default_profiles|---|menu.profiles.header_custom_profiles|Builtin native|Custom native")
			helpers.assert_true(rawequal(rows[4], builtin))
			helpers.assert_true(rawequal(rows[5], custom))
			helpers.assert_eq(rows[4].action(), false)
			helpers.assert_eq(state.calls, 1)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	helpers.it("valid hidden presentation preserves native data without logging a refusal", function()
		with_presentation(function(Menu, commands, getters, children, state)
			local rows = Menu.get_array("presentation")
			for i = #rows, 2, -1 do rows[i] = nil end
			rows[1].platforms, rows[1].unavailable = { "ahk" }, "hide"
			local actual = assert(Menu.template_rows("frame", commands, getters, children))
			helpers.assert_eq(labels(actual), "Builtin native|Custom native")
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	local omissions = {
		{ "missing", function(Menu) Menu.get_array("frame")[1].section = "missing" end },
		{ "empty", function(Menu) local rows = Menu.get_array("presentation"); for i = #rows, 1, -1 do rows[i] = nil end end },
		{ "malformed caption", function(Menu) Menu.get_array("presentation")[1].i18n = "" end },
		{ "unknown row", function(Menu) Menu.get_array("presentation")[3].type = "unknown" end },
		{ "clicked command", function(Menu) local row = Menu.get_array("presentation")[3]; row.type, row.section, row.id, row.i18n = "command", nil, "forbidden", "caption"; row.disabled_when = { "forbidden" } end },
		{ "clicked child", function(Menu) local row = Menu.get_array("presentation")[3]; row.type, row.section, row.id, row.i18n = "group", nil, "customs", "caption" end },
		{ "label getter", function(Menu) Menu.get_array("nested")[1].caption_getter = "forbidden" end },
		{ "header callback", function(Menu) Menu.get_array("presentation")[1].action = function() error("must not execute") end end },
		{ "conditional nested include", function(Menu) Menu.get_array("presentation")[3].present_when = "forbidden" end },
		{ "nested cycle", function(Menu) Menu.get_array("presentation")[3].section = "presentation" end },
		{ "nested missing", function(Menu) Menu.get_array("presentation")[3].section = "missing" end },
		{ "sparse presentation", function(Menu) Menu.get_array("presentation")[2] = nil end },
		{ "malformed platforms", function(Menu) Menu.get_array("presentation")[1].platforms = "hs" end },
		{ "inherited target getter", function(Menu) setmetatable(Menu.get_array("presentation")[1], { __index = { caption_getter = "forbidden" } }) end },
		{ "forged target membership", function(Menu) setmetatable(Menu.get_array("presentation"), { __len = function() return 1 end }) end },
		{ "selected inert row with clicked sibling", function(Menu)
			Menu.get_array("frame")[1].row_id = "safe"
			Menu.get_array("presentation")[1].id = "safe"
			Menu.get_array("presentation")[3] = { type = "command", id = "forbidden", i18n = "caption", disabled_when = { "forbidden" } }
		end },
	}
	for _, omission in ipairs(omissions) do
		helpers.it("logs and omits " .. omission[1] .. " before any clicked/getter work, preserving native data", function()
			with_presentation(function(Menu, commands, getters, children, state, builtin, custom)
				omission[2](Menu)
				local rows = assert(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(labels(rows), "Builtin native|Custom native")
				helpers.assert_true(rawequal(rows[1], builtin))
				helpers.assert_true(rawequal(rows[2], custom))
				helpers.assert_eq(state.getters, 0)
				helpers.assert_eq(state.calls, 0)
				helpers.assert_eq(table.concat(state.phases, "|"), "builtins|customs")
				helpers.assert_eq(#state.errors, 1)
				helpers.assert_true(state.errors[1]:find("presentation omitted", 1, true) ~= nil)
				helpers.assert_eq(rows[1].action(), false)
				helpers.assert_eq(state.calls, 1)
			end)
		end)
	end
	local strict = {
		{ "unknown enum", function(Menu) Menu.get_array("frame")[1].on_refusal = "ignore" end },
		{ "empty enum", function(Menu) Menu.get_array("frame")[1].on_refusal = "" end },
		{ "false enum", function(Menu) Menu.get_array("frame")[1].on_refusal = false end },
		{ "missing include identity", function(Menu) Menu.get_array("frame")[1].section = "" end },
		{ "bad selector", function(Menu) Menu.get_array("frame")[1].row_id = "missing" end },
		{ "missing presence getter", function(Menu) Menu.get_array("frame")[1].present_when = "missing" end },
		{ "throwing presence getter", function(Menu, getters) Menu.get_array("frame")[1].present_when = "forbidden"; getters.forbidden = function() error("owner refused") end end },
		{ "wrong presence type", function(Menu, getters) Menu.get_array("frame")[1].present_when = "forbidden"; getters.forbidden = function() return 1 end end },
		{ "native provider failure", function(_, _, children) children.customs = function() error("real native read failed") end end },
		{ "policy on a native list", function(Menu) Menu.get_array("frame")[2].on_refusal = "omit_presentation" end },
		{ "strict ordinary include", function(Menu) local row = Menu.get_array("frame")[1]; row.on_refusal = nil; row.section = "missing" end },
	}
	for _, refusal in ipairs(strict) do
		helpers.it("keeps " .. refusal[1] .. " a refusal rather than a generic success fallback", function()
			with_presentation(function(Menu, commands, getters, children, state)
				refusal[2](Menu, getters, children)
				helpers.assert_nil(Menu.template_rows("frame", commands, getters, children))
				helpers.assert_eq(state.calls, 0)
			end)
		end)
	end
end)


helpers.describe("inert presentation platform membership cannot invoke implicit getters", function()
	helpers.it("omits a metatable-forged platform array before renderer iteration, retaining physical native data", function()
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
		local callbacks, errors = 0, {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		local Menu = assert(require("menu.renderer").new({ platform = "linux",
			manifest_path = function() return path end, json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger }))
		Menu.get_array("presentation")[1].platforms = setmetatable({ "ahk" }, {
			__index = function(_, index) callbacks = callbacks + 1; if index == 2 then return "linux" end end,
		})
		local builtin, custom = { label = "Builtin native" }, { label = "Custom native" }
		local rows = assert(Menu.template_rows("frame", {}, {}, {
			builtins = function() return { builtin } end, customs = function() return { custom } end,
		}))
		helpers.assert_eq(callbacks, 0, "raw platform proof cannot later execute an implicit callback")
		helpers.assert_eq(#rows, 2, "the malformed inert target is completely omitted on both Lua VMs")
		helpers.assert_true(rawequal(rows[1], builtin) and rawequal(rows[2], custom))
		helpers.assert_eq(#errors, 1)
		helpers.assert_true(errors[1]:find("presentation omitted", 1, true) ~= nil)
	end)
end)


helpers.describe("selected inert include inspects only physical identities before whole-target proof", function()
	for _, mode in ipairs({ "scalar sibling", "inherited sibling identity", "inherited target membership" }) do
		helpers.it("omits " .. mode .. " without implicit work, retaining the native data after a valid exact selector", function()
			local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
			local callbacks, errors = 0, {}
			local logger = helpers.make_logger_stub()
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			local Menu = assert(require("menu.renderer").new({ platform = "linux",
				manifest_path = function() return path end, json_decode = require("json").decode,
				i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger }))
			Menu.get_array("frame")[1].row_id = "safe"
			local target = Menu.get_array("presentation")
			target[1].id = "safe"
			if mode == "scalar sibling" then target[3] = false
			elseif mode == "inherited sibling identity" then
				target[3] = setmetatable({ type = "label", i18n = "caption" }, {
					__index = function() callbacks = callbacks + 1; return "inherited" end,
				})
			else
				setmetatable(target, { __index = function() callbacks = callbacks + 1 end })
			end
			local builtin, custom = { label = "Builtin native" }, { label = "Custom native" }
			local called, rows = pcall(Menu.template_rows, "frame", {}, {}, {
				builtins = function() return { builtin } end, customs = function() return { custom } end,
			})
			helpers.assert_true(called, "malformed presentation cannot throw before its opted-in preflight")
			helpers.assert_eq(callbacks, 0, "physical selector admission never invokes inherited identity/membership")
			helpers.assert_not_nil(rows)
			helpers.assert_eq(#rows, 2)
			helpers.assert_true(rawequal(rows[1], builtin) and rawequal(rows[2], custom))
			helpers.assert_eq(#errors, 1)
			helpers.assert_true(errors[1]:find("presentation omitted", 1, true) ~= nil)
		end)
	end
end)


helpers.describe("invalid inert selector refuses before identity comparison", function()
	helpers.it("does not invoke equality callbacks for a non-string selector", function()
		local path = helpers.driver_root():gsub("/$", "") .. "/../_shared/tests/corpus/menus/profile_frame_presentation_omission.json"
		local callbacks, providers, errors = 0, 0, {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		local Menu = assert(require("menu.renderer").new({ platform = "linux",
			manifest_path = function() return path end, json_decode = require("json").decode,
			i18n = { get = function(key) return key end, section = function(key) return key end }, logger = logger }))
		local meta = { __eq = function() callbacks = callbacks + 1; return true end }
		Menu.get_array("frame")[1].row_id = setmetatable({}, meta)
		Menu.get_array("presentation")[1].id = setmetatable({}, meta)
		local function supplied() providers = providers + 1; return { { label = "Native" } } end
		local called, rows = pcall(Menu.template_rows, "frame", {}, {}, { builtins = supplied, customs = supplied })
		helpers.assert_true(called)
		helpers.assert_nil(rows, "bad selector is a strict identity refusal, not omitted presentation")
		helpers.assert_eq(callbacks, 0)
		helpers.assert_eq(providers, 0)
		helpers.assert_eq(#errors, 1)
		helpers.assert_nil(errors[1]:find("presentation omitted", 1, true))
	end)
end)
