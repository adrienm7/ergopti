--- _shared/lua/test/hotstring_family_samples.lua

--- ==============================================================================
--- MODULE: Shipped Hotstring Family Samples
--- DESCRIPTION:
--- Resolves _shared/tests/corpus/hotstrings/family_samples.json into vectors
--- of the hotstrings/vectors.json shape, reading each sample's entry from the
--- SHIPPED file through toml_codec.reader, the parser both Lua drivers load
--- their hotstring packs with. The E2E harnesses replay the result exactly as
--- they replay the engine corpus, so a renamed, removed or re-flagged shipped
--- entry fails the run, and so does a manifest family left without samples.
--- ==============================================================================

local Json   = require("json")
local Reader = require("toml_codec.reader")

local M = {}

--- Samples each family of the menu manifest needs, so a new family cannot
--- ship without the data pin this corpus exists for.
M.MIN_SAMPLES_PER_FAMILY = 2

-- The per-entry flags the harnesses register, as vectors.json names them.
local FLAGS = { "is_word", "auto_expand", "is_case_sensitive", "is_case_sensitive_strict", "final_result" }

--- Reads one file whole, failing with its path.
--- @param path string
--- @return string
local function read(path)
	local handle, open_error = io.open(path, "rb")
	if not handle then error("cannot read " .. path .. ": " .. tostring(open_error), 0) end
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Finds one entry of a parsed pack by section and trigger.
--- @param data table A toml_codec.reader document.
--- @param sample table One corpus sample.
--- @return table entry
local function shipped_entry(data, sample)
	local section = data.sections[sample.section]
	if type(section) ~= "table" or type(section.entries) ~= "table" then
		error(string.format("%s: %s has no section [[%s]]", sample.id, sample.file, sample.section), 0)
	end
	for _, entry in ipairs(section.entries) do
		if entry.trigger == sample.trigger then return entry end
	end
	error(string.format("%s: [[%s]] of %s no longer ships the trigger %q",
		sample.id, sample.section, sample.file, sample.trigger), 0)
end

--- Loads the samples and resolves each one against its shipped file.
--- @param static_root string Absolute path of the repository's static/ directory.
--- @return table vectors In corpus order, each shaped like a vectors.json vector.
function M.load(static_root)
	assert(type(static_root) == "string" and static_root ~= "", "the static/ root is required")
	local shared = static_root .. "/ergopti_plus/_shared"
	local corpus = Json.decode(read(shared .. "/tests/corpus/hotstrings/family_samples.json"))
	local manifest = Json.decode(read(shared .. "/modules/menu/menu_manifest.json"))
	local families = assert(manifest.hotstring_category_keys, "the menu manifest lists no hotstring families")
	local excluded = corpus.excluded_families or {}
	assert(type(corpus.samples) == "table" and #corpus.samples > 0, "family_samples.json has no samples")

	local documents, counts, ids, vectors = {}, {}, {}, {}
	for index, sample in ipairs(corpus.samples) do
		assert(type(sample.id) == "string" and sample.id ~= "", "sample " .. index .. " has no id")
		assert(not ids[sample.id], "sample " .. sample.id .. " is listed twice")
		ids[sample.id] = true
		if families[sample.family] == nil then
			error(sample.id .. ": '" .. tostring(sample.family) .. "' is no hotstring family of the menu manifest", 0)
		end
		if excluded[sample.family] ~= nil then
			error(sample.id .. ": the family '" .. sample.family .. "' is excluded, it cannot be sampled", 0)
		end
		local data = documents[sample.file]
		if data == nil then
			local committed
			data, committed = Reader.parse(static_root .. "/" .. sample.file)
			if not committed then error(sample.id .. ": " .. sample.file .. " does not parse", 0) end
			documents[sample.file] = data
		end
		local entry = shipped_entry(data, sample)
		local vector = {
			id          = "family." .. sample.id,
			trigger     = entry.trigger,
			replacement = entry.output,
			buffer      = sample.buffer,
			terminator  = sample.terminator,
			expected    = sample.expected,
		}
		for _, flag in ipairs(FLAGS) do vector[flag] = entry[flag] == true end
		vectors[#vectors + 1] = vector
		counts[sample.family] = (counts[sample.family] or 0) + 1
	end

	for family in pairs(families) do
		if excluded[family] ~= nil then
			if type(excluded[family]) ~= "string" or excluded[family] == "" then
				error("the excluded family '" .. family .. "' gives no reason", 0)
			end
		elseif (counts[family] or 0) < M.MIN_SAMPLES_PER_FAMILY then
			error(string.format("the hotstring family '%s' has %d shipped sample(s); at least %d are required",
				family, counts[family] or 0, M.MIN_SAMPLES_PER_FAMILY), 0)
		end
	end
	for family in pairs(excluded) do
		if families[family] == nil then
			error("the excluded family '" .. family .. "' is no hotstring family of the menu manifest", 0)
		end
	end
	return vectors
end

return M
