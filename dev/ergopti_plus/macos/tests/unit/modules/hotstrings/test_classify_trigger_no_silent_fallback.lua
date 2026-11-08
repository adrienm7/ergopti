--- tests/unit/modules/hotstrings/test_classify_trigger_no_silent_fallback.lua

--- ==============================================================================
--- MODULE: Regression — the @-collector must not silently fall back to three scans
--- DESCRIPTION:
--- `classify_trigger` answers "is this string an exact trigger / a prefix of one /
--- a suffix of one" in ONE pass over the corpus, and its result is memoised. The
--- @-collector calls it, but behind `if _keymap.classify_trigger then` — and the
--- else branch ran `has_exact_trigger`, `has_trigger_prefix` and
--- `has_trigger_suffix` as three separate full-corpus scans, none of them memoised.
---
--- ROOT CAUSE ENCODED:
--- A hardcoded behavioural fallback for a function that is always exported
--- (`keymap/init.lua` assigns `M.classify_trigger = Registry.classify_trigger`).
--- Convention 5.4 forbids exactly this: a missing dependency must fail loudly, not
--- quietly select a slower path with different caching behaviour. The branch could
--- only ever be reached through a partial `_keymap` injection — i.e. a wiring
--- mistake — and it would then hide that mistake behind three silent scans instead
--- of reporting it.
---
--- The real registered interceptor is exercised with an admitted classifier and a
--- missing one. Its own diagnostic must be observable; an unrelated neighboring
--- Logger.error cannot certify this dependency boundary.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The collector is located by its state constant rather than by a path.
local ANCHOR = "STATE_COLLECTING"

-- The three single-purpose predicates the fallback used.
local SCAN_PREDICATES = {
	"has_exact_trigger",
	"has_trigger_prefix",
	"has_trigger_suffix",
}

--- Boots the actual owner and drives its registered callback with modeled keys.
--- @param source string Reviewed module bytes, optionally one controlled mutation.
--- @param claim string|nil Which classifier flag claims the trigger; nil means missing.
--- @return table record Observed classifier calls, diagnostics and expansion intents.
local function probe(source, claim)
	local target = "modules.dynamic_hotstrings.personal_info"
	return helpers.with_stub_scope({ target, "infra.logger", "modules.keystats", "ui.personal_info_editor",
		"adapters.synthetic_input", "adapters.file_system", "infra.personal_info_fields" }, function()
		local record = { errors = {}, queries = {}, attempts = 0, scans = 0 }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, format, ...) record.errors[#record.errors + 1] = string.format(format, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["modules.keystats"], package.loaded["ui.personal_info_editor"] = {}, {}
		package.loaded["adapters.synthetic_input"] = {
			emit_key_stroke = function() return true end, emit_key_strokes = function() return true end,
		}
		local interceptor
		local keymap = {
			get_trigger_char = function() return "★" end,
			register_interceptor = function(callback) interceptor = callback end,
			register_preview_provider = function() end,
			inject_dynamic = function() record.attempts = record.attempts + 1; return true end,
		}
		for _, name in ipairs(SCAN_PREDICATES) do
			keymap[name] = function() record.scans = record.scans + 1; error("unmemoised fallback scan") end
		end
		if claim then
			keymap.classify_trigger = function(trigger)
				record.queries[#record.queries + 1] = trigger
				return claim == "exact", claim == "prefix", claim == "suffix"
			end
		end
		local previous_loader = package.preload[target]
		package.preload[target] = function() return assert(load(source, "reviewed personal-info owner"))() end
		local loaded, owner = pcall(helpers.load_with_stubs, target)
		package.preload[target] = previous_loader
		if not loaded then error(owner, 0) end
		local path = os.tmpname()
		local file = assert(io.open(path, "w"))
		assert(file:write('[info]\nfirst_name = "Alice"\n[letters]\np = "first_name"\n'))
		assert(file:close())
		local called, failure = xpcall(function()
			helpers.assert_true(owner.start("", keymap, path, function(_, publish) return publish() end))
			helpers.assert_type(interceptor, "function", "the real owner must publish its interceptor")
			local function key(char)
				return { getFlags = function() return {} end, getKeyCode = function() return 0 end,
					getCharacters = function() return char end }
			end
			interceptor(key("@"), "prefix")
			interceptor(key("p"), "@")
			record.terminal = interceptor(key("★"), "@p")
		end, debug.traceback)
		owner.stop()
		os.remove(path)
		if not called then error(failure, 0) end
		return record
	end)
end

--- Requires the diagnostic emitted by the missing dependency's actual branch.
local function assert_missing_classifier(record)
	helpers.assert_eq(#record.errors, 1, "missing classifier must report its own wiring error")
	helpers.assert_contains(record.errors[1], "keymap.classify_trigger is missing")
	helpers.assert_contains(record.errors[1], "prefix@")
	helpers.assert_eq(record.scans, 0)
	helpers.assert_eq(#record.queries, 0)
end





-- ==================================================================
-- ==================================================================
-- ======= 1/ One classifier, and it is required ====================
-- ==================================================================
-- ==================================================================

helpers.describe("@-collector: no silent fallback to per-predicate scans", function()

	helpers.it("does not call the three single-purpose predicates", function()
		local src = helpers.read_driver_source(ANCHOR)
		helpers.assert_true(src ~= nil and src ~= "",
			"the @-collector must be locatable by '" .. ANCHOR .. "'; an empty corpus would "
			.. "make every assertion below vacuous")

		-- Comments stripped: the prose that explains why the single-pass classifier
		-- replaced these three names mentions all three.
		local code = src:gsub("%-%-[^\n]*", "")

		local offenders = {}
		for _, name in ipairs(SCAN_PREDICATES) do
			if code:find(name, 1, true) then table.insert(offenders, name) end
		end

		helpers.assert_eq(#offenders, 0,
			"each of these walks the whole mapping corpus and none is memoised, so the "
			.. "fallback was three uncached full scans where the classifier does one cached "
			.. "pass. It is also unreachable in production - keymap always exports "
			.. "classify_trigger - so its only effect was to hide a partial injection "
			.. "behind a slower path: " .. table.concat(offenders, ", "))
	end)

	helpers.it("still calls the single-pass classifier", function()
		local code = helpers.read_driver_source(ANCHOR):gsub("%-%-[^\n]*", "")

		-- Without this case the assertion above would pass against a collector that
		-- stopped classifying altogether, which would let a trigger already claimed by
		-- a static hotstring be collected as a dynamic one.
		helpers.assert_true(code:find("classify_trigger", 1, true) ~= nil,
			"the collector must still ask whether the trigger is already claimed")
	end)

	helpers.it("reports a missing classifier instead of working around it", function()
		assert_missing_classifier(probe(assert(helpers.read_driver_unit(ANCHOR)), nil))
	end)

	helpers.it("the real single-pass classifier refuses every claimed trigger and admits an unclaimed one", function()
		local source = assert(helpers.read_driver_unit(ANCHOR))
		for _, claim in ipairs({ "exact", "prefix", "suffix", "unclaimed" }) do
			local record = probe(source, claim)
			helpers.assert_eq(#record.errors, 0)
			helpers.assert_eq(record.scans, 0)
			if claim == "unclaimed" then
				helpers.assert_eq(record.queries, { "prefix@", "@p★" })
				helpers.assert_eq(record.attempts, 1)
				helpers.assert_eq(record.terminal, "consume")
			else
				helpers.assert_eq(record.queries, { "prefix@" })
				helpers.assert_eq(record.attempts, 0)
				helpers.assert_nil(record.terminal)
			end
		end
	end)

	helpers.it("rejects a missing-classifier diagnostic downgraded to debug", function()
		local source = assert(helpers.read_driver_unit(ANCHOR))
		local needle = 'Logger.error(LOG, "keymap.classify_trigger is missing'
		local first = assert(source:find(needle, 1, true))
		helpers.assert_nil(source:find(needle, first + 1, true), "the mutant must target one diagnostic")
		local mutated = source:sub(1, first - 1) .. "Logger.debug" .. source:sub(first + #"Logger.error")
		local record = probe(mutated, nil)
		local accepted, failure = pcall(assert_missing_classifier, record)
		helpers.assert_eq(accepted, false, "a silent mutant must fail the same behavioral assertion")
		helpers.assert_contains(failure, "missing classifier must report its own wiring error")
	end)

end)
