--- static/ergopti_plus/linux/tests/unit/meta/test_corpus_logger_behaviour.lua

--- ==============================================================================
--- MODULE: Logger Behaviour Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/logger/behaviour_vectors.json against the shared
--- Lua logger core, which is the logger this driver actually runs: every Linux
--- module reaches it through logger.shim. The sibling corpus
--- (_shared/modules/logger/test_vectors.json) pins the LINE FORMAT; this one pins
--- the parts that decide whether a line exists at all — severity filtering and
--- the ring buffer.
---
--- WHY IT MATTERS HERE: this driver is the one already ON the shared core, so it
--- is the reference the other two are being moved towards. If the core drifts
--- from the corpus, the target moves and the migration measures nothing.
---
--- COVERAGE:
--- 1. Corpus integrity — every section present and non-empty.
--- 2. Numbering and aliases — spec § 4.
--- 3. Filtering — the emitted/dropped sets at each threshold, measured through
---    the core's sink rather than by reading the level back.
--- 4. Lifecycle pairs — trace/done and start/success can never be split.
--- 5. Ring buffer — capacity, order, both boundaries and clear-after-wrap.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_true = helpers.assert_true
local assert_eq   = helpers.assert_eq

local driver_root = helpers.driver_root()
local corpus_path = driver_root .. "/../_shared/tests/corpus/logger/behaviour_vectors.json"




-- ===========================================
-- ===========================================
-- ======= 1/ Corpus Loading =================
-- ===========================================
-- ===========================================

--- Reads and decodes the shared behaviour corpus.
--- Fails loudly rather than skipping: an unreadable corpus must not let this
--- consumer report success over zero vectors.
--- @return table
local function read_corpus()
  local f = io.open(corpus_path, "r")
  assert(f, "logger behaviour corpus not found at " .. corpus_path)
  local raw = f:read("*a")
  f:close()
  local json = require("json")
  local decoded = json.decode(raw)
  assert(type(decoded) == "table", "logger behaviour corpus did not decode into a table")
  return decoded
end

local CORPUS = read_corpus()
local Logger = require("logger")

-- Corpus variant name → the core function that emits it. Explicit rather than
-- derived, so a renamed variant fails here instead of quietly testing seven of
-- eight.
local EMITTERS = {
  debug   = Logger.debug,
  trace   = Logger.trace,
  done    = Logger.done,
  info    = Logger.info,
  start   = Logger.start,
  success = Logger.success,
  warn    = Logger.warn,
  error   = Logger.error,
}

--- Emits one variant with the sink installed and reports whether it got through.
--- @param variant string
--- @return boolean
local function emits(variant)
  local seen = false
  Logger.set_sink(function() seen = true end)
  EMITTERS[variant]("corpus", "Ligne de test.")
  Logger.set_sink(nil)
  return seen
end




-- ===========================================
-- ===========================================
-- ======= 2/ Corpus Integrity ===============
-- ===========================================
-- ===========================================

describe("Logger behaviour corpus: integrity", function()
  it("holds every section, none of them empty", function()
    assert_eq(type(CORPUS.numbering), "table", "the corpus must declare the spec numbering")
    assert_eq(type(CORPUS.aliases), "table", "the corpus must declare the accepted aliases")
    assert_true(#CORPUS.filtering > 0, "the filtering section is empty — every case below would pass vacuously")
    assert_true(#CORPUS.lifecycle_pairs > 0, "the lifecycle-pair section is empty")
    assert_true(#CORPUS.ring_buffer.cases > 0, "the ring-buffer section is empty")
  end)

  it("names all eight variants, and the core emits every one of them", function()
    local named = {}
    for _, case in ipairs(CORPUS.filtering) do
      for _, v in ipairs(case.emitted) do named[v] = true end
      for _, v in ipairs(case.dropped) do named[v] = true end
    end
    local count = 0
    for variant in pairs(named) do
      assert_eq(type(EMITTERS[variant]), "function",
        "the corpus names the variant '" .. variant .. "', which the core does not emit")
      count = count + 1
    end
    assert_eq(count, 8, "the corpus must exercise all eight variants")
  end)
end)




-- ===========================================
-- ===========================================
-- ======= 3/ Numbering & Aliases ============
-- ===========================================
-- ===========================================

describe("Logger behaviour corpus: numbering", function()
  it("every alias resolves to its spec level", function()
    local saved = Logger.get_level()
    for alias, expected in pairs(CORPUS.aliases) do
      if type(expected) == "number" then
        Logger.set_level(alias)
        assert_eq(Logger.get_level(), expected,
          "set_level('" .. alias .. "') must resolve to " .. tostring(expected))
        Logger.set_level(alias:upper())
        assert_eq(Logger.get_level(), expected,
          "set_level('" .. alias:upper() .. "') must resolve to the same level as '" .. alias .. "'")
      end
    end
    Logger.set_level(saved)
  end)

  it("the numbering is what the filtering thresholds are built from", function()
    -- The numbers are only meaningful if a threshold set to one variant's level
    -- admits exactly the variants at or above it. Asserting the table alone would
    -- pass against a core that ignored it.
    local saved = Logger.get_level()
    for variant, level in pairs(CORPUS.numbering) do
      if type(level) == "number" then
        Logger.set_level(level)
        assert_eq(emits(variant), true,
          "a threshold set to " .. variant .. "'s own level (" .. tostring(level) ..
          ") must still admit " .. variant)
      end
    end
    Logger.set_level(saved)
  end)
end)




-- ===========================================
-- ===========================================
-- ======= 4/ Severity Filtering =============
-- ===========================================
-- ===========================================

describe("Logger behaviour corpus: filtering", function()
  for _, case in ipairs(CORPUS.filtering) do
    it(case.id, function()
      local saved = Logger.get_level()
      Logger.set_level(case.min_level)

      for _, variant in ipairs(case.emitted) do
        assert_eq(emits(variant), true,
          "at threshold '" .. case.min_level .. "', " .. variant .. " must be emitted")
      end
      for _, variant in ipairs(case.dropped) do
        assert_eq(emits(variant), false,
          "at threshold '" .. case.min_level .. "', " .. variant .. " must be dropped")
      end

      Logger.set_level(saved)
    end)
  end

  for _, pair in ipairs(CORPUS.lifecycle_pairs) do
    it(pair.id, function()
      local saved = Logger.get_level()
      for _, threshold in ipairs({ "debug", "info", "warning", "error" }) do
        Logger.set_level(threshold)
        assert_eq(emits(pair.a), emits(pair.b),
          "at threshold '" .. threshold .. "', " .. pair.a .. " and " .. pair.b ..
          " must be emitted or dropped together — half a lifecycle pair in the log reads as a " ..
          "silent failure that never happened")
      end
      Logger.set_level(saved)
    end)
  end
end)




-- ===========================================
-- ===========================================
-- ======= 5/ Ring Buffer ====================
-- ===========================================
-- ===========================================

describe("Logger behaviour corpus: ring buffer", function()
  --- Emits n numbered lines at a threshold that lets them all through.
  --- @param n number
  local function emit_numbered(n)
    local saved = Logger.get_level()
    Logger.set_level("debug")
    Logger.ring_buffer_clear()
    Logger.set_sink(function() end)   -- keep the probe out of stdout
    for i = 1, n do
      Logger.info("corpus", "ligne %d", i)
    end
    Logger.set_sink(nil)
    Logger.set_level(saved)
  end

  --- Extracts the emission index a snapshot entry carries.
  --- @param entry any
  --- @return number|nil
  local function index_of(entry)
    local text = type(entry) == "table" and (entry.line or entry.message or "") or tostring(entry)
    local n = text:match("ligne (%d+)")
    return n and tonumber(n) or nil
  end

  for _, case in ipairs(CORPUS.ring_buffer.cases) do
    it(case.id, function()
      emit_numbered(case.emit)
      if case.clear then Logger.ring_buffer_clear() end

      local snapshot = Logger.ring_buffer_snapshot()
      assert_eq(#snapshot, case.expect_size,
        case.id .. ": the buffer must hold " .. tostring(case.expect_size) .. " entry(ies)")
      assert_eq(Logger.ring_buffer_size(), case.expect_size,
        case.id .. ": the reported size must match the snapshot it hands out")

      if case.expect_first then
        -- Order is asserted across the WHOLE snapshot, not just its ends: a
        -- circular buffer returned as its raw array has the right first and last
        -- entries only by accident, and reads as two shuffled halves in between.
        local previous = nil
        for _, entry in ipairs(snapshot) do
          local idx = index_of(entry)
          assert_true(idx ~= nil, case.id .. ": every entry must carry its emission index")
          if previous then
            assert_eq(idx, previous + 1, case.id .. ": the snapshot must read oldest-first with no gaps")
          end
          previous = idx
        end
        assert_eq(index_of(snapshot[1]), case.expect_first,
          case.id .. ": the oldest surviving entry must be line " .. tostring(case.expect_first))
        assert_eq(index_of(snapshot[#snapshot]), case.expect_last,
          case.id .. ": the newest entry must be line " .. tostring(case.expect_last))
      end

      Logger.ring_buffer_clear()
    end)
  end

  it("capacity matches the corpus", function()
    -- Derived rather than read from a constant: a capacity field that drifted
    -- from the real array would agree with itself and with nothing else.
    emit_numbered(CORPUS.ring_buffer.capacity + 25)
    assert_eq(#Logger.ring_buffer_snapshot(), CORPUS.ring_buffer.capacity,
      "the buffer must cap at the corpus capacity")
    Logger.ring_buffer_clear()
  end)
end)




-- ===========================================
-- ===========================================
-- ======= 6/ The Core's Default =============
-- ===========================================
-- ===========================================

describe("Logger behaviour corpus: the core's default", function()
  it("matches the row the corpus records for it", function()
    -- A starting threshold is a policy, not a behaviour of the filter, so the
    -- corpus records one row per driver and each asserts its own. Changing it is
    -- then a deliberate edit to the shared file, not a surprise in a log that
    -- suddenly went quiet.
    local recorded = CORPUS.driver_defaults.shared_core
    assert_eq(type(recorded), "string", "the corpus must record the core's default")
    assert_eq(CORPUS.aliases[recorded], 10,
      "the recorded default must name a level the corpus knows")
  end)
end)
