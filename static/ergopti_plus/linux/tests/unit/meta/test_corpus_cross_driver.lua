--- static/ergopti_plus/linux/tests/unit/meta/test_corpus_cross_driver.lua

--- ==============================================================================
--- MODULE: Cross-Driver Corpus Consumer (Linux)
--- DESCRIPTION:
--- Consumes the shared cross-driver test corpus vectors from
--- _shared/tests/corpus/ to verify ADR-006 compliance: every driver MUST
--- consume every cross-driver corpus. Vectors that cannot run on Linux are
--- explicitly SKIP-marked with a documented reason.
---
--- CORPORA CONSUMED:
--- 1. hotstrings/vectors.json         — shared hotstring engine (tested)
--- 2. tap_hold/vectors.json           — SKIP (kanata handles remapping on Linux)
--- 3. llm/parser_test_vectors.json    — SKIP (LLM engine not implemented on Linux)
--- 4. prompt_builder/vectors.json     — SKIP (PromptBuilder not wired on Linux)
--- 5. security/keylogger vectors      — partially tested (pure-logic paths)
--- 6. toml/fuzz_corpus.json           — tested (shared TOML codec)
--- 7. locale/resolution_vectors.json  — SKIP (Linux resolves via infra/locale.lua)
--- 8. tooltip/{layout,dequeue}         — SKIP (canonical layout math is JS)
--- 9. updater/release_parser_vectors.json — tested (full replay in
---    test_corpus_updater_release_parser.lua; parser used by manager.lua)
---
--- RATIONALE:
--- Even SKIP-marked vectors must be consumed (file loaded, vectors counted)
--- so the corpus is visible in the Linux test report and gaps are tracked
--- rather than silently absent. This mirrors the AHK approach in
--- meta/test_corpus_security_keylogger.ahk.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe = helpers.describe
local it       = helpers.it
local assert_true  = helpers.assert_true
local assert_eq    = helpers.assert_eq

local driver_root = helpers.driver_root()
local shared_root = driver_root .. "/../_shared"
local corpus_root = shared_root .. "/tests/corpus"




-- ===========================================
-- ===========================================
-- ======= 1/ JSON Loader (minimal) ==========
-- ===========================================
-- ===========================================

--- Minimal JSON-to-Lua parser for the corpus files.
--- Handles the simple subset used in the corpus: objects, arrays, strings,
--- numbers, booleans, null. Does not handle escaped unicode or numbers in
--- scientific notation — sufficient for the corpus format.
--- @param path string  Absolute path to the JSON file.
--- @return table|nil   Parsed Lua table, or nil + error string on failure.
local function load_json_corpus(path)
	local f = io.open(path, "r")
	if not f then return nil, "cannot open: " .. path end
	local raw = f:read("*a")
	f:close()
	-- Use _shared/lua/json.lua if available (bundled in the repo).
	local ok, json_mod = pcall(require, "json")
	if ok and json_mod and json_mod.decode then
		local decoded, err = json_mod.decode(raw)
		if decoded then return decoded end
		return nil, "json.decode error: " .. tostring(err)
	end
	-- Very minimal fallback: detect that the file is valid JSON by checking
	-- for the mandatory 'vectors' key via pattern match.
	if raw:find('"vectors"') then
		return { _raw = raw, _loaded = true }, nil
	end
	return nil, "no JSON parser available and file does not look like a corpus"
end

--- Returns the number of items in the 'vectors' array, or nil if missing.
--- @param data table  Parsed corpus table.
--- @return number|nil
local function vector_count(data)
	if type(data) ~= "table" then return nil end
	if type(data.vectors) == "table" then return #data.vectors end
	-- Fallback for the raw-string case: count "id" occurrences as proxy.
	if data._raw then
		local n = 0
		for _ in data._raw:gmatch('"id"') do n = n + 1 end
		return n
	end
	return nil
end




-- ====================================================
-- ====================================================
-- ======= 2/ Corpus 1 — Hotstrings (tested) ==========
-- ====================================================
-- ====================================================

describe("Corpus: hotstrings/vectors.json", function()
	local path = corpus_root .. "/hotstrings/vectors.json"

	it("corpus file exists on disk", function()
		assert_true(io.open(path, "r") ~= nil, "hotstrings corpus must exist at: " .. path)
	end)

	local data, err = load_json_corpus(path)

	it("corpus loads without error", function()
		assert_true(data ~= nil, "load error: " .. tostring(err))
	end)

	if data then
		local n = vector_count(data)
		it("corpus has at least 1 vector", function()
			assert_true(n ~= nil and n >= 1, "expected >=1 vectors, got: " .. tostring(n))
		end)

		-- The shared hotstring engine is loaded and tested in
		-- test_shared_hotstring_engine.lua; here we just validate corpus structure.
		it("corpus vectors have expected shape (id + description fields)", function()
			if type(data.vectors) ~= "table" then return end
			for _, v in ipairs(data.vectors) do
				assert_true(type(v.id) == "string", "vector missing 'id' field")
				assert_true(type(v.description) == "string", "vector " .. v.id .. " missing 'description'")
			end
		end)
	end
end)




-- ==========================================================
-- ==========================================================
-- ======= 3/ Corpus 2 — Tap-Hold (SKIP — kanata) ===========
-- ==========================================================
-- ==========================================================

describe("Corpus: tap_hold/vectors.json", function()
	local path = corpus_root .. "/tap_hold/vectors.json"

	it("corpus file exists on disk", function()
		assert_true(io.open(path, "r") ~= nil, "tap_hold corpus must exist at: " .. path)
	end)

	local data = load_json_corpus(path)
	local n    = data and vector_count(data) or 0

	it("corpus loaded: " .. tostring(n) .. " vector(s) present", function()
		assert_true(n ~= nil and n >= 1, "expected >=1 vectors in tap_hold corpus")
	end)

	-- A skip has to assert the reason it skipped for, or it is just a green with
	-- a sentence attached. Kanata reads the TOML config directly and emits
	-- uinput events, so there is genuinely no Lua tap-hold engine here — and the
	-- day someone writes one, this turns red rather than letting a whole corpus
	-- stay unreplayed behind a stale rationale.
	it("SKIP [CONF-LINUX-TAPHOLD] is still justified — no Lua tap-hold engine exists on Linux", function()
		local ok = pcall(require, "modules.tap_hold")
		assert_true(not ok,
			"modules.tap_hold now loads on Linux — replay the tap_hold corpus against it instead of skipping it")
	end)
end)




-- =====================================================================
-- =====================================================================
-- ======= 4/ Corpus 3 — LLM Parser (SKIP — not implemented) ===========
-- =====================================================================
-- =====================================================================

describe("Corpus: llm/parser_test_vectors.json", function()
	local path = corpus_root .. "/llm/parser_test_vectors.json"

	it("corpus file exists on disk", function()
		assert_true(io.open(path, "r") ~= nil, "llm/parser corpus must exist at: " .. path)
	end)

	local data = load_json_corpus(path)
	local n    = data and vector_count(data) or 0

	it("corpus loaded: " .. tostring(n) .. " vector(s) present", function()
		assert_true(n ~= nil and n >= 1, "expected >=1 vectors in llm/parser corpus")
	end)

	-- STALE RATIONALE, corrected 2026-07-31. This skip said "the LLM engine
	-- (api_ollama, api_remote, prediction_engine) has not been ported" — all
	-- three modules exist and load. What is actually missing is a Lua PARSER for
	-- the advanced-block reply format these vectors describe; the Linux engine
	-- consumes predictions without going through one. Asserting the real reason
	-- is what stops the rationale rotting again.
	it("SKIP [CONF-LINUX-LLM-PARSER] is still justified — Linux has no Lua reply parser to replay these vectors through", function()
		-- Required directly: if the engine this skip talks about has genuinely
		-- gone, the throw says so with the real error, and the rationale is wrong
		-- in the other direction.
		local engine = require("modules.llm.prediction_engine")
		assert_true(type(engine) == "table",
			"modules.llm.prediction_engine must return a module table — this skip's rationale is written around it existing")
		local ok, mod = pcall(require, "modules.llm.parser")
		assert_true(not ok or type(mod) ~= "table" or type(mod.process_prediction) ~= "function",
			"a Lua reply parser now exists on Linux — replay the llm/parser corpus against it instead of skipping it")
	end)
end)




-- ========================================================================
-- ========================================================================
-- ======= 5/ Corpus 4 — Prompt Builder (SKIP — not implemented) ===========
-- ========================================================================
-- ========================================================================

describe("Corpus: prompt_builder/vectors.json", function()
	local path = corpus_root .. "/prompt_builder/vectors.json"

	it("corpus file exists on disk", function()
		assert_true(io.open(path, "r") ~= nil, "prompt_builder corpus must exist at: " .. path)
	end)

	local data = load_json_corpus(path)
	local n    = data and vector_count(data) or 0

	it("corpus loaded: " .. tostring(n) .. " vector(s) present", function()
		assert_true(n ~= nil and n >= 1, "expected >=1 vectors in prompt_builder corpus")
	end)

	-- The skip's reason is that the Linux daemon does not LOAD the shared
	-- PromptBuilder, not that the module is missing — so that is what is
	-- checked. The day the daemon requires it, this turns red and the corpus
	-- gets replayed instead of skipped.
	it("SKIP [CONF-LINUX-PROMPT-BUILDER] is still justified — the Linux daemon does not load the shared PromptBuilder", function()
		local root = helpers.driver_root()
		local fh = io.open(root .. "/ergopti_hotstrings.lua", "r")
		assert_true(fh ~= nil, "the Linux entry point must be readable")
		local src = fh:read("*a"); fh:close()
		assert_true(src:find("llm.prompt_builder", 1, true) == nil,
			"the daemon now references llm.prompt_builder — replay the prompt_builder corpus against it instead of skipping it")
	end)
end)




-- =============================================================
-- =============================================================
-- ======= 6/ Corpus 5 — Security (partial) ====================
-- =============================================================
-- =============================================================

describe("Corpus: security/keylogger_no_persist_vectors.json", function()
	local path = corpus_root .. "/security/keylogger_no_persist_vectors.json"

	it("corpus file exists on disk", function()
		assert_true(io.open(path, "r") ~= nil, "security corpus must exist at: " .. path)
	end)

	local data = load_json_corpus(path)
	local n    = data and vector_count(data) or 0

	it("corpus loaded: >= 10 vectors", function()
		assert_true(n ~= nil and n >= 10, "expected >=10 security vectors, got: " .. tostring(n))
	end)

	-- SEC-001..006 are macOS-only (AX APIs, bundle IDs, private window detection).
	-- SEC-007..008 require a live keylogger session (cannot run headless anywhere).
	-- SEC-009 and SEC-010 are AHK-specific (Win32 ES_PASSWORD, UIA.IsPassword).
	-- STALE RATIONALE, corrected 2026-07-31. This skip said Linux secure-field
	-- detection was "not yet implemented" and called the adapter a stub. It is a
	-- real 157-line implementation exposing isSecureField and isSecureApp. The
	-- honest reason the vectors are skipped is the one stated above: every one of
	-- SEC-001..010 is macOS-only, AHK-specific, or needs a live session. So what
	-- is asserted here is that the Linux adapter exists and answers.
	it("the Linux SecureFieldDetector adapter exists and answers", function()
		-- Required directly, not through pcall: a failed require throws and fails
		-- this test with the real error, where asserting on a pcall status would
		-- prove only that require returned.
		local sfd = require("adapters.secure_field_detector")
		assert_true(type(sfd) == "table", "adapters.secure_field_detector must return a module table")
		assert_true(type(sfd.isSecureApp) == "function", "it must expose isSecureApp")
		assert_true(sfd.isSecureApp("") == false,
			"an empty app id must answer false rather than throw — the vectors above are skipped because they are macOS/AHK-specific, NOT because Linux lacks a detector")
	end)
end)




-- ===========================================================
-- ===========================================================
-- ======= 7/ Corpus 6 — TOML Fuzz (tested) ==================
-- ===========================================================
-- ===========================================================

describe("Corpus: toml/fuzz_corpus.json", function()
	local path = corpus_root .. "/toml/fuzz_corpus.json"

	it("corpus file exists on disk", function()
		assert_true(io.open(path, "r") ~= nil, "toml fuzz corpus must exist at: " .. path)
	end)

	local f = io.open(path, "r")
	local raw = f and f:read("*a") or ""
	if f then f:close() end

	-- Count top-level vector objects by counting '"input"' occurrences (the
	-- fuzz corpus uses this key for every entry). A null byte in one of the
	-- entries causes JSON.parse to fail in Node, so we use pattern matching.
	local entry_count = 0
	for _ in raw:gmatch('"input"') do entry_count = entry_count + 1 end

	it("corpus has at least 10 fuzz entries", function()
		assert_true(entry_count >= 10,
			"expected >=10 fuzz entries (counted 'input' keys), got: " .. entry_count)
	end)

	-- Attempt to load the shared TOML codec and exercise it against the fuzz
	-- corpus. The codec should not crash on any of the fuzz inputs.
	local toml_ok, toml_mod = pcall(require, "toml_codec.codec")

	it("shared TOML codec loads (_shared/lua/toml_codec/codec.lua)", function()
		assert_true(toml_ok, "toml_codec.codec must be requireable: " .. tostring(toml_mod))
	end)

	if toml_ok and toml_mod and raw ~= "" then
		-- Extract individual fuzz inputs by pattern — each entry has
		-- "input": "<value>" where value is a JSON string.
		local fuzz_inputs = {}
		for quoted in raw:gmatch('"input":%s*"(.-[^\\])"') do
			-- Unescape common JSON sequences
			local unescaped = quoted:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"')
			table.insert(fuzz_inputs, unescaped)
		end

		--- Decodes with whichever entry point this codec build exposes.
		local function decode(input)
			if toml_mod.decode then return toml_mod.decode(input) end
			return toml_mod.parse(input)
		end

		it("the fuzz corpus leaves the TOML codec able to parse valid input", function()
			-- The old assertion was assert_true(true) with the crash count in its
			-- message, and its own comment said "this assertion always passes".
			-- Rejecting malformed TOML is CORRECT behaviour, so the crash count is
			-- not the thing to assert on. What must hold is that no fuzz input
			-- leaves the codec broken for the next caller — a parser that
			-- corrupts module-level state on a malformed input is the real defect
			-- a fuzz corpus exists to find.
			assert_true(#fuzz_inputs > 0,
				"no fuzz input was extracted from the corpus — the regex above stopped matching, so this test measured nothing")

			for index, input in ipairs(fuzz_inputs) do
				local ok_call, result = pcall(decode, input)
				if not ok_call then
					error("fuzz input #" .. index .. " raised instead of returning nil: " .. tostring(result))
				end
			end

			-- Called directly: if the fuzz sweep left the codec unable to parse
			-- valid TOML, the throw IS the failure and carries the real error.
			local decoded = decode("[section]\nkey = \"value\"\n")
			assert_true(type(decoded) == "table" and type(decoded.section) == "table"
				and decoded.section.key == "value",
				"and it must still parse it CORRECTLY — a codec left in a broken state by a malformed input is what this corpus is for")
		end)
	end
end)





-- ===========================================
-- ===========================================
-- ======= 8/ Corpus 7 — Locale (SKIP) =======
-- ===========================================
-- ===========================================

describe("Corpus: locale/resolution_vectors.json", function()
	local path = corpus_root .. "/locale/resolution_vectors.json"

	it("corpus file exists on disk", function()
		assert_true(io.open(path, "r") ~= nil, "locale corpus must exist at: " .. path)
	end)

	local data = load_json_corpus(path)
	local n    = data and vector_count(data) or 0

	it("corpus loaded: " .. tostring(n) .. " vector(s) present", function()
		assert_true(n ~= nil and n >= 1, "expected >=1 vectors in locale corpus")
	end)

	it("SKIP [CONF-LINUX-LOCALE-CASCADE] — Linux resolves locales via infra/locale.lua (shared cascade replay is a roadmap item)", function()
		-- The shared locale.core cascade (active->en->fr with star substitution)
		-- is pinned by the macOS consumer (test_corpus_locale_resolution.lua). The
		-- Linux driver reads locale files through infra/locale.lua and does not yet
		-- replay the shared cascade; ADR-006 compliance here means the corpus is
		-- consumed (file loaded, vectors counted) with the gap tracked, not hidden.
		--
		-- The skip used to be assert_true(true), which made the gap indistinguishable
		-- from a passing replay. What IS checkable while the replay is missing: the
		-- driver has a locale resolver at all, and the corpus this case will one day
		-- consume is real. A skip that asserts nothing survives the arrival of the
		-- feature it is waiting for and goes on reporting a gap that closed.
		local resolver = io.open(driver_root .. "/infra/locale.lua", "r")
		assert_true(resolver ~= nil,
			"the resolver this skip defers to must exist — if infra/locale.lua is gone, the gap "
				.. "described here is not the gap that is real")
		if resolver then resolver:close() end
		assert_true(n >= 1,
			"and the corpus must carry vectors, or the replay this defers has nothing to replay")
	end)
end)





-- ================================================
-- ================================================
-- ======= 9/ Corpus 8 — Tooltip (replayed) =======
-- ================================================
-- ================================================

describe("Corpus: tooltip/{layout,dequeue}_vectors.json", function()
	local layout_path  = corpus_root .. "/tooltip/layout_vectors.json"
	local dequeue_path = corpus_root .. "/tooltip/dequeue_vectors.json"

	it("layout corpus file exists on disk", function()
		assert_true(io.open(layout_path, "r") ~= nil, "tooltip layout corpus must exist at: " .. layout_path)
	end)

	it("dequeue corpus file exists on disk", function()
		assert_true(io.open(dequeue_path, "r") ~= nil, "tooltip dequeue corpus must exist at: " .. dequeue_path)
	end)

	local data = load_json_corpus(layout_path)
	local n    = data and vector_count(data) or 0

	it("layout corpus loaded: " .. tostring(n) .. " vector(s) present", function()
		assert_true(n ~= nil and n >= 1, "expected >=1 vectors in tooltip layout corpus")
	end)

	-- The skip that used to sit here asserted that `require("modules.tooltip.layout")`
	-- FAILS, on the grounds that Linux had no Lua port of the layout maths. It
	-- does now — in _shared/lua/tooltip/layout.lua, shared with macOS — so the
	-- corpus is replayed against it instead. The vectors are the output of
	-- _shared/modules/tooltip/layout.js, which is the reference every driver has
	-- to agree with.
	--
	-- Driven with the geometry from the shared constants rather than with
	-- literals: the vectors were generated against those numbers, so a test
	-- carrying its own copy would pass while the driver drew somewhere else.
	local ok_layout, Layout = pcall(require, "tooltip.layout")
	local ok_style, Style = pcall(function()
		return require("ui.tooltip.config").load()
	end)

	it("the shared layout module and the style canon both load", function()
		assert_true(ok_layout, "tooltip.layout must be requirable: " .. tostring(Layout))
		assert_true(ok_style, "the tooltip style canon must load: " .. tostring(Style))
	end)

	if ok_layout and ok_style and data and data.vectors then
		local opts = {
			caret_offset_x  = Style.positioning.caret_offset_x,
			caret_offset_y  = Style.positioning.caret_offset_y,
			window_offset_y = Style.positioning.window_offset_y,
			screen_margin   = Style.layout.screen_margin,
		}

		for _, vector in ipairs(data.vectors) do
			it("layout vector " .. tostring(vector.id) .. " lands where the reference says", function()
				local got = Layout.compute_position(vector.anchor, vector.canvasSize, vector.screenFrame, opts)
				assert_eq(got.x, vector.expected.x,
					"x for " .. tostring(vector.id) .. " — " .. tostring(vector.description))
				assert_eq(got.y, vector.expected.y,
					"y for " .. tostring(vector.id) .. " — " .. tostring(vector.description))
			end)
		end
	end
end)





-- ===============================================
-- ===============================================
-- ======= 10/ Corpus 9 — Updater (tested) =======
-- ===============================================
-- ===============================================

describe("Corpus: updater/release_parser_vectors.json", function()
	local path = corpus_root .. "/updater/release_parser_vectors.json"

	it("corpus file exists on disk", function()
		assert_true(io.open(path, "r") ~= nil, "updater corpus must exist at: " .. path)
	end)

	local data = load_json_corpus(path)
	local n    = data and vector_count(data) or 0

	it("corpus has at least 1 vector", function()
		assert_true(n ~= nil and n >= 1, "expected >=1 updater vectors, got: " .. tostring(n))
	end)

	-- The shared updater.release_parser is loaded and every vector is replayed in
	-- test_corpus_updater_release_parser.lua (the Linux updater calls this parser
	-- in production via modules/updater/manager.lua). Here we only validate the
	-- corpus is present and well-formed so the cross-driver contract is visible in
	-- one place alongside the other corpora.
	it("corpus vectors have expected shape (id + category fields)", function()
		if type(data) ~= "table" or type(data.vectors) ~= "table" then return end
		for _, v in ipairs(data.vectors) do
			assert_true(type(v.id) == "string", "vector missing 'id' field")
			assert_true(type(v.category) == "string", "vector " .. tostring(v.id) .. " missing 'category'")
		end
	end)
end)
