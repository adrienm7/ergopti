--- _shared/lua/test/hotstrings_scope_overrides_contract.lua

--- The Hotstrings scope leaves every bundled section on the manifest's recommended
--- delay, measured through the shared cascade over the real corpus files.
return function(helpers)
	local Manifest = require("infra.manifest_reader")
	local Planner = require("hotstrings.scope_overrides")
	local Resolver = require("hotstrings.delay_resolver")
	local Languages = require("hotstrings.languages")
	local Codec = require("toml_codec")
	local Extension = require("layouts.extension")
	local Extensions = require("hotstrings.extensions")
	local shared = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
		:match("^(.*)/lua/test/[^/]+$")
	assert(shared, "the shared tree must enclose this contract")

	local function read(path)
		local handle = io.open(path, "rb")
		if not handle then return nil end
		local content = handle:read("*a")
		handle:close()
		return content
	end
	local function decode_path(path)
		return assert(Codec.decode(assert(read(path), path)), path)
	end
	local function decode(relative) return decode_path(shared .. "/modules/hotstrings/" .. relative) end
	local default_delay = assert(tonumber(decode("defaults.toml").delays.default_sec))
	local index = decode("_index.toml")

	-- The real bundled inventory: the neutral files and every declared language
	-- pack, identified exactly as both Lua drivers register them.
	local corpus = {}
	for _, stem in ipairs(index.menu.categories_order) do
		corpus[#corpus + 1] = { id = stem, document = decode(stem .. ".toml") }
	end
	for _, pack in ipairs(Languages.packs(index)) do
		for _, stem in ipairs(pack.categories) do
			corpus[#corpus + 1] = { id = Languages.group_id(pack.id, stem),
				document = decode(pack.id .. "/" .. stem .. ".toml") }
		end
	end
	-- The Ergopti extension every driver ships (SFB reduction, rolls and the
	-- magic key's repeat corrections moved there), found and scanned by the
	-- shared resolvers the drivers use. Its files keep their historical
	-- category: a whole bound file is that category's corpus, and a bound
	-- section stays a section of its category, whose metadata it inherits.
	local family = assert(read(shared .. "/modules/layouts/defaults.json"), "layout defaults")
		:match('"ergopti_family"%s*:%s*"([^"]+)"')
	local shipped = Extension.shipped_root(shared .. "/../../layouts/registry/", { ergopti_family = family },
		function(path) return read(path) ~= nil end)
	local found = Extensions.scan({ assert(shipped, "the Ergopti extension ships with every driver") }, {
		list_dirs = function() return {} end,
		list_files = function(dir)
			local files = {}
			local listing = assert(io.popen('ls -1 "' .. dir .. '" 2>/dev/null'))
			for entry in listing:lines() do
				if entry:match("%.toml$") then files[#files + 1] = dir .. "/" .. entry end
			end
			listing:close()
			return files
		end,
		read_file = read,
	})
	local bound_sections = {}
	for _, pack in ipairs(found) do
		for _, file in ipairs(pack.bound_files) do
			local binding = file.binding
			if binding.sections == nil then
				corpus[#corpus + 1] = { id = binding.category, document = decode_path(file.path) }
			else
				bound_sections[binding.category] = bound_sections[binding.category] or {}
				for _, section in ipairs(binding.sections) do
					bound_sections[binding.category][section] = true
				end
			end
		end
	end
	local metas, groups = {}, {}
	for _, item in ipairs(corpus) do
		local meta = item.document._meta
		local sections, listed = {}, {}
		for name in pairs(meta.sections or {}) do
			sections[#sections + 1] = name
			listed[name] = true
		end
		for name in pairs(bound_sections[item.id] or {}) do
			if not listed[name] then sections[#sections + 1] = name end
		end
		table.sort(sections)
		metas[item.id] = meta
		groups[#groups + 1] = { id = item.id, override = { item.id }, sections = sections, bundled = true }
	end

	--- The corpus rung of the cascade, which is what a deleted override leaves.
	local function inherited(group, section)
		local meta = metas[group]
		local section_delay = meta.section_delays and meta.section_delays[section]
		return Resolver.resolve({ meta_category = meta,
			meta_section = section_delay ~= nil and { delay = section_delay } or nil,
			default_delay = default_delay }).delay
	end

	--- Applies planned changes to a user override tree, as each writer does.
	local function apply(tree, changes)
		for _, change in ipairs(changes) do
			local category = tree[change.override[1]] or {}
			tree[change.override[1]] = category
			local target = category
			if change.section then
				category.sections = category.sections or {}
				category.sections[change.section] = category.sections[change.section] or {}
				target = category.sections[change.section]
			end
			target[change.field] = change.value
		end
		return tree
	end

	--- A user who customised every owned field of every bundled section.
	local function customised()
		local tree = {}
		for _, group in ipairs(groups) do
			local entry = { delay = 9, color = "#123456", show_tooltip = false, priority = 7, sections = {} }
			for _, section in ipairs(group.sections) do
				entry.sections[section] = { delay = 8, color = "#654321", show_tooltip = false, priority = 6 }
			end
			tree[group.id] = entry
		end
		tree.not_installed = { delay = 3, sections = { kept = { delay = 4 } } }
		return tree
	end

	local function effective(tree, group, section)
		local user = tree[group] or {}
		local meta = metas[group]
		local section_delay = meta.section_delays and meta.section_delays[section]
		return Resolver.resolve({ user_category = user, user_section = (user.sections or {})[section],
			meta_category = meta, meta_section = section_delay ~= nil and { delay = section_delay } or nil,
			default_delay = default_delay })
	end

	local function plan(mode, overrides)
		local request = { mode = mode, features = Manifest.features(), groups = groups, inherited = inherited }
		for key, value in pairs(overrides or {}) do request[key] = value end
		return Planner.plan(request)
	end

	helpers.describe("hotstrings scope overrides: recommended delays", function()
		helpers.it("replays independent delay recommendations shared with the AHK owner", function()
			local fixture = assert(require("json").decode(assert(read(shared ..
				"/tests/corpus/hotstrings/scope_override_delay_vectors.json"))))
			for _, vector in ipairs(fixture.vectors) do
				local changes, recommendations = Planner.plan({ mode = vector.mode,
					features = fixture.features,
					groups = { { id = vector.id, override = { vector.id },
						sections = { vector.section }, bundled = vector.bundled } },
					inherited = function() return vector.inherited end })
				local expected = vector.expected
				helpers.assert_eq(#recommendations, expected ~= nil and 1 or 0, vector.name)
				local explicit = {}
				for _, change in ipairs(changes) do
					if change.value ~= nil then explicit[#explicit + 1] = change end
				end
				helpers.assert_eq(#explicit, expected ~= nil and 1 or 0, vector.name .. " writer ownership")
				if expected ~= nil then
					helpers.assert_eq(recommendations[1], { group = vector.id, section = vector.section,
						seconds = expected, inherited = vector.inherited }, vector.name)
					helpers.assert_eq(explicit[1].value, expected, vector.name)
				end
			end
		end)

		helpers.it("leaves every bundled section on the manifest recommendation after restore", function()
			local tree = apply(customised(), (plan("recommended")))
			local checked = 0
			for _, group in ipairs(groups) do
				for _, section in ipairs(group.sections) do
					local entry = Languages.section_feature(Manifest.features(), group.id, section)
					local seconds = entry and entry.recommended.time_activation_seconds
					local resolved = effective(tree, group.id, section)
					if seconds ~= nil then
						checked = checked + 1
						helpers.assert_eq(resolved.delay, seconds, group.id .. "." .. section)
					else
						helpers.assert_eq(resolved.delay, inherited(group.id, section), group.id .. "." .. section)
					end
					helpers.assert_eq(resolved.has_override, seconds ~= nil and seconds ~= inherited(group.id, section),
						group.id .. "." .. section .. " override ownership")
				end
			end
			helpers.assert_true(checked >= 30, "the manifest must recommend delays for the bundled corpus")
		end)

		helpers.it("writes the autocorrection recommendation that deletion would inherit as 1.0 s", function()
			local changes, recommendations = plan("recommended")
			for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
				helpers.assert_eq(inherited("autocorrection", section), 1.0, "the split preserves each family corpus delay")
			end
			local explicit = {}
			for _, change in ipairs(changes) do
				if change.value ~= nil then
					explicit[change.override[1] .. "." .. tostring(change.section) .. "." .. change.field] = change.value
				end
			end
			for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
				helpers.assert_eq(explicit["autocorrection." .. section .. ".delay"], 0.5, section .. " explicit recommendation")
			end
			helpers.assert_nil(explicit["autocorrection.caps.delay"], "the retired family is not a shipped recommendation")
			helpers.assert_eq(explicit["french_autocorrection.accents.delay"], 0.5)
			helpers.assert_eq(explicit["rolls.hc.delay"], nil, "an equal inheritance stays sparse")
			-- The historical ten differences were one common caps family and the
			-- nine French families below. Three replacements add exactly two rows;
			-- this independent membership list also refuses accidental additions.
			helpers.assert_eq(#recommendations, 12, "ten historical rows minus caps plus three common families")
			local reported = {}
			for _, row in ipairs(recommendations) do
				helpers.assert_true(row.inherited ~= row.seconds, row.group .. "." .. row.section)
				reported[#reported + 1] = row.group .. "." .. row.section
			end
			table.sort(reported)
			helpers.assert_eq(reported, { "autocorrection.abbreviations", "autocorrection.names", "autocorrection.technical_terms",
				"french_autocorrection.accents", "french_autocorrection.errors", "french_autocorrection.minus",
				"french_autocorrection.minus_apostrophe", "french_autocorrection.multiple_punctuation_marks",
				"french_autocorrection.names", "french_autocorrection.ou", "french_autocorrection.suffixes_a_chaining",
				"french_autocorrection.typographic_apostrophe" })
		end)

		helpers.it("returns every section to its corpus inheritance on clear", function()
			local changes, recommendations = plan("clear")
			helpers.assert_eq(#recommendations, 0)
			for _, change in ipairs(changes) do helpers.assert_nil(change.value, "clear only removes") end
			local tree = apply(customised(), changes)
			for _, group in ipairs(groups) do
				helpers.assert_nil(tree[group.id].delay)
				helpers.assert_nil(tree[group.id].color)
				for _, section in ipairs(group.sections) do
					local resolved = effective(tree, group.id, section)
					helpers.assert_eq(resolved.delay, inherited(group.id, section), group.id .. "." .. section)
					helpers.assert_eq(resolved.has_override, false, group.id .. "." .. section)
				end
			end
			helpers.assert_eq(tree.not_installed.delay, 3, "an unknown category survives")
			helpers.assert_eq(tree.not_installed.sections.kept.delay, 4, "an unknown section survives")
		end)
	end)

	helpers.describe("hotstrings scope overrides: ownership", function()
		helpers.it("never recommends a delay for a personal or extension pack", function()
			local user = { { id = "personal", override = { "personal" }, sections = { "code", "autocorrection" }, bundled = false } }
			local changes, recommendations = Planner.plan({ mode = "recommended", features = Manifest.features(),
				groups = user, inherited = function() return 0 end })
			helpers.assert_eq(#recommendations, 0)
			helpers.assert_eq(#changes, 12)
			for _, change in ipairs(changes) do helpers.assert_nil(change.value) end
		end)

		helpers.it("owns only the four override fields of listed tables and extras", function()
			local changes = Planner.plan({ mode = "clear", features = Manifest.features(),
				groups = { { id = "rolls", override = { "rolls" }, sections = { "hc" }, bundled = true } },
				inherited = inherited, extra = { { override = { "_global" }, fields = { "delay" } } } })
			local rows = Planner.writer_rows(changes)
			local found = {}
			for _, row in ipairs(rows) do
				helpers.assert_eq(row.delete, true)
				found[#found + 1] = row.section .. "." .. row.key
			end
			table.sort(found)
			helpers.assert_eq(found, { "_global.delay", "rolls.color", "rolls.delay", "rolls.hc.color", "rolls.hc.delay",
				"rolls.hc.priority", "rolls.hc.show_tooltip", "rolls.priority", "rolls.show_tooltip" })
		end)

		helpers.it("renders an extension identity as one quoted table segment", function()
			local rows = Planner.writer_rows(Planner.plan({ mode = "clear", features = Manifest.features(),
				groups = { { id = "ext:demo:rolls", override = { "ext:demo:rolls" }, sections = { "a.b" }, bundled = false } },
				inherited = inherited }))
			helpers.assert_eq(rows[1].section, '"ext:demo:rolls"')
			helpers.assert_eq(rows[5].section, '"ext:demo:rolls"."a.b"')
		end)

		helpers.it("refuses an unknown mode, a malformed group and a missing inheritance", function()
			local base = { mode = "clear", features = Manifest.features(), groups = {}, inherited = inherited }
			local function refused(changes)
				local request = {}
				for key, value in pairs(base) do request[key] = value end
				for key, value in pairs(changes) do request[key] = value end
				helpers.assert_eq(pcall(Planner.plan, request), false)
			end
			refused({ mode = "restore" })
			refused({ inherited = false })
			refused({ groups = { { id = "rolls", override = {}, sections = {}, bundled = true } } })
			refused({ groups = { { id = "rolls", override = { "rolls" }, sections = { "" }, bundled = true } } })
			refused({ groups = { { id = "rolls", override = { "rolls" }, sections = {}, bundled = true },
				{ id = "rolls", override = { "rolls" }, sections = {}, bundled = true } } })
			for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
				helpers.assert_eq(pcall(Planner.plan, { mode = "recommended", features = Manifest.features(),
					groups = { { id = "autocorrection", override = { "autocorrection" }, sections = { section }, bundled = true } },
					inherited = function() return nil end }), false, "an unknown inheritance cannot be compared: " .. section)
			end
		end)
	end)
end
