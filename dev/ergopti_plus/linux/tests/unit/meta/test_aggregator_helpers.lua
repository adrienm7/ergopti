--- tests/unit/meta/test_aggregator_helpers.lua

local helpers     = require("tests.helpers")
local AggHelper   = helpers.load_module("keylogger.aggregator_helpers")

helpers.describe("aggregator_helpers", function()

  -- ==========================================================================
  -- 1. new_batch()
  -- ==========================================================================

  helpers.describe("new_batch()", function()
    helpers.it("returns a table", function()
      local b = AggHelper.new_batch()
      helpers.assert_true(type(b) == "table", "new_batch returns table")
    end)

    helpers.it("contains all expected sub-tables", function()
      local b = AggHelper.new_batch()
      local expected = {
        "app_day","ngram","kc_ngram","sc_ngram","kc_hold",
        "titles","hourly","hourly_min5","layouts","chars_class",
        "errors","ergo","bursts","sessions","app_buckets",
        "system_day","app_time","switches_to",
      }
      for _, k in ipairs(expected) do
        helpers.assert_true(type(b[k]) == "table", "batch." .. k .. " is table")
      end
    end)

    helpers.it("ngram sub-table has all n-gram levels", function()
      local b = AggHelper.new_batch()
      local ngram_keys = {
        "ngram_chars","ngram_bigrams","ngram_trigrams",
        "ngram_quadgrams","ngram_pentagrams","ngram_hexagrams",
        "ngram_heptagrams","ngram_words","ngram_word_bigrams",
      }
      for _, k in ipairs(ngram_keys) do
        helpers.assert_true(type(b.ngram[k]) == "table", "batch.ngram." .. k .. " is table")
      end
    end)

    helpers.it("creates independent copies", function()
      local a = AggHelper.new_batch()
      local b = AggHelper.new_batch()
      a.app_day.solo = { date = "2025-01-01", app = "test" }
      helpers.assert_true(b.app_day.solo == nil, "batches are independent")
    end)
  end)

  -- ==========================================================================
  -- 2. gc() — get-or-create
  -- ==========================================================================

  helpers.describe("gc()", function()
    helpers.it("creates a sub-table when key is absent", function()
      local t = {}
      local sub = AggHelper.gc(t, "foo", { x = 1 })
      helpers.assert_eq(sub.x, 1)
      helpers.assert_eq(t.foo.x, 1)
    end)

    helpers.it("returns existing sub-table when key is present", function()
      local t = { foo = { x = 42 } }
      local sub = AggHelper.gc(t, "foo")
      helpers.assert_eq(sub.x, 42)
    end)

    helpers.it("uses empty table as default when no default provided", function()
      local t = {}
      local sub = AggHelper.gc(t, "bar")
      helpers.assert_true(type(sub) == "table", "returns table")
      helpers.assert_true(t.bar == sub, "inserts into parent")
    end)
  end)

  -- ==========================================================================
  -- 3. bucket_add()
  -- ==========================================================================

  helpers.describe("bucket_add()", function()
    helpers.it("adds value to all buckets >= delay", function()
      local m = {}
      AggHelper.bucket_add(m, 1500, 1)
      -- 1500ms ≤ 2000ms, 3000ms, 5000ms, 10000ms, 20000ms, 30000ms, 60000ms
      -- NOT ≤ 1000ms
      helpers.assert_eq(m["1000"], nil)
      helpers.assert_eq(m["2000"], 1)
      helpers.assert_eq(m["3000"], 1)
      helpers.assert_eq(m["60000"], 1)
    end)

    helpers.it("adds value to all buckets when delay ≤ first bucket", function()
      local m = {}
      AggHelper.bucket_add(m, 100, 3)
      helpers.assert_eq(m["1000"], 3)
      helpers.assert_eq(m["60000"], 3)
    end)

    helpers.it("adds value to no buckets when delay > last bucket", function()
      local m = {}
      AggHelper.bucket_add(m, 99999, 5)
      helpers.assert_eq(m["1000"], nil)
      helpers.assert_eq(m["60000"], nil)
    end)

    helpers.it("accumulates multiple calls", function()
      local m = {}
      AggHelper.bucket_add(m, 500, 1)
      AggHelper.bucket_add(m, 500, 2)
      helpers.assert_eq(m["1000"], 3)
    end)

    helpers.it("supports custom bucket thresholds", function()
      local m = {}
      local custom = { 100, 500, 1000 }
      AggHelper.bucket_add(m, 300, 7, custom)
      helpers.assert_eq(m["100"], nil)
      helpers.assert_eq(m["500"], 7)
      helpers.assert_eq(m["1000"], 7)
    end)
  end)

  -- ==========================================================================
  -- 4. burst_length_bucket()
  -- ==========================================================================

  helpers.describe("burst_length_bucket()", function()
    helpers.it("maps to first matching boundary", function()
      helpers.assert_eq(AggHelper.burst_length_bucket(1), "1")
      helpers.assert_eq(AggHelper.burst_length_bucket(3), "5")
      helpers.assert_eq(AggHelper.burst_length_bucket(5), "5")
      helpers.assert_eq(AggHelper.burst_length_bucket(200), "200")
    end)

    helpers.it("returns '500+' for values beyond last bucket", function()
      helpers.assert_eq(AggHelper.burst_length_bucket(500), "500")
      helpers.assert_eq(AggHelper.burst_length_bucket(999), "500+")
      helpers.assert_eq(AggHelper.burst_length_bucket(99999), "500+")
    end)

    helpers.it("supports custom buckets", function()
      local custom = { 10, 50, 100 }
      helpers.assert_eq(AggHelper.burst_length_bucket(30, custom), "50")
      helpers.assert_eq(AggHelper.burst_length_bucket(200, custom), "100+")
    end)
  end)

  -- ==========================================================================
  -- 5. finalize_burst()
  -- ==========================================================================

  helpers.describe("finalize_burst()", function()
    helpers.it("no-ops on nil burst_cursor", function()
      local b = AggHelper.new_batch()
      AggHelper.finalize_burst(b, "2025-07-01", "vim", nil)
      helpers.assert_eq(next(b.bursts), nil)
    end)

    helpers.it("no-ops on zero-char burst", function()
      local b = AggHelper.new_batch()
      local cursor = { char_count = 0, sum_delays = 0, sum_delays_sq = 0 }
      AggHelper.finalize_burst(b, "2025-07-01", "vim", cursor)
      helpers.assert_eq(next(b.bursts), nil)
    end)

    helpers.it("records burst count and max_chars", function()
      local b = AggHelper.new_batch()
      local key = "2025-07-01\x01vim"
      AggHelper.finalize_burst(b, "2025-07-01", "vim", {
        char_count = 12, sum_delays = 600, sum_delays_sq = 30000,
      })
      helpers.assert_eq(b.bursts[key].count_total, 1)
      helpers.assert_eq(b.bursts[key].max_chars,  12)
    end)

    helpers.it("computes max CPM (chars ≥ MIN_BURST_FOR_CPM)", function()
      local b = AggHelper.new_batch()
      local key = "2025-07-01\x01vim"
      -- 12 chars, total delay 600ms → CPM = 12 * 60000 / 600 = 1200
      AggHelper.finalize_burst(b, "2025-07-01", "vim", {
        char_count = 12, sum_delays = 600, sum_delays_sq = 30000,
      })
      helpers.assert_eq(b.bursts[key].max_cpm, 1200)
    end)

    helpers.it("does NOT compute CPM for short bursts (below MIN_BURST_FOR_CPM)", function()
      local b = AggHelper.new_batch()
      local key = "2025-07-01\x01vim"
      AggHelper.finalize_burst(b, "2025-07-01", "vim", {
        char_count = 5, sum_delays = 500, sum_delays_sq = 25000,
      })
      helpers.assert_eq(b.bursts[key].max_cpm, 0)
    end)

    helpers.it("populates length_buckets", function()
      local b = AggHelper.new_batch()
      local key = "2025-07-01\x01vim"
      AggHelper.finalize_burst(b, "2025-07-01", "vim", {
        char_count = 3, sum_delays = 100, sum_delays_sq = 1000,
      })
      helpers.assert_eq(b.bursts[key].length_buckets["5"], 1)
    end)

    helpers.it("accumulates inter-keystroke metrics", function()
      local b = AggHelper.new_batch()
      local key = "2025-07-01\x01vim"
      AggHelper.finalize_burst(b, "2025-07-01", "vim", {
        char_count = 5, sum_delays = 400, sum_delays_sq = 40000,
      })
      helpers.assert_eq(b.bursts[key].inter_count, 4)   -- 5 chars → 4 inter-keystroke gaps
      helpers.assert_eq(b.bursts[key].inter_sum,   400)
      helpers.assert_eq(b.bursts[key].inter_sumsq, 40000)
    end)

    helpers.it("tracks max_cpm across multiple bursts", function()
      local b = AggHelper.new_batch()
      local key = "2025-07-01\x01vim"
      -- Burst 1: CPM = 12*60000/1200 = 600
      AggHelper.finalize_burst(b, "2025-07-01", "vim", {
        char_count = 12, sum_delays = 1200, sum_delays_sq = 0,
      })
      -- Burst 2: CPM = 20*60000/600 = 2000
      AggHelper.finalize_burst(b, "2025-07-01", "vim", {
        char_count = 20, sum_delays = 600, sum_delays_sq = 0,
      })
      helpers.assert_eq(b.bursts[key].count_total, 2)
      helpers.assert_eq(b.bursts[key].max_cpm,    2000)
      helpers.assert_eq(b.bursts[key].max_chars,  20)
    end)
  end)

  -- ==========================================================================
  -- 6. finalize_session()
  -- ==========================================================================

  helpers.describe("finalize_session()", function()
    helpers.it("no-ops on nil session_cursor", function()
      local b = AggHelper.new_batch()
      AggHelper.finalize_session(b, "2025-07-01", "vim", nil)
      helpers.assert_eq(next(b.sessions), nil)
    end)

    helpers.it("no-ops on zero-char session", function()
      local b = AggHelper.new_batch()
      AggHelper.finalize_session(b, "2025-07-01", "vim", {
        char_count = 0, total_ms = 0,
      })
      helpers.assert_eq(next(b.sessions), nil)
    end)

    helpers.it("records session count, longest, and total_active_ms", function()
      local b = AggHelper.new_batch()
      local key = "2025-07-01\x01vim"
      AggHelper.finalize_session(b, "2025-07-01", "vim", {
        char_count = 200, total_ms = 300000,
      })
      helpers.assert_eq(b.sessions[key].count_total,      1)
      helpers.assert_eq(b.sessions[key].longest_ms,       300000)
      helpers.assert_eq(b.sessions[key].longest_chars,    200)
      helpers.assert_eq(b.sessions[key].total_active_ms,  300000)
    end)

    helpers.it("collects durations up to the cap", function()
      local b = AggHelper.new_batch()
      local key = "2025-07-01\x01vim"
      for i = 1, 5 do
        AggHelper.finalize_session(b, "2025-07-01", "vim", {
          char_count = 10, total_ms = 10000 + i * 1000,
        })
      end
      -- durations cap defaults to 100, so all 5 fit
      helpers.assert_eq(#b.sessions[key].durations, 5)
      helpers.assert_eq(b.sessions[key].durations[1], 11000)
      helpers.assert_eq(b.sessions[key].durations[5], 15000)
    end)

    helpers.it("respects custom durations_cap", function()
      local b = AggHelper.new_batch()
      local key = "2025-07-01\x01vim"
      for i = 1, 5 do
        AggHelper.finalize_session(b, "2025-07-01", "vim", {
          char_count = 10, total_ms = 5000,
        }, 3)  -- cap at 3
      end
      helpers.assert_eq(#b.sessions[key].durations, 3)
    end)
  end)

  -- ==========================================================================
  -- 7. add_ngram_metric()
  -- ==========================================================================

  helpers.describe("add_ngram_metric()", function()
    helpers.it("creates a new entry and increments count", function()
      local b = AggHelper.new_batch()
      AggHelper.add_ngram_metric(b, "ngram_chars", "2025-07-01\x01vim\x01e", 80, false, "none")
      local item = b.ngram.ngram_chars["2025-07-01\x01vim\x01e"]
      helpers.assert_eq(item.c, 1)
      helpers.assert_eq(item.td, 80)
      helpers.assert_eq(item.cd, 1)
      helpers.assert_eq(item.e, 0)
    end)

    helpers.it("tracks errors separately from counts", function()
      local b = AggHelper.new_batch()
      AggHelper.add_ngram_metric(b, "ngram_chars", "k", 0, true, "none")
      local item = b.ngram.ngram_chars["k"]
      helpers.assert_eq(item.e, 1)
      helpers.assert_eq(item.c, 0)
    end)

    helpers.it("tracks error source by synthetic type", function()
      local b = AggHelper.new_batch()
      AggHelper.add_ngram_metric(b, "ngram_chars", "k", 0, true, "hotstring")
      local item = b.ngram.ngram_chars["k"]
      helpers.assert_eq(item.esrc["hotstring"], 1)
      helpers.assert_eq(item.e, 1)
    end)

    helpers.it("tracks synthetic type on non-error events too", function()
      local b = AggHelper.new_batch()
      AggHelper.add_ngram_metric(b, "ngram_chars", "k", 0, false, "hotstring")
      local item = b.ngram.ngram_chars["k"]
      helpers.assert_eq(item.esrc["hotstring"], 1)
      helpers.assert_eq(item.c, 1)
      -- Synthetic non-error: td and cd NOT incremented (delay=0)
      helpers.assert_eq(item.cd, 0)
    end)

    helpers.it("no-ops on non-existent ngram table", function()
      local b = AggHelper.new_batch()
      -- Should not crash
      AggHelper.add_ngram_metric(b, "nonexistent_table", "k", 0, false, "none")
      helpers.assert_true(true)  -- survived
    end)
  end)

  -- ==========================================================================
  -- 8. push_ngram()
  -- ==========================================================================

  helpers.describe("push_ngram()", function()
    helpers.it("composes key from date, app, and token", function()
      local b = AggHelper.new_batch()
      AggHelper.push_ngram(b, "ngram_bigrams", "2025-07-01", "vim", "ab", 50, false, "none")
      local key = "2025-07-01\x01vim\x01ab"
      helpers.assert_eq(b.ngram.ngram_bigrams[key].c, 1)
      helpers.assert_eq(b.ngram.ngram_bigrams[key].td, 50)
    end)

    helpers.it("works with special characters in token", function()
      local b = AggHelper.new_batch()
      AggHelper.push_ngram(b, "ngram_chars", "2025-07-01", "vim", "é", 30, false, "none")
      local key = "2025-07-01\x01vim\x01é"
      helpers.assert_eq(b.ngram.ngram_chars[key].c, 1)
    end)
  end)

  -- ==========================================================================
  -- 9. bump_app_day()
  -- ==========================================================================

  helpers.describe("bump_app_day()", function()
    helpers.it("creates row and increments field", function()
      local b = AggHelper.new_batch()
      AggHelper.bump_app_day(b, "2025-07-01", "vim", "chars", 5)
      local key = "2025-07-01\x01vim"
      helpers.assert_eq(b.app_day[key].date, "2025-07-01")
      helpers.assert_eq(b.app_day[key].app,  "vim")
      helpers.assert_eq(b.app_day[key].chars, 5)
    end)

    helpers.it("accumulates multiple increments to same field", function()
      local b = AggHelper.new_batch()
      AggHelper.bump_app_day(b, "2025-07-01", "vim", "chars", 3)
      AggHelper.bump_app_day(b, "2025-07-01", "vim", "chars", 7)
      local key = "2025-07-01\x01vim"
      helpers.assert_eq(b.app_day[key].chars, 10)
    end)

    helpers.it("supports multiple distinct fields", function()
      local b = AggHelper.new_batch()
      AggHelper.bump_app_day(b, "2025-07-01", "vim", "chars", 5)
      AggHelper.bump_app_day(b, "2025-07-01", "vim", "errors", 2)
      local key = "2025-07-01\x01vim"
      helpers.assert_eq(b.app_day[key].chars, 5)
      helpers.assert_eq(b.app_day[key].errors, 2)
    end)
  end)

  -- ==========================================================================
  -- 10. get_app_ctx()
  -- ==========================================================================

  helpers.describe("get_app_ctx()", function()
    helpers.it("creates a new context for an unknown app", function()
      local ngram_ctx = {}
      local ctx = AggHelper.get_app_ctx(ngram_ctx, "vim")
      helpers.assert_true(type(ctx) == "table", "returns a table")
      helpers.assert_eq(ctx.p1, nil)
      helpers.assert_eq(ctx.cur_word, "")
      helpers.assert_eq(ctx.word_err, false)
      helpers.assert_eq(type(ctx.current_burst), "nil")  -- starts as nil
      helpers.assert_eq(type(ctx.current_session), "nil")
      helpers.assert_eq(ctx.bs_run_len, 0)
      helpers.assert_eq(ctx.last_was_bs, false)
      helpers.assert_eq(ctx.last_finger, nil)
      helpers.assert_eq(ctx.same_finger_run, 0)
      helpers.assert_eq(ctx.same_hand_run, 0)
    end)

    helpers.it("returns the SAME context on subsequent calls (mutation shared)", function()
      local ngram_ctx = {}
      local a = AggHelper.get_app_ctx(ngram_ctx, "vim")
      local b = AggHelper.get_app_ctx(ngram_ctx, "vim")
      helpers.assert_true(a == b, "same table reference")
    end)

    helpers.it("maintains separate contexts per app", function()
      local ngram_ctx = {}
      local vim_ctx  = AggHelper.get_app_ctx(ngram_ctx, "vim")
      local code_ctx = AggHelper.get_app_ctx(ngram_ctx, "vscode")
      helpers.assert_true(vim_ctx ~= code_ctx)
      vim_ctx.p1 = "e"
      code_ctx.p1 = "i"
      helpers.assert_eq(vim_ctx.p1, "e")
      helpers.assert_eq(code_ctx.p1, "i")
    end)

    helpers.it("handles nil ngram_ctx gracefully", function()
      local ctx = AggHelper.get_app_ctx(nil, "vim")
      helpers.assert_true(type(ctx) == "table", "returns empty table")
    end)
  end)

  -- ==========================================================================
  -- 11. Constants
  -- ==========================================================================

  helpers.describe("constants", function()
    helpers.it("exports CONTENT_KCS as a table", function()
      helpers.assert_true(type(AggHelper.CONTENT_KCS) == "table", "CONTENT_KCS is table")
      helpers.assert_true(#AggHelper.CONTENT_KCS > 0, "has entries")
    end)

    helpers.it("exports UI_PAUSE_BUCKETS_MS ascending", function()
      local b = AggHelper.UI_PAUSE_BUCKETS_MS
      for i = 2, #b do
        helpers.assert_true(b[i] > b[i-1], "buckets ascending")
      end
    end)
  end)

end)
