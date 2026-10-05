--- tests/unit/infra/test_personal_file_controls_native.lua

--- ==============================================================================
--- MODULE: Native Personal Metadata Publication
--- DESCRIPTION:
--- Boots actual source adoption, registry and override owners on physical files.
--- Conditional publication failures preserve live choices and retain inverse debt.
--- Real temporary I/O and native adapter code use controlled Hammerspoon primitives;
--- this module does not qualify physical macOS locking or keyboard input.
--- ==============================================================================

local helpers = require("tests.helpers")
local lfs = require("lfs")
local Files = require("hotstrings.personal_files")

local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil, "absent" end
	local content = assert(file:read("*a")); assert(file:close())
	return content, "ok"
end

local function write(path, content)
	local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
end

local function terminal_available(f)
	local token = assert(f.Config.capture_terminal_admission(), "settled personal publication restores actual terminal admission")
	helpers.assert_true(token.abort(), "the fixture releases its exact terminal admission owner")
end

local function fixture(body, options)
	options = options or {}
	return helpers.with_stub_scope({
		"adapters.file_system", "adapters.storage", "infra.config_paths", "infra.fs_dir", "infra.toml.reader",
		"infra.personal_hotstrings", "infra.personal_file_adoption", "infra.personal_file_controls",
		"modules.hotstrings.hotstrings_config", "modules.keymap", "modules.keymap.state",
		"modules.keymap.registry", "modules.keymap.registry_groups", "modules.keymap.registry_index",
		"modules.keymap.expander", "modules.keymap.llm_bridge", "modules.keymap.utils",
		"modules.llm.prediction_engine", "modules.llm.warmup_controller", "modules.llm.streaming_handler",
		"modules.keymap.terminators", "modules.keymap.terminator_replay", "ui.hotstring_editor",
		"infra.preferences", "infra.personal_file_scope", "ui.menu.menu_hotstrings_custom", "ui.menu.keymap_lifecycle",
		"infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu", "ui.hotstrings_config_window",
	}, function()
		local root = os.tmpname(); os.remove(root); assert(lfs.mkdir(root))
		local primary, alpha, beta = root .. "/personal_hotstrings.toml", root .. "/alpha.toml", root .. "/beta.toml"
		local overrides = root .. "/_overrides.toml"
		local preferences = root .. "/_preferences.toml"
		if options.preferences then write(preferences, options.preferences) end
		write(primary, '[[base]]\n"primary" = "Primary"\n')
		write(alpha, options.alpha_source or [=[# Independent personal source notes.
[_meta]
delay = 0.1
color = "#111111"
show_tooltip = true
priority = 10
future = "source neighbor"
[_meta.sections.probe]
delay = 0.2
color = "#222222"
show_tooltip = true
priority = 15
[[probe]]
"collision" = { output = "Alpha", is_word = false, auto_expand = true, is_case_sensitive = true, is_case_sensitive_strict = true }
[[other]]
"alphasibling" = "Alpha sibling"
]=])
		write(beta, [=[[_meta]
delay = 0.4
priority = 40
[[probe]]
"collision" = { output = "Beta", is_word = false, auto_expand = true, is_case_sensitive = true, is_case_sensitive_strict = true }
]=])
		write(overrides, options.override_source or [=[# Independent override notes.
[personal_ext_alpha]
delay = 0.9
color = "#aaaaaa"
show_tooltip = false
priority = 20
future = { keep = "unknown owner" }
[personal_ext_alpha.probe]
delay = 0.8
color = "#bbbbbb"
show_tooltip = false
priority = 30
future = "section neighbor"
[personal_ext_alpha.other]
delay = 0.7
priority = 25
[personal_ext_beta]
delay = 0.6
priority = 40
[foreign]
future = "keep every neighbor"
]=])
		local controls, observations = {}, { writes = {}, publications = 0, reads = {}, enumerations = {} }
		local cleanup_sources = options.setup and options.setup(root, controls, observations)
		local native_paths = require("infra.config_paths")
		package.loaded["infra.config_paths"] = setmetatable({ get = function(key)
			if key == "PersonalTomlPath" then return primary end
			if key == "PersonalHotstringsDir" then return root end
			if key == "ConfigTomlPath" then return preferences end
			return native_paths.get(key)
		end }, { __index = native_paths })
		package.loaded["infra.fs_dir"] = { entries = function(path)
			observations.enumerations[#observations.enumerations + 1] = path
			local names = {}; for name in lfs.dir(path) do names[#names + 1] = name end; return names
		end }
		package.loaded["ui.hotstring_editor"] = { init = function() return true end }
		local adapter = {
			exists = function(path) return lfs.attributes(path) ~= nil end,
			path_status = function(path)
				local attrs = lfs.symlinkattributes(path)
				return attrs and "present" or "absent", attrs
			end,
			read = read,
			read_with_status = function(path)
				observations.reads[#observations.reads + 1] = path
				if controls.read_refusal == path then return nil, "error", "controlled physical read refusal" end
				return read(path)
			end,
			write_if_unchanged = function(path, content, expected)
				observations.writes[#observations.writes + 1] = { path = path, content = content, expected = expected }
				if controls.source_inverse_refusal and path == alpha and content == controls.original_source then return false end
				if controls.source_race and path == alpha then
					write(path .. ".owned-stage", controls.source_race)
					assert(os.rename(path .. ".owned-stage", path)); controls.source_race = nil
				end
				if controls.source_refusal and path == alpha then
					if controls.source_refusal == "throw" then error("controlled source publication refusal") end
					return false
				end
				if controls.inverse_refusal and path == overrides and content == controls.original_overrides then return false end
				local previous, status = read(path)
				if status ~= expected.status or (status == "ok" and previous ~= expected.content) then return false end
				write(path .. ".owned-stage", content); assert(os.rename(path .. ".owned-stage", path))
				observations.publications = observations.publications + 1
				if path == alpha and controls.refuse_receipt then controls.read_refusal = alpha end
				if controls.after_publish then controls.after_publish(path, content) end
				return true
			end,
		}
		local cleanup_adapter
		if options.adapter_factory then
			adapter, cleanup_adapter = options.adapter_factory(adapter, {
				root = root, alpha = alpha, overrides = overrides, controls = controls, observations = observations,
			})
			-- The native adapter fixture reloads its own directory port. Source boot
			-- discovery owns an actual physical enumeration rather than that port's
			-- synthetic missing-path listing used by native writer primitives.
			package.loaded["infra.fs_dir"] = { entries = function(path)
				local names = {}; for name in lfs.dir(path) do names[#names + 1] = name end; return names
			end }
		end
		package.loaded["adapters.file_system"] = adapter
		local native_state, state = require("modules.keymap.state")
		package.loaded["modules.keymap.state"] = setmetatable({ new = function(...)
			state = native_state.new(...); return state
		end }, { __index = native_state })
		local old_attributes = hs.fs.attributes
		hs.fs.attributes = function(path) return lfs.attributes(path) end
		local native_utils = require("modules.keymap.utils")
		package.loaded["modules.keymap.utils"] = setmetatable({
			is_ignored_window = function() return false, 0 end,
			is_secure_field = function() return false end,
			start_ignored_win_tracking = function() return 1 end,
		}, { __index = native_utils })
		local ok, detail = pcall(function()
			local Keymap = helpers.load_with_stubs("modules.keymap")
			hs.fs.attributes = function(path) return lfs.attributes(path) end
			local Registry = require("modules.keymap.registry")
			local Config = require("modules.hotstrings.hotstrings_config")
			helpers.assert_true(Config.init({ override_path = overrides, delay_transaction = Keymap.with_hotstring_delays,
				toml_resolver = function(id)
					if id == "personal" then return primary end
					local components = Files.components(id)
					return components and root .. "/" .. table.concat(components, "/") or helpers.shared("modules/hotstrings/" .. id .. ".toml")
				end }))
			local Loader = require("infra.personal_hotstrings")
			local Preferences = require("infra.preferences")
			local saved = { hotstrings = { personal_ext_alpha = true, personal_ext_beta = true } }
			if options.preferences then
				local status; saved, status = Preferences.load(preferences); helpers.assert_eq(status, "ok")
			end
			if options.registration_refusal then
				local native_load = Keymap.load_toml
				Keymap.load_toml = function(name, ...)
					if name == Files.describe({ "alpha.toml" }).id then
						if options.registration_refusal == "false" then return false end
						return nil
					end
					return native_load(name, ...)
				end
			end
			local loaded = Loader.load({ bundled_hotstrings_dir = helpers.shared("modules/hotstrings/"), saved_preferences = saved })
			helpers.assert_eq(#loaded, 3, "the real boot scanner adopts only primary and two personal source files")
			helpers.assert_true(Keymap.apply_hotstring_preferences(saved), "the native boot projection applies actual durable choices")
			local alpha_id, beta_id = Files.describe({ "alpha.toml" }).id, Files.describe({ "beta.toml" }).id
			local Controller = require("infra.personal_file_controls")
			local function binding() return assert(Controller.capture(alpha_id), "real boot adoption supplies the current physical capability") end
			local function winner()
				for _, mapping in ipairs(Registry.mappings_for_tail("n") or {}) do
					if mapping.trigger == "collision" then
						return require("modules.keymap.expander").would_fire(mapping, "collision"), mapping
					end
				end
			end
			body({ root = root, primary = primary, alpha = alpha, beta = beta, overrides = overrides,
				preferences = preferences, Preferences = Preferences, saved = saved, loaded = loaded,
				alpha_id = alpha_id, beta_id = beta_id, state = state, Keymap = Keymap, Registry = Registry,
				Config = Config, Loader = Loader, Controller = Controller, binding = binding, winner = winner,
				controls = controls, observations = observations, adapter = adapter })
		end)
		if cleanup_adapter then cleanup_adapter() end
		if cleanup_sources then cleanup_sources() end
		hs.fs.attributes = old_attributes
		for _, path in ipairs({ primary, alpha, beta, overrides, preferences, root .. "/gamma.toml" }) do
			os.remove(path); os.remove(path .. ".owned-stage")
		end
		assert(lfs.rmdir(root))
		if not ok then error(detail, 0) end
	end)
end

--- Builds actual native file rows through the shared policy and shipped renderer.
--- The application configuration-window port is controlled; source and preference
--- mutations still traverse the real controller, registry and conditional writer.
local function personal_menu(f)
	package.loaded["infra.i18n"], package.loaded["infra.locale"], package.loaded["locale.core"] = nil, nil, nil
	package.loaded["infra.manifest_menu"], package.loaded["ui.menu.menu_hotstrings_custom"] = nil, nil
	local i18n = require("infra.i18n"); i18n.init()
	local locale = require("infra.locale"); locale.set_locale("en")
	local projected = f.Preferences.project_hotstring_preferences(f.saved, f.Registry.list_groups(), f.Registry.get_sections)
	local ctx = { keymap = f.Keymap, personal_root = f.root, personal_files = f.loaded, hotfiles = { f.primary, f.alpha, f.beta },
		state = { keymap = true, trigger_char = "★", hotstrings = projected.hotstrings }, paused = false,
		get_group_name = function(path)
			for _, record in ipairs(f.loaded) do if record.path == path then return record.name end end
			return nil
		end,
		applyTriggerChar = function(value) return value end, notify_feature = function() end,
		hotstring_editor = { open = function() return true end } }
	local observations = { refreshes = 0, edits = 0 }
	ctx.updateMenu = function() observations.refreshes = observations.refreshes + 1 end
	local names = {}; for _, record in ipairs(f.loaded) do names[#names + 1] = record.name end
	ctx.save_prefs = function() return f.Preferences.save(f.preferences, ctx.state, names, { keymap = f.Keymap }) end
	package.loaded["ui.hotstrings_config_window"] = { open = function()
		observations.edits = observations.edits + 1; return true
	end }
	local Custom = require("ui.menu.menu_hotstrings_custom")
	local Manifest = require("infra.manifest_menu")
	local function find(rows, predicate)
		for _, row in ipairs(rows or {}) do
			if predicate(row) then return row end
			local found = find(row.menu or row.submenu or row.items, predicate)
			if found then return found end
		end
	end
	local function build() return { Custom.build_custom(ctx, { group_counts = {} }) } end
	local function file(name)
		return assert(find(build(), function(row)
			return (row.title or row.label or ""):match("^" .. name .. "[ %(—]") ~= nil
				or (row.title or row.label) == name
		end), "the actual native renderer exposes file " .. name)
	end
	return { build = build, find = find, file = file, i18n = i18n, manifest = Manifest, ctx = ctx, observations = observations }
end

--- Runs the actual Group 3 FileSystem producer on real files. Only Hammerspoon
--- advisory mutex/close receipts and requested failure timing are controlled.
local function native_fixture(body)
	return require("tests.support.file_system_transaction_fixture").with_fixture(function(native)
		fixture(body, { adapter_factory = function(_, f)
			local controls, observations = f.controls, f.observations
			observations.locks, observations.unlocks, observations.closes = {}, {}, {}
			observations.renames, observations.receipts, observations.views = {}, {}, {}
			local handles, held = {}, {}
			local saved_open, saved_rename = io.open, os.rename
			local function increment(target, path) target[path] = (target[path] or 0) + 1 end
			local files = native.make_adapter(nil, nil, nil, nil, function(handle)
				increment(observations.locks, handle.path)
				if held[handle.path] then return nil, "controlled independent native lock contention" end
				held[handle.path] = true; return true
			end, function(handle)
				increment(observations.unlocks, handle.path)
				if controls.release_refusal == handle.path then return nil, "controlled native unlock refusal" end
				held[handle.path] = false; return true
			end)
			io.open = function(path, mode)
				local handle, detail = saved_open(path, mode)
				if not handle or mode ~= "a+" or path:sub(-#native.WRITE_LOCK_SUFFIX) ~= native.WRITE_LOCK_SUFFIX then
					return handle, detail
				end
				local source = path:sub(1, -#native.WRITE_LOCK_SUFFIX - 1)
				local wrapper = { path = source, close = function()
					increment(observations.closes, source)
					if controls.release_refusal == source then return nil, "controlled native lock close refusal" end
					held[source] = false; return handle:close()
				end }
				handles[#handles + 1] = handle
				return wrapper
			end
			os.rename = function(source, destination)
				if destination == f.alpha or destination == f.overrides then
					increment(observations.renames, destination)
					if controls.rename_refusal == destination then return nil, "controlled prepublication rename refusal" end
				end
				local renamed, detail = saved_rename(source, destination)
				if renamed and controls.after_rename then controls.after_rename(destination) end
				return renamed, detail
			end
			local native_publish, native_view = files.write_if_unchanged, files.publication_receipt_view
			local native_read = files.read_with_status
			files.read_with_status = function(path, on_error)
				if controls.read_refusal == path then return nil, "error", "controlled physical read refusal" end
				return native_read(path, on_error)
			end
			files.write_if_unchanged = function(path, content, expected, on_error)
				observations.writes[#observations.writes + 1] = { path = path, content = content, expected = expected }
				local requested, diagnostic = path, on_error
				if path == f.alpha and controls.foreign_receipt == "callback" then diagnostic = function() end end
				if path == f.alpha and controls.foreign_receipt == "path" then requested = f.root .. "/./alpha.toml" end
				local accepted, detail, receipt = native_publish(requested, content, expected, diagnostic)
				if receipt then observations.receipts[#observations.receipts + 1] = receipt end
				if controls.after_publish then controls.after_publish(path, content) end
				return accepted, detail, receipt
			end
			files.publication_receipt_view = function(receipt, path, expected, candidate, on_error)
				local view = native_view(receipt, path, expected, candidate, on_error)
				observations.views[#observations.views + 1] = { path = path, accepted = view ~= nil }
				return view
			end
			observations.held = held
			return files, function()
				-- Settle only the fixture's exact captured native resources. A controller
				-- whose admission was revoked remains closed and is never reset here.
				controls.release_refusal, controls.rename_refusal, controls.after_rename = nil, nil, nil
				for _, receipt in ipairs(observations.receipts) do
					if receipt.is_settled() ~= true then helpers.assert_true(receipt.retry()) end
				end
				io.open, os.rename = saved_open, saved_rename
				for _, handle in ipairs(handles) do pcall(function() handle:close() end) end
				for _, path in ipairs({ f.alpha, f.overrides }) do os.remove(path .. native.WRITE_LOCK_SUFFIX) end
				for path, active in pairs(held) do helpers.assert_eq(active, false, "fixture releases its native mutex " .. path) end
			end
		end })
	end)
end

--- Unavailable owners must also close the native generic category controls.
local function unavailable_scope(menu, file)
	local rows = file.menu or file.submenu
	for _, key in ipairs({ "menu.hotstrings.scope_enable_all", "menu.hotstrings.scope_disable_all" }) do
		local row = assert(menu.find(rows, function(item) return item.title == menu.i18n.get(key) end),
			"the actual file submenu retains the declared generic scope control " .. key)
		helpers.assert_eq(row.disabled, true, "unavailable file ownership visibly closes " .. key)
		helpers.assert_nil(row.fn, "the unavailable native scope row has no runnable callback")
	end
end

helpers.describe("actual native personal file menu publication", function()
	helpers.it("renders all five shared controls and commits file gates and tooltip through actual owners", function()
		fixture(function(f)
			helpers.assert_true(f.Registry.disable_section(f.alpha_id, "probe"))
			local menu = personal_menu(f)
			local declared = menu.manifest.get_array("personal_file_controls")
			local expected = { { "personal_file_enabled", "menu.common.enabled" }, { "personal_file_delay", "hs_config.label_delay" },
				{ "personal_file_priority", "hs_config.label_priority" }, { "personal_file_color", "hs_config.label_color" },
				{ "personal_file_tooltip", "hs_config.label_tooltip" } }
			helpers.assert_eq(#declared, 5, "the independent control contract requires all five declared fields")
			local file = menu.file("alpha"); local rows = file.menu or file.submenu
			for index, control in ipairs(expected) do
				helpers.assert_eq(declared[index].id, control[1])
				helpers.assert_true(menu.i18n.get(control[2]) ~= control[2], "the real English catalogue translates " .. control[2])
				helpers.assert_eq(rows[index].title, menu.i18n.get(control[2]))
				helpers.assert_true(type(rows[index].fn) == "function" and rows[index].disabled ~= true)
			end
			for index = 2, 4 do helpers.assert_true(rows[index].fn()) end
			helpers.assert_eq(menu.observations.edits, 3, "all three native metadata commands reach the configuration window port")
			local source, overrides = read(f.alpha), read(f.overrides)
			helpers.assert_true(rows[1].fn(), "the rendered file gate commits its actual preference cohort")
			helpers.assert_eq(f.Registry.is_group_enabled(f.alpha_id), false)
			helpers.assert_eq(f.Registry.is_section_enabled(f.alpha_id, "probe"), false)
			helpers.assert_eq(f.Registry.is_section_enabled(f.alpha_id, "other"), true)
			helpers.assert_eq(f.Registry.is_group_enabled(f.beta_id), true)
			helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), overrides)
			local enabled = menu.file("alpha"); helpers.assert_true((enabled.menu or enabled.submenu)[1].fn())
			helpers.assert_eq(f.Registry.is_group_enabled(f.alpha_id), true)
			helpers.assert_eq(f.Registry.is_section_enabled(f.alpha_id, "probe"), false)
			helpers.assert_eq(f.Registry.is_section_enabled(f.alpha_id, "other"), true)
			local current = menu.file("alpha"); local tooltip = (current.menu or current.submenu)[5]
			helpers.assert_eq(f.Config.resolve(f.alpha_id, nil).show_tooltip, false)
			helpers.assert_true(tooltip.fn(), "the actual rendered tooltip control publishes source metadata")
			helpers.assert_eq(require("toml_codec").decode(assert(read(f.alpha)))._meta.show_tooltip, true)
			helpers.assert_eq(f.Config.resolve(f.alpha_id, nil).show_tooltip, true)
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").show_tooltip, false, "the unselected section override retains its independent choice")
			local saved, status = f.Preferences.load(f.preferences); helpers.assert_eq(status, "ok")
			local projection = f.Preferences.project_hotstring_preferences(saved, f.Registry.list_groups(), f.Registry.get_sections)
			helpers.assert_eq(projection.section_states[f.alpha_id].probe, false)
		end)
	end)

	helpers.it("refuses held rendered callbacks after source replacement before any publication or editor activation", function()
		fixture(function(f)
			local menu = personal_menu(f); local file = menu.file("alpha"); local rows = file.menu or file.submenu
			local replacement = assert(read(f.alpha)) .. "# External source owner wins.\n"
			write(f.alpha, replacement)
			local before = #f.observations.writes
			for index = 1, 5 do helpers.assert_eq(rows[index].fn(), false, "held control " .. index .. " refuses stale source authority") end
			helpers.assert_eq(#f.observations.writes, before)
			helpers.assert_eq(read(f.alpha), replacement)
			helpers.assert_eq(menu.observations, { refreshes = 0, edits = 0 })
			helpers.assert_eq(f.Registry.is_group_enabled(f.alpha_id), true)
			helpers.assert_eq(f.Registry.is_group_enabled(f.beta_id), true)
			unavailable_scope(menu, menu.file("alpha"))
		end)
	end)

	helpers.it("renders an actually unreadable boot source as unavailable and refuses all file controls", function()
		fixture(function(f)
			local record = f.Loader.adoption(f.alpha_id)
			helpers.assert_eq(record.admitted, false, "actual classified source read refusal prevents adoption")
			local menu = personal_menu(f); local file = menu.file("alpha"); local rows = file.menu or file.submenu
			helpers.assert_true((file.title or file.label):find(menu.i18n.get("menu.hotstrings.personal_source_unavailable"), 1, true) ~= nil)
			for index = 1, 5 do
				helpers.assert_eq(rows[index].disabled, true)
				if rows[index].fn then helpers.assert_eq(rows[index].fn(), false) end
			end
			local reason = menu.i18n.get("menu.hotstrings.personal_file_unavailable")
			helpers.assert_true(reason ~= "menu.hotstrings.personal_file_unavailable")
			helpers.assert_eq(menu.manifest.get_array("personal_file_unavailable")[1].disabled_reason_key, "menu.hotstrings.personal_file_unavailable")
				helpers.assert_eq(rows[6].title, menu.i18n.get("healthcheck.state.unavailable") .. " — " .. assert(reason:match("^([^:]+):")))
			helpers.assert_eq(rows[6].disabled, true)
			unavailable_scope(menu, file)
			helpers.assert_eq(#f.observations.writes, 0)
			helpers.assert_eq(menu.observations, { refreshes = 0, edits = 0 })
		end, { setup = function(root, controls) controls.read_refusal = root .. "/alpha.toml" end })
	end)

	helpers.it("projects actual linked and depth-limited directories into translated readonly diagnostic rows without child discovery", function()
		local paths, directories, child_paths = {}, {}, {}
		fixture(function(f)
			local blocked = f.Loader.unavailable_directories()
			helpers.assert_eq(#blocked, 2)
			local reasons = {}; for _, record in ipairs(blocked) do reasons[record.reason] = record end
			helpers.assert_true(reasons["linked-directory"] ~= nil and reasons["scan-depth"] ~= nil)
			local menu = personal_menu(f); local rows = menu.build()
			local reason = menu.i18n.get("menu.hotstrings.personal_directory_unavailable")
			helpers.assert_true(reason ~= "menu.hotstrings.personal_directory_unavailable")
			for _, record in ipairs(blocked) do
				local row = assert(menu.find(rows, function(item) return (item.title or item.label) == record.label end))
				local children = row.menu or row.submenu
				helpers.assert_eq(#children, 1)
				helpers.assert_eq(children[1].disabled, true)
				helpers.assert_eq(menu.manifest.get_array("personal_directory_unavailable")[1].disabled_reason_key, "menu.hotstrings.personal_directory_unavailable")
					helpers.assert_eq(children[1].title, menu.i18n.get("healthcheck.state.unavailable") .. " — " .. assert(reason:match("^([^:]+):")))
				if children[1].fn then helpers.assert_eq(children[1].fn(), false) end
				for _, enumerated in ipairs(f.observations.enumerations) do
					helpers.assert_true(enumerated ~= record.path, "the actual scanner never enumerates a blocked directory")
				end
			end
			for _, path in ipairs(f.observations.reads) do
				for _, child in ipairs(child_paths) do helpers.assert_true(path ~= child, "blocked children never acquire source reads or ownership") end
			end
			helpers.assert_eq(#f.loaded, 3)
			helpers.assert_eq(#f.observations.writes, 0)
			local detached = f.Loader.unavailable_directories(); detached[1].reason = "foreign mutation"
			helpers.assert_true(f.Loader.unavailable_directories()[1].reason ~= "foreign mutation")
		end, { setup = function(root)
			local target = root .. "/_linked-target"; assert(lfs.mkdir(target)); directories[#directories + 1] = target
			local linked = root .. "/linked"; assert(lfs.link(target, linked, true)); paths[#paths + 1] = linked
			local linked_child = target .. "/hidden.toml"; write(linked_child, '[[probe]]\n"hidden" = "Linked child"\n')
			paths[#paths + 1] = linked_child; child_paths[#child_paths + 1] = linked .. "/hidden.toml"
			local deep = root
			for index = 1, Files.additional_scan_max_depth + 1 do
				deep = deep .. "/depth"; assert(lfs.mkdir(deep)); directories[#directories + 1] = deep
			end
			local deep_child = deep .. "/hidden.toml"; write(deep_child, '[[probe]]\n"hidden" = "Deep child"\n')
			paths[#paths + 1] = deep_child; child_paths[#child_paths + 1] = deep_child
			return function()
				for _, path in ipairs(paths) do assert(os.remove(path)) end
				for index = #directories, 1, -1 do assert(lfs.rmdir(directories[index])) end
			end
		end })
	end)
end)

helpers.describe("source-owned personal controls native publication", function()
	for _, section in ipairs({ false, "probe" }) do
		helpers.it("commits all four " .. (section or "file") .. " fields through the actual boot owners", function()
			fixture(function(f)
				local selected = section or nil
				for _, field in ipairs({ "delay", "color", "show_tooltip", "priority" }) do
					local value = ({ delay = 0.35, color = "#c0ffee", show_tooltip = true, priority = 60 })[field]
					helpers.assert_true(f.Controller.apply(f.binding(), selected, field, value), field .. " publication is acknowledged")
					local source = require("toml_codec").decode(assert(read(f.alpha)))
					local leaf = selected and source._meta.sections[selected] or source._meta
					helpers.assert_eq(leaf[field], value)
					helpers.assert_eq(f.Config.resolve(f.alpha_id, selected)[field], value, "the live resolver uses the published source field")
					local override = require("toml_codec").decode(assert(read(f.overrides)))
					helpers.assert_nil(override.personal_ext_alpha[field], "the file's masking legacy field is retired")
					if selected then helpers.assert_nil(override.personal_ext_alpha.probe[field]) end
					helpers.assert_eq(override.personal_ext_alpha.future, { keep = "unknown owner" })
					helpers.assert_eq(override.personal_ext_alpha.probe.future, "section neighbor")
					helpers.assert_eq(override.personal_ext_alpha.other.delay, 0.7)
					helpers.assert_eq(override.personal_ext_beta.priority, 40)
					helpers.assert_eq(override.foreign.future, "keep every neighbor")
					for _, bytes in ipairs({ '# Independent override notes.\n', 'future = { keep = "unknown owner" }\n',
						'future = "section neighbor"\n', '[personal_ext_alpha.other]\ndelay = 0.7\npriority = 25\n',
						'[foreign]\nfuture = "keep every neighbor"\n' }) do
						helpers.assert_true(read(f.overrides):find(bytes, 1, true) ~= nil, "unowned override bytes remain exact")
					end
					helpers.assert_true(read(f.alpha):find('# Independent personal source notes.\n', 1, true) ~= nil)
					helpers.assert_true(read(f.alpha):find('future = "source neighbor"\n', 1, true) ~= nil)
					helpers.assert_true(f.Loader.adoption_current(f.Loader.adoption(f.alpha_id)))
				end
			end)
		end)
	end
	helpers.it("changes the actual equal-trigger collision immediately and preserves sibling delay inheritance", function()
		fixture(function(f)
			helpers.assert_eq(f.winner(), "Beta")
			helpers.assert_true(f.Controller.apply(f.binding(), "probe", "priority", 60))
			local output, mapping = f.winner()
			helpers.assert_eq(output, "Alpha")
			helpers.assert_eq(mapping.priority, 60)
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "other").priority, 25)
			helpers.assert_eq(f.Config.resolve(f.beta_id, "probe").priority, 40)
			helpers.assert_true(f.Controller.apply(f.binding(), "probe", "delay", 0.3))
			helpers.assert_eq(f.state.SECTION_DELAYS[f.alpha_id].probe, 0.3)
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "other").delay, 0.7)
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").delay, 0.3)
			helpers.assert_eq(f.winner(), "Alpha")
		end)
	end)
	for _, disabled in ipairs({ "group", "section" }) do
		helpers.it("preserves a disabled " .. disabled .. " while publishing source metadata", function()
			fixture(function(f)
				if disabled == "group" then helpers.assert_true(f.Registry.disable_group(f.alpha_id))
				else helpers.assert_true(f.Registry.disable_section(f.alpha_id, "probe")) end
				helpers.assert_true(f.Controller.apply(f.binding(), "probe", "priority", 60))
				helpers.assert_eq(f.winner(), "Beta")
				if disabled == "group" then helpers.assert_eq(f.Registry.is_group_enabled(f.alpha_id), false)
				else helpers.assert_eq(f.Registry.is_section_enabled(f.alpha_id, "probe"), false) end
			end)
		end)
	end
	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("rolls back exact sources, collision and caches after source " .. refusal, function()
			fixture(function(f)
				local source, override = read(f.alpha), read(f.overrides)
				local resolved = f.Config.resolve(f.alpha_id, "probe")
				f.controls.source_refusal = refusal
				helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
				helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), override)
				helpers.assert_eq(f.winner(), "Beta")
				helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe"), resolved)
				local lease = {}; helpers.assert_true(f.Config.acquire(lease)); helpers.assert_true(f.Config.release(lease))
			end)
		end)
	end
	helpers.it("retains override inverse debt and blocks every subsequent edit until its exact inverse acknowledges", function()
		fixture(function(f)
			local source, override = read(f.alpha), read(f.overrides)
			f.controls.original_overrides, f.controls.source_refusal, f.controls.inverse_refusal = override, "false", true
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			helpers.assert_eq(read(f.alpha), source)
			helpers.assert_true(read(f.overrides) ~= override)
			helpers.assert_eq(f.winner(), "Beta")
			helpers.assert_nil(f.Controller.capture(f.alpha_id))
			helpers.assert_eq(f.Config.acquire({}), false, "unproved inverse retains the override owner's lease")
			helpers.assert_eq(f.Controller.retry_cleanup(), false)
			f.controls.inverse_refusal = false
			helpers.assert_true(f.Controller.retry_cleanup())
			helpers.assert_eq(read(f.overrides), override)
			local lease = {}; helpers.assert_true(f.Config.acquire(lease)); helpers.assert_true(f.Config.release(lease))
		end)
	end)
	helpers.it("refuses a lost post-publication physical receipt and restores the exact source before acknowledging", function()
		fixture(function(f)
			local source, override = read(f.alpha), read(f.overrides)
			f.controls.refuse_receipt = true
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), override)
			helpers.assert_eq(f.winner(), "Beta")
		end)
	end)
	helpers.it("retains source inverse debt until both original physical sources are restored", function()
		fixture(function(f)
			local source, override = read(f.alpha), read(f.overrides)
			f.controls.original_source, f.controls.original_overrides = source, override
			f.controls.refuse_receipt, f.controls.source_inverse_refusal = true, true
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			helpers.assert_true(read(f.alpha) ~= source)
			helpers.assert_true(read(f.overrides) ~= override)
			helpers.assert_eq(f.winner(), "Beta", "native publication rolls back despite outstanding physical source debt")
			helpers.assert_nil(f.Controller.capture(f.alpha_id))
			helpers.assert_eq(f.Config.acquire({}), false)
			helpers.assert_eq(f.Controller.retry_cleanup(), false)
			f.controls.source_inverse_refusal, f.controls.refuse_receipt, f.controls.read_refusal = false, false, nil
			helpers.assert_true(f.Controller.retry_cleanup())
			helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), override)
			helpers.assert_eq(f.winner(), "Beta")
			local lease = {}; helpers.assert_true(f.Config.acquire(lease)); helpers.assert_true(f.Config.release(lease))
			helpers.assert_true(f.Loader.adoption_current(f.Loader.adoption(f.alpha_id)))
		end)
	end)
	helpers.it("rejects a retained capability after an external physical source replacement without writing", function()
		fixture(function(f)
			local held, source, override = f.binding(), read(f.alpha), read(f.overrides)
			local external = source .. "# External source owner.\n"
			write(f.alpha .. ".owned-stage", external); assert(os.rename(f.alpha .. ".owned-stage", f.alpha))
			helpers.assert_eq(f.Controller.apply(held, "probe", "priority", 60), false)
			helpers.assert_eq(f.observations.publications, 0)
			helpers.assert_eq(#f.observations.writes, 0)
			helpers.assert_eq(read(f.alpha), external); helpers.assert_eq(read(f.overrides), override)
			helpers.assert_eq(f.winner(), "Beta")
		end)
	end)
	helpers.it("preserves foreign bytes that arrive at the final source CAS and restores only its owned override write", function()
		fixture(function(f)
			local source, override = read(f.alpha), read(f.overrides)
			local external = source .. "# Concurrent source owner.\n"
			f.controls.source_race = external
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			helpers.assert_eq(read(f.alpha), external); helpers.assert_eq(read(f.overrides), override)
			helpers.assert_eq(f.winner(), "Beta")
			local lease = {}; helpers.assert_true(f.Config.acquire(lease)); helpers.assert_true(f.Config.release(lease))
		end)
	end)
	for _, legacy in ipairs({ "explicit-false", "section-only", "override-only" }) do
		helpers.it("persists enable over " .. legacy .. " legacy choice through the actual menu, writer and boot readback", function()
			local legacy_group = legacy == "explicit-false" and "personal_ext_alpha = false\n" or ""
			local legacy_section = legacy == "section-only"
				and "[hotstrings.modules.personal_ext_alpha]\nprobe = false\nfuture_section = true\n" or ""
			local source = "# Durable legacy preference notes.\n[hotstrings.groups]\n" .. legacy_group
				.. "personal_ext_beta = true\nfuture_group = false\n" .. legacy_section
				.. '[future]\nkeep = "unowned preference neighbor"\n'
			fixture(function(f)
				local record = f.Loader.adoption(f.alpha_id)
				helpers.assert_eq(record.legacy_name, "personal_ext_alpha")
				helpers.assert_eq(f.Registry.is_group_enabled(f.alpha_id), false, "known old absence retains its neutral disabled posture")
				local projected = f.Preferences.project_hotstring_preferences(f.saved, f.Registry.list_groups(), f.Registry.get_sections)
				helpers.assert_eq(projected.hotstrings[f.alpha_id], false)
				local ctx = { keymap = f.Keymap, personal_root = f.root, personal_files = f.loaded, paused = false,
					state = { keymap = true, hotstrings = projected.hotstrings },
					updateMenu = function() return true end }
				local names = {}; for _, file in ipairs(f.loaded) do names[#names + 1] = file.name end
				ctx.save_prefs = function() return f.Preferences.save(f.preferences, ctx.state, names, { keymap = f.Keymap }) end
				local original_source, original_overrides = read(f.alpha), read(f.overrides)
				local menu = require("ui.menu.menu_hotstrings_custom")
				helpers.assert_true(menu.category_scope_fn(ctx, { f.alpha_id }, true)())
				helpers.assert_eq(f.Registry.is_group_enabled(f.alpha_id), true)
				local encoded = assert(read(f.preferences))
				local decoded = require("toml_codec").decode(encoded)
				helpers.assert_eq(decoded.hotstrings.groups[f.alpha_id], true, "canonical true is durable even though the fresh-source default is true")
				helpers.assert_eq(decoded.hotstrings.modules[f.alpha_id].probe, true)
				for _, bytes in ipairs({ "# Durable legacy preference notes.\n", "personal_ext_beta = true\n", "future_group = false\n",
					'[future]\nkeep = "unowned preference neighbor"\n', legacy_group, legacy_section }) do
					if bytes ~= "" then helpers.assert_true(encoded:find(bytes, 1, true) ~= nil, "the old preference owner retains exact bytes") end
				end
				helpers.assert_eq(read(f.alpha), original_source); helpers.assert_eq(read(f.overrides), original_overrides)
				local saved, status = f.Preferences.load(f.preferences); helpers.assert_eq(status, "ok")
				local readback = f.Preferences.project_hotstring_preferences(saved, f.Registry.list_groups(), f.Registry.get_sections)
				helpers.assert_eq(readback.hotstrings[f.alpha_id], true)
				helpers.assert_eq(readback.section_states[f.alpha_id].probe, true)
				helpers.assert_true(f.Keymap.disable_group(f.alpha_id))
				helpers.assert_true(f.Keymap.apply_hotstring_preferences(saved), "boot readback uses canonical intent before the old legacy choice")
				helpers.assert_eq(f.Registry.is_group_enabled(f.alpha_id), true)
				helpers.assert_eq(f.Registry.is_section_enabled(f.alpha_id, "probe"), true)
				helpers.assert_eq(f.Registry.is_group_enabled(f.beta_id), true)
			end, { preferences = source })
		end)
	end
	for _, changed in ipairs({ "new-source", "physical-alias" }) do
		helpers.it("refuses a retained menu cohort after " .. changed .. " before any publication", function()
			fixture(function(f)
				local selected; for _, file in ipairs(f.loaded) do if file.name == f.alpha_id then selected = file end end
				local ctx = { keymap = f.Keymap, personal_root = f.root, personal_files = f.loaded }
				local current = require("infra.personal_file_scope").bind(ctx, selected)
				local held = f.binding(); helpers.assert_true(current())
				local gamma = f.root .. "/gamma.toml"
				if changed == "physical-alias" then assert(lfs.link(f.alpha, gamma, false))
				else write(gamma, '[[probe]]\n"foreign" = "Foreign owner"\n') end
				ctx.personal_files[#ctx.personal_files + 1] = { name = Files.describe({ "gamma.toml" }).id,
					path = gamma, personal_source = Files.describe({ "gamma.toml" }) }
				helpers.assert_eq(current(), false)
				helpers.assert_eq(f.Controller.apply(held, "probe", "priority", 60), false)
				helpers.assert_eq(#f.observations.writes, 0)
				helpers.assert_eq(f.observations.publications, 0)
				helpers.assert_eq(f.winner(), "Beta")
			end)
		end)
	end
	for _, refusal in ipairs({ "false", "nil" }) do
		helpers.it("refuses source mutation authority when the native boot registration returns " .. refusal, function()
			fixture(function(f)
				local source, overrides = read(f.alpha), read(f.overrides)
				local record = f.Loader.adoption(f.alpha_id)
				helpers.assert_eq(record.admitted, false)
				helpers.assert_eq(record.reason, "native-registration-refused")
				helpers.assert_nil(f.Controller.capture(f.alpha_id))
				helpers.assert_nil(f.Keymap.personal_file_scope_binding(f.alpha_id))
				local projected = f.Preferences.project_hotstring_preferences(f.saved,
					{ [f.alpha_id] = false }, function() return { { name = "probe" } } end)
				helpers.assert_eq(projected.hotstrings[f.alpha_id], false)
				helpers.assert_eq(projected.section_states[f.alpha_id].probe, false)
				helpers.assert_eq(#f.observations.writes, 0)
				helpers.assert_eq(f.observations.publications, 0)
				helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), overrides)
				helpers.assert_eq(f.winner(), "Beta", "the admitted sibling keeps its real live mapping")
			end, { registration_refusal = refusal })
		end)
	end
	helpers.it("preserves the exact unsupported canonical override while retiring only the active legacy priority", function()
		local id = Files.describe({ "alpha.toml" }).id
		local unknown = '["' .. id .. '"]\npriority = 51\nfuture = "canonical raw neighbor"\n'
			.. '["' .. id .. '".probe]\npriority = 52\n# Retain this unsupported canonical block exactly.\n'
		local legacy = '[personal_ext_alpha]\npriority = 20\ncolor = "#aaaaaa"\nfuture = "legacy file neighbor"\n'
			.. '[personal_ext_alpha.probe]\npriority = 30\ndelay = 0.8\nfuture = "legacy section neighbor"\n'
		fixture(function(f)
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").priority, 30,
				"the actual native override parser admits the legacy owner and leaves quoted headers unknown")
			helpers.assert_eq(f.winner(), "Beta")
			helpers.assert_true(f.Controller.apply(f.binding(), "probe", "priority", 63))
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").priority, 63)
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").delay, 0.8)
			helpers.assert_eq(f.winner(), "Alpha", "the actual native collision uses the acknowledged metadata priority")
			local source = require("toml_codec").decode(assert(read(f.alpha)))
			helpers.assert_eq(source._meta.priority, 20, "the active legacy file priority transfers to preserve siblings")
			helpers.assert_eq(source._meta.sections.probe.priority, 63)
			local bytes = assert(read(f.overrides))
			helpers.assert_true(bytes:find(unknown, 1, true) ~= nil, "the unsupported canonical block stays byte exact")
			local parsed = require("toml_codec").decode(bytes)
			helpers.assert_eq(parsed[id].priority, 51); helpers.assert_eq(parsed[id].probe.priority, 52)
			helpers.assert_nil(parsed.personal_ext_alpha.priority)
			helpers.assert_nil(parsed.personal_ext_alpha.probe.priority)
			helpers.assert_eq(parsed.personal_ext_alpha.color, "#aaaaaa")
			helpers.assert_eq(parsed.personal_ext_alpha.probe.delay, 0.8)
			helpers.assert_true(bytes:find('future = "legacy section neighbor"\n', 1, true) ~= nil)
			helpers.assert_true(f.Config.reload())
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").priority, 63)
			helpers.assert_eq(f.winner(), "Alpha")
		end, { alpha_source = [=[[_meta]
priority = 10
[_meta.sections.probe]
priority = 15
[[probe]]
"collision" = { output = "Alpha", is_word = false, auto_expand = true, is_case_sensitive = true, is_case_sensitive_strict = true }
]=], override_source = legacy .. unknown })
	end)
	helpers.it("keeps the actual legacy section_delays typing delay when publishing only color", function()
		fixture(function(f)
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").delay, 0.42)
			helpers.assert_eq(f.state.SECTION_DELAYS[f.alpha_id].probe, 0.42)
			helpers.assert_true(f.Controller.apply(f.binding(), "probe", "color", "#abcdef"))
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").delay, 0.42)
			helpers.assert_eq(f.state.SECTION_DELAYS[f.alpha_id].probe, 0.42,
				"the live engine delay survives a newly introduced modern section metadata table")
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").color, "#abcdef")
			local source = assert(read(f.alpha))
			helpers.assert_true(source:find('[_meta.section_delays]\nprobe = 0.42 # Retain the historical typing delay.\n', 1, true) ~= nil)
			local parsed = require("toml_codec").decode(source)
			helpers.assert_nil(parsed._meta.sections.probe.delay, "a color edit must not rewrite another metadata field")
			helpers.assert_eq(parsed._meta.sections.probe.color, "#abcdef")
			helpers.assert_true(f.Config.reload())
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").delay, 0.42)
		end, { alpha_source = [=[[_meta]
delay = 0.1
priority = 10
[_meta.section_delays]
probe = 0.42 # Retain the historical typing delay.
[[probe]]
"collision" = { output = "Alpha", is_word = false, auto_expand = true, is_case_sensitive = true, is_case_sensitive_strict = true }
]=], override_source = [=[# Independent active legacy color overrides.
[personal_ext_alpha]
color = "#aaaaaa"
future = "legacy file neighbor"
[personal_ext_alpha.probe]
color = "#bbbbbb"
future = "legacy section neighbor"
]=] })
	end)
		helpers.it("refuses an owned metadata header case alias without changing the actual Team section", function()
		local source = [=[# Case-sensitive personal source notes.
[_meta]
delay = 0.1
priority = 10
[_meta.sections.team]
delay = 0.33
# Keep the orphan section metadata comment exactly.
future = "unknown orphan neighbor"
[[Team]]
"collision" = { output = "Alpha", is_word = false, auto_expand = true, is_case_sensitive = true, is_case_sensitive_strict = true }
]=]
		fixture(function(f)
			helpers.assert_eq(f.Loader.adoption(f.alpha_id).admitted, true)
			helpers.assert_eq(f.Registry.is_group_enabled(f.alpha_id), true)
			helpers.assert_eq(f.Registry.is_section_enabled(f.alpha_id, "Team"), true)
			local original, overrides = read(f.alpha), read(f.overrides)
			local resolved = f.Config.resolve(f.alpha_id, "Team")
			helpers.assert_eq(resolved.delay, 0.9, "Team inherits its file choice rather than the orphan lowercase metadata")
			helpers.assert_eq(f.Controller.apply(f.binding(), "Team", "delay", 0.3), false)
			helpers.assert_eq(#f.observations.writes, 0)
			helpers.assert_eq(f.observations.publications, 0)
			helpers.assert_eq(read(f.alpha), original); helpers.assert_eq(read(f.overrides), overrides)
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "Team"), resolved)
			helpers.assert_eq(f.Registry.is_section_enabled(f.alpha_id, "Team"), true)
			helpers.assert_eq(f.winner(), "Beta")
		end, { alpha_source = source })
	end)

		helpers.it("retains acknowledged source inverse until actual catalogue advance reads and acknowledges it", function()
		fixture(function(f)
			local source, override = read(f.alpha), read(f.overrides)
			local Adoption = require("infra.personal_file_adoption")
			local advance, refused, attempts = Adoption.advance, true, 0
			Adoption.advance = function(inventory, selected, content)
				if content ~= source then return false end -- Refuse the forward admission only.
				attempts = attempts + 1
				if not refused then return advance(inventory, selected, content) end
				f.controls.read_refusal = f.alpha
				local accepted = advance(inventory, selected, content)
				f.controls.read_refusal = nil
				return accepted
			end
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			helpers.assert_eq(attempts, 1, "the actual inverse adoption observes the controlled physical read refusal")
			helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), override)
			helpers.assert_eq(f.winner(), "Beta")
			helpers.assert_nil(f.Controller.capture(f.alpha_id))
			helpers.assert_eq(f.Config.acquire({}), false)
			helpers.assert_nil(f.Config.capture_terminal_admission(), "catalogue inverse debt prevents actual quit/reload admission")
			local writes = #f.observations.writes
			helpers.assert_eq(f.Controller.retry_cleanup(), false)
			helpers.assert_eq(attempts, 2)
			helpers.assert_eq(#f.observations.writes, writes, "a disk inverse ACK must never be replayed while only catalogue adoption is outstanding")
			refused = false
			helpers.assert_true(f.Controller.retry_cleanup())
			helpers.assert_eq(attempts, 3); helpers.assert_eq(#f.observations.writes, writes)
			helpers.assert_true(f.Loader.adoption_current(f.Loader.adoption(f.alpha_id)))
			local owner = {}; helpers.assert_true(f.Config.acquire(owner)); helpers.assert_true(f.Config.release(owner))
			terminal_available(f)
			Adoption.advance = advance
			helpers.assert_true(f.Controller.apply(f.binding(), "probe", "priority", 60))
			helpers.assert_eq(f.winner(), "Alpha")
		end)
	end)

		helpers.it("refuses a same-value public gate mutation inside the captured native source publisher", function()
		fixture(function(f)
			local source, override = read(f.alpha), read(f.overrides)
			local reentered = false
			f.controls.after_publish = function(path)
				if path ~= f.alpha then return end
				reentered = true
				helpers.assert_eq(f.Keymap.is_group_enabled(f.alpha_id), true)
				helpers.assert_true(f.Keymap.enable_group(f.alpha_id), "the actual public setter republishes the same visible choice")
			end
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			helpers.assert_true(reentered)
			helpers.assert_true(read(f.alpha) ~= source); helpers.assert_true(read(f.overrides) ~= override)
			helpers.assert_eq(f.winner(), "Alpha", "foreign native ownership prevents overwriting its candidate mappings")
			helpers.assert_eq(f.Registry.is_group_enabled(f.alpha_id), true)
			helpers.assert_eq(f.Registry.is_group_enabled(f.beta_id), true)
			helpers.assert_nil(f.Controller.capture(f.alpha_id))
			helpers.assert_nil(f.Keymap.capture_publication_owner())
			helpers.assert_eq(f.Config.acquire({}), false)
			helpers.assert_nil(f.Config.capture_terminal_admission(), "foreign native ownership retains actual terminal refusal")
			local writes = #f.observations.writes
			helpers.assert_eq(f.Controller.retry_cleanup(), false)
			helpers.assert_eq(#f.observations.writes, writes, "equal gates cannot authorize a foreign native or source inverse")
		end)
	end)

		helpers.it("(personal-native-receipt) retains actual forward rename release debt before exact source inverse", function()
		native_fixture(function(f)
			local source, override = read(f.alpha), read(f.overrides)
			f.controls.release_refusal = f.alpha
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			helpers.assert_eq(f.observations.renames[f.alpha], 1)
			helpers.assert_true(f.observations.held[f.alpha])
			helpers.assert_true(f.observations.unlocks[f.alpha] > 0 and f.observations.closes[f.alpha] > 0)
			helpers.assert_true(read(f.alpha) ~= source); helpers.assert_true(read(f.overrides) ~= override)
			helpers.assert_eq(f.winner(), "Beta", "the actual native registry journal rolls back before physical cleanup")
			helpers.assert_nil(f.Controller.capture(f.alpha_id)); helpers.assert_eq(f.Config.acquire({}), false)
			helpers.assert_nil(f.Config.capture_terminal_admission(), "forward release debt retains actual terminal refusal")
			local writes = #f.observations.writes
			helpers.assert_eq(f.Controller.retry_cleanup(), false)
			helpers.assert_eq(#f.observations.writes, writes, "retained native release prevents any inverse publication")
			f.controls.release_refusal = nil
			helpers.assert_true(f.Controller.retry_cleanup())
			helpers.assert_eq(f.observations.renames[f.alpha], 2)
			helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), override)
			helpers.assert_eq(f.observations.held[f.alpha], false)
			helpers.assert_true(f.Loader.adoption_current(f.Loader.adoption(f.alpha_id)))
			terminal_available(f)
			helpers.assert_true(f.Controller.apply(f.binding(), "probe", "priority", 60))
			helpers.assert_eq(f.winner(), "Alpha")
		end)
	end)

		helpers.it("(personal-native-receipt) settles actual prepublication release-only debt without a source inverse", function()
		native_fixture(function(f)
			local source, override = read(f.alpha), read(f.overrides)
			f.controls.release_refusal, f.controls.rename_refusal = f.alpha, f.alpha
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			helpers.assert_eq(read(f.alpha), source); helpers.assert_true(read(f.overrides) ~= override)
			helpers.assert_eq(f.observations.renames[f.alpha], 1)
			helpers.assert_true(f.observations.held[f.alpha])
			helpers.assert_nil(f.Controller.capture(f.alpha_id)); helpers.assert_eq(f.Config.acquire({}), false)
			helpers.assert_nil(f.Config.capture_terminal_admission(), "release-only debt retains actual terminal refusal")
			helpers.assert_eq(f.Controller.retry_cleanup(), false)
			f.controls.release_refusal, f.controls.rename_refusal = nil, nil
			helpers.assert_true(f.Controller.retry_cleanup())
			helpers.assert_eq(f.observations.renames[f.alpha], 1, "a source that never published has no inverse rename")
			helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), override)
			helpers.assert_eq(f.winner(), "Beta")
			helpers.assert_true(f.Loader.adoption_current(f.Loader.adoption(f.alpha_id)))
			local owner = {}; helpers.assert_true(f.Config.acquire(owner)); helpers.assert_true(f.Config.release(owner))
			terminal_available(f)
		end)
	end)

		helpers.it("(personal-native-receipt) retains actual inverse rename release debt until its own strict settlement", function()
		native_fixture(function(f)
			local source, override = read(f.alpha), read(f.overrides)
			f.controls.release_refusal = f.alpha
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			f.controls.release_refusal = nil
			f.controls.after_rename = function(path)
				if path == f.alpha and f.observations.renames[f.alpha] == 2 then f.controls.release_refusal = f.alpha end
			end
			helpers.assert_eq(f.Controller.retry_cleanup(), false)
			helpers.assert_eq(read(f.alpha), source); helpers.assert_true(read(f.overrides) ~= override)
			helpers.assert_eq(f.observations.renames[f.alpha], 2); helpers.assert_true(f.observations.held[f.alpha])
			helpers.assert_nil(f.Controller.capture(f.alpha_id)); helpers.assert_eq(f.Config.acquire({}), false)
			helpers.assert_nil(f.Config.capture_terminal_admission(), "inverse native release debt retains actual terminal refusal")
			local writes = #f.observations.writes
			helpers.assert_eq(f.Controller.retry_cleanup(), false); helpers.assert_eq(#f.observations.writes, writes)
			f.controls.release_refusal, f.controls.after_rename = nil, nil
			helpers.assert_true(f.Controller.retry_cleanup())
			helpers.assert_eq(f.observations.renames[f.alpha], 2, "an acknowledged inverse is not rewritten to settle its retained lock")
			helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), override)
			helpers.assert_eq(f.winner(), "Beta")
			helpers.assert_true(f.Loader.adoption_current(f.Loader.adoption(f.alpha_id)))
			terminal_available(f)
		end)
	end)

	helpers.it("(personal-native-receipt) retries only the retained terminal journal release after complete source acknowledgement", function()
		native_fixture(function(f)
			local capture = f.Keymap.capture_publication_owner
			local refused, releases = true, 0
			f.Keymap.capture_publication_owner = function()
				local owner = capture()
				if not owner then return nil end
				local release = owner.release
				owner.release = function()
					releases = releases + 1
					if refused then return false end -- Controlled ACK, actual private owner remains held.
					return release()
				end
				return owner
			end
			helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
			helpers.assert_eq(releases, 1)
			helpers.assert_eq(f.winner(), "Alpha", "complete source/native publication is preserved during release-only debt")
			helpers.assert_eq(f.Config.resolve(f.alpha_id, "probe").priority, 60)
			helpers.assert_true(f.Loader.adoption_current(f.Loader.adoption(f.alpha_id)))
			helpers.assert_nil(f.Controller.capture(f.alpha_id)); helpers.assert_eq(f.Config.acquire({}), false)
			helpers.assert_nil(f.Config.capture_terminal_admission(), "release-only scope ownership refuses actual quit/reload")
			local source, override, writes = read(f.alpha), read(f.overrides), #f.observations.writes
			helpers.assert_eq(f.Controller.retry_cleanup(), false); helpers.assert_eq(releases, 2)
			helpers.assert_eq(#f.observations.writes, writes)
			refused = false
			helpers.assert_true(f.Controller.retry_cleanup()); helpers.assert_eq(releases, 3)
			helpers.assert_eq(#f.observations.writes, writes, "final release cannot replay any acknowledged source or native inverse")
			helpers.assert_eq(read(f.alpha), source); helpers.assert_eq(read(f.overrides), override)
			helpers.assert_eq(f.winner(), "Alpha")
			terminal_available(f)
			helpers.assert_true(f.Controller.capture(f.alpha_id) ~= nil)
			f.Keymap.capture_publication_owner = capture
		end)
	end)

	for _, mismatch in ipairs({ "callback", "path" }) do
			helpers.it("(personal-native-receipt) refuses actual foreign " .. mismatch .. " capability despite identical candidate bytes", function()
			native_fixture(function(f)
				local source, override = read(f.alpha), read(f.overrides)
				f.controls.foreign_receipt = mismatch
				helpers.assert_eq(f.Controller.apply(f.binding(), "probe", "priority", 60), false)
				helpers.assert_true(read(f.alpha) ~= source); helpers.assert_true(read(f.overrides) ~= override)
				helpers.assert_eq(f.winner(), "Beta")
				local refused = false
				for _, view in ipairs(f.observations.views) do
					if view.path == f.alpha and not view.accepted then refused = true end
				end
				helpers.assert_true(refused, "the actual private native verifier rejects the mismatched invocation owner")
				helpers.assert_nil(f.Controller.capture(f.alpha_id)); helpers.assert_eq(f.Config.acquire({}), false)
				helpers.assert_nil(f.Config.capture_terminal_admission(), "unverified native capability cannot admit actual quit/reload")
				local candidate, writes = read(f.alpha), #f.observations.writes
				helpers.assert_eq(f.Controller.retry_cleanup(), false)
				helpers.assert_eq(#f.observations.writes, writes)
				helpers.assert_eq(read(f.alpha), candidate, "physical byte agreement never grants inverse authority to a foreign capability")
			end)
		end)
	end
end)
