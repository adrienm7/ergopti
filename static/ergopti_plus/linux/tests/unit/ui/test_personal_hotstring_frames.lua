--- tests/unit/ui/test_personal_hotstring_frames.lua

--- ==============================================================================
--- MODULE: Personal Hotstrings Complete Frames
--- DESCRIPTION:
--- Exercises the genuine native provider and renderer with a private native
--- preferences source. Source order and literal caption expectations are authored
--- independently of declarations; retained controls preserve the editor contract.
--- ==============================================================================

local helpers = require("tests.helpers")
local function upvalue(callback, wanted)
	for index = 1, 100 do
		local name, value = debug.getupvalue(callback, index)
		if name == wanted then return assert(value) end
		if name == nil then break end
	end
	error("missing genuine native closure: " .. wanted)
end

--- Owns genuine current modules and a private persistent editor source.
--- @param scenario function Receives actual frame observations.
--- @param options table|nil Native source and pause posture.
local function with_personal_frame(scenario, options)
	options = options or {}
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu",
		"ui.menu.menu_builder", "adapters.storage", "ui.hotstring_editor.bridge" }
	local previous, saved_getenv = {}, os.getenv
	for name, value in pairs(package.loaded) do previous[name] = value end
	local scratch, native, owner, receipt, acquired, store
	local lfs = require("lfs")
	local ok, result = xpcall(function()
		scratch = assert(os.tmpname()); assert(os.remove(scratch)); assert(lfs.mkdir(scratch))
		assert(lfs.mkdir(scratch .. "/ergopti_plus"))
		store = scratch .. "/ergopti_plus/storage.json"
		local seed = assert(io.open(store, "wb"))
		assert(seed:write('{"hotstring_editor.default_section":"beta","hotstring_editor.auto_close":false,"future":{"keep":"bytes"}}\n'))
		assert(seed:close())
		os.getenv = function(name)
			if name == "XDG_CONFIG_HOME" then return scratch end
			return saved_getenv(name)
		end
		for _, name in ipairs(names) do rawset(package.loaded, name, nil) end
		native = require("infra.i18n"); native.init()
		owner = { pending = function() return false end }
		assert(native.scope_acquire(owner)); acquired = true
		receipt = assert(native.scope_capture(owner))
		assert(native.scope_apply(owner, receipt, options.locale or "en"))
		local renderer = require("infra.manifest_menu")
		local bridge = require("ui.hotstring_editor.bridge")
		local builder = require("ui.menu.menu_builder")
		local build_hotstrings = upvalue(builder.build, "_build_hotstrings")
		local files = require("infra.paths")
		local corpus_file = assert(io.open(files.shared("tests/corpus/menus/hotstring_personal_frames.json"), "rb"))
		local corpus = assert(require("json").decode(assert(corpus_file:read("*a")))); assert(corpus_file:close())
		local sections = options.empty and {} or { "alpha", "-", "module", "beta" }
		local category = { id = "personal", count = 5, sections_order = sections,
			sections = { alpha = { count = 2 }, module = { count = 0 }, beta = { count = 3 } } }
		local changes, openings = 0, 0
		local context = {
			config = { get_groups = function() return {} end, is_group_enabled = function() return true end,
				is_section_enabled = function() return true end,
				get_category = function(id) return id == "personal" and category or nil end },
			paused = options.paused == true,
			is_paused = function() return options.paused == true end,
			webview = { show = function(name) assert(name == "hotstring_editor"); openings = openings + 1 end },
			on_menu_changed = function() changes = changes + 1 end,
		}
		local function read_source()
			local file = assert(io.open(store, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
		end
		return scenario({ root = renderer.get_root(), bridge = bridge, corpus = corpus,
			get = native.get, locale = native.get_locale(), context = context, read_source = read_source,
			changes = function() return changes end, openings = function() return openings end,
			build = function()
				local parent = build_hotstrings(context)
				assert(parent == nil or type(parent) == "table" and type(parent.label) == "string"
					and type(parent.submenu) == "table", "the actual native parent is complete DATA or an explicit refusal")
				return parent and parent.submenu
			end })
	end, debug.traceback)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	os.getenv = saved_getenv
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	local cleanup_ok, cleanup_error = pcall(function()
		if scratch then
			for filename in lfs.dir(scratch .. "/ergopti_plus") do
				if filename ~= "." and filename ~= ".." then assert(os.remove(scratch .. "/ergopti_plus/" .. filename)) end
			end
			assert(lfs.rmdir(scratch .. "/ergopti_plus")); assert(lfs.rmdir(scratch))
		end
	end)
	for name, value in pairs(previous) do assert(rawequal(rawget(package.loaded, name), value), name) end
	assert(rawequal(os.getenv, saved_getenv))
	assert(restored and released and forgotten, "native scope restoration remains acknowledged")
	assert(cleanup_ok, cleanup_error)
	if not ok then error(result, 0) end
	return result
end

local function find(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local child = type(row.menu) == "table" and find(row.menu, title) or nil
		if child then return child end
	end
end

helpers.describe("complete personal hotstring shared frames (Linux)", function()
	helpers.it("retains the literal native section order and persistent current default", function()
		with_personal_frame(function(f)
			local before = f.read_source()
			local rows = f.build()
			local parent = assert(find(rows, f.corpus.default_parent_labels.linux[f.locale]))
			local expected = f.corpus.default_choices.linux_native_order
			helpers.assert_eq(#parent.menu, #expected)
			for index, caption in ipairs(expected) do
				if caption == "none" then caption = f.corpus.none_captions.linux[f.locale] end
				helpers.assert_eq(parent.menu[index].title, caption)
				helpers.assert_eq(parent.menu[index].checked == true, f.corpus.default_checks.linux[index])
			end
			helpers.assert_eq(find(rows, f.get("menu.hotstrings.close_on_add")).checked == true, false)
			helpers.assert_eq(f.read_source(), before, "presentation does not rewrite the private native source")
			helpers.assert_eq(f.changes(), 0); helpers.assert_eq(f.openings(), 0)
		end)
	end)
	helpers.it("preserves genuine editor preference callbacks and fresh native reload", function()
		with_personal_frame(function(f)
			local rows = f.build()
			local parent = assert(find(rows, f.corpus.default_parent_labels.linux.en))
			parent.menu[1].fn()
			helpers.assert_eq(f.bridge.get_pref("default_section"), "")
			find(rows, f.get("menu.hotstrings.close_on_add")).fn()
			helpers.assert_eq(f.bridge.get_pref("auto_close"), true)
			helpers.assert_eq(f.changes(), 2)
			local bytes = f.read_source()
			local model = assert(require("json").decode(bytes))
			helpers.assert_eq(model.future.keep, "bytes")
			local old_storage = package.loaded["adapters.storage"]
			local old_bridge = package.loaded["ui.hotstring_editor.bridge"]
			package.loaded["adapters.storage"], package.loaded["ui.hotstring_editor.bridge"] = nil, nil
			local reload = require("ui.hotstring_editor.bridge")
			helpers.assert_eq(reload.get_pref("default_section"), "")
			helpers.assert_eq(reload.get_pref("auto_close"), true)
			package.loaded["adapters.storage"], package.loaded["ui.hotstring_editor.bridge"] = old_storage, old_bridge
		end)
	end)
	helpers.it("refuses missing whole declarations and held commands without native effects", function()
		with_personal_frame(function(f)
			local rows, before = f.build(), f.read_source()
			local parent = assert(find(rows, f.corpus.default_parent_labels.linux.en))
			local close = assert(find(rows, f.get("menu.hotstrings.close_on_add")))
			for _, key in ipairs({ "hotstring_personal_default_frame", "hotstring_personal_controls_frame", "hotstring_personal_content_frame", "hotstring_personal_default_parent" }) do
				local original = f.root[key]; f.root[key] = nil
				helpers.assert_eq(find(f.build(), parent.title), nil)
				helpers.assert_eq(find(f.build(), close.title), nil)
				f.root[key] = original; helpers.assert_not_nil(find(f.build(), parent.title))
			end
			local none = f.root.hotstring_personal_none; f.root.hotstring_personal_none = {}
			helpers.assert_eq(parent.menu[1].fn(), false)
			f.root.hotstring_personal_none = none
			local close_definition = f.root.hotstring_personal_close; f.root.hotstring_personal_close = {}
			helpers.assert_eq(close.fn(), false)
			f.root.hotstring_personal_close = close_definition
			helpers.assert_eq(f.read_source(), before); helpers.assert_eq(f.changes(), 0)
		end)
	end)
	helpers.it("restores the exact module owners and locale after a scenario raises", function()
		local renderer, bridge = rawget(package.loaded, "infra.manifest_menu"), rawget(package.loaded, "ui.hotstring_editor.bridge")
		local ok, detail = pcall(with_personal_frame, function() error("personal frame scenario sentinel") end)
		helpers.assert_eq(ok, false); helpers.assert_true(detail:find("personal frame scenario sentinel", 1, true) ~= nil)
		helpers.assert_true(rawequal(rawget(package.loaded, "infra.manifest_menu"), renderer))
		helpers.assert_true(rawequal(rawget(package.loaded, "ui.hotstring_editor.bridge"), bridge))
	end)
	helpers.it("uses literal French hand captions from the genuine current renderer", function()
		with_personal_frame(function(f)
			local rows = f.build()
			local parent = assert(find(rows, f.corpus.default_parent_labels.linux.fr))
			helpers.assert_eq(parent.menu[1].title, f.corpus.none_captions.linux.fr)
			helpers.assert_eq(find(rows, f.corpus.close_caption.fr).checked == true, false)
			local original = f.root.hotstring_personal_content_frame
			f.root.hotstring_personal_content_frame = nil
			helpers.assert_eq(find(f.build(), parent.title), nil)
			f.root.hotstring_personal_content_frame = original
			helpers.assert_not_nil(find(f.build(), parent.title))
		end, { locale = "fr" })
	end)
	helpers.it("retains empty personal source status and one real none choice", function()
		with_personal_frame(function(f)
			local rows = f.build()
			local parent = assert(find(rows, f.corpus.default_parent_labels.linux.en))
			helpers.assert_eq(#parent.menu, 1)
			helpers.assert_eq(parent.menu[1].title, f.corpus.none_captions.linux.en)
			local empty
			for index, row in ipairs(rows) do
				if row.title == f.get("menu.hotstrings.close_on_add") then
					helpers.assert_eq(rows[index + 1].title, "-")
					empty = assert(rows[index + 2])
				end
			end
			helpers.assert_not_nil(empty)
			helpers.assert_eq(empty.title, f.get("menu.hotstrings.no_group_loaded"))
			helpers.assert_eq(empty.disabled, true)
			helpers.assert_type(empty.fn, "function")
		end, { empty = true })
	end)

end)

--- Restores the exact private declaration independently of scenario failure.
--- @param frame table Genuine existing provider fixture.
--- @param scenario function Receives the retained original leaf declaration.
local function with_default_choice_declaration(frame, scenario)
	local key = "hotstring_personal_default_choice"
	local original = rawget(frame.root, key)
	assert(type(original) == "table", "the genuine generated choice declaration exists")
	local native_index
	for index, row in ipairs(original) do
		for _, platform in ipairs(row.platforms or {}) do
			if platform == "linux" then
				assert(native_index == nil, "the original leaf has one actual native-visible owner")
				native_index = index
			end
		end
	end
	assert(native_index ~= nil, "the original leaf has its actual native-visible owner")
	local ok, result = xpcall(function() return scenario(key, original, native_index) end, function(err) return err end)
	rawset(frame.root, key, original)
	if not ok then error(result, 0) end
	return result
end

helpers.describe("shared personal default-category leaf policy", function()
	for _, kind in ipairs({ "missing", "kind", "caption" }) do
		helpers.it("refuses actual provider with " .. kind .. " leaf source and repairs exactly", function()
			with_personal_frame(function(f)
				with_default_choice_declaration(f, function(key, original, native_index)
					assert(type(f.build()) == "table")
					local changed = {}
					if kind ~= "missing" then
						for index, row in ipairs(original) do changed[index] = row end
						local row = {}
						for field, value in pairs(original[native_index]) do row[field] = value end
						if kind == "kind" then row.type = "label"
						else row.caption_getter = "unavailable_default_caption" end
						changed[native_index] = row
					end
					rawset(f.root, key, changed)
					helpers.assert_eq(f.build(), nil, "a refused dynamic leaf cannot publish a partial default frame")
					helpers.assert_eq(f.bridge.get_pref("default_section"), "beta")
					helpers.assert_eq(f.changes(), 0); helpers.assert_eq(f.openings(), 0)
					rawset(f.root, key, original)
					local repaired = assert(f.build())
					local parent = assert(find(repaired, f.corpus.default_parent_labels.linux[f.locale]))
					for index, caption in ipairs(f.corpus.default_choices.linux_native_order) do
						if caption == "none" then caption = f.corpus.none_captions.linux[f.locale] end
						helpers.assert_eq(parent.menu[index].title, caption)
						helpers.assert_eq(parent.menu[index].checked == true, f.corpus.default_checks.linux[index])
					end
				end)
			end)
		end)
	end
	helpers.it("retained actual choice refuses missing source and dispatches after exact repair", function()
		with_personal_frame(function(f)
			with_default_choice_declaration(f, function(key, original)
				local rows = assert(f.build())
				local parent = assert(find(rows, f.corpus.default_parent_labels.linux[f.locale]))
				local choice = assert(parent.menu[2])
				helpers.assert_eq(choice.title, f.corpus.default_choices.linux_native_order[2])
				local before = f.read_source()
				rawset(f.root, key, {})
				helpers.assert_eq(choice.fn(), false)
				helpers.assert_eq(f.bridge.get_pref("default_section"), "beta")
				helpers.assert_eq(f.read_source(), before)
				helpers.assert_eq(f.changes(), 0); helpers.assert_eq(f.openings(), 0)
				rawset(f.root, key, original)
				choice.fn()
				helpers.assert_eq(f.bridge.get_pref("default_section"), "alpha")
				helpers.assert_eq(f.changes(), 1)
				local stored = assert(require("json").decode(f.read_source()))
				helpers.assert_eq(stored["hotstring_editor.default_section"], "alpha")
				helpers.assert_eq(stored.future.keep, "bytes")
			end)
		end)
	end)
end)
