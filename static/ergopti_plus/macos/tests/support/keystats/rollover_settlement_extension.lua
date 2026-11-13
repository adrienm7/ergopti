--- tests/support/keystats/rollover_settlement_extension.lua

--- Adds an unfinished word to the real rollover process fixture.
return {
 before_ingest = function(manager, date)
  local db = assert(require("metrics.engine.journal.sqlite_writer").get_db())
  assert(db:exec("UPDATE meta SET value='6' WHERE key='aggregate_cache_revision'") == 0)
  assert(manager.append_log({ type = "typing", timestamp = date .. " 23:59:58.000", app = "Editor",
   text = "hi", events = { { "h", 100, {} }, { "i", 100, {} } } }))
 end,
 after_recovery = function(db)
  local total = 0
  for row in db:nrows("SELECT c FROM ngram_words WHERE date='2026-10-20' AND app='Editor' AND token='hi'") do total = total + row.c end
  assert(total == 1, "recovered rollover must credit old-day word exactly once; observed " .. total)
 end,
}
