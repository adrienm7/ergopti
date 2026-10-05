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
