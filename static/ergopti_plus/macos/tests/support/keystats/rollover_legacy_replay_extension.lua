--- tests/support/keystats/rollover_legacy_replay_extension.lua

--- Exercises a legacy context whose disposable raw cache lost the canonical row.
local json = require("json")
local function meta(db, key)
 local value
 for row in db:nrows("SELECT value FROM meta WHERE key='" .. key .. "';") do value = row.value end
 return value
end
return {
 before_ingest = function(manager, date)
  assert(manager.append_log({ type = "typing", timestamp = date .. " 23:59:58.000", app = "Editor",
   text = "hi", events = { { "h", 100, {} }, { "i", 100, {} } } }))
 end,
 before_rollover = function(db)
  local context = assert(json.decode(assert(meta(db, "ngram_ctx_json"))))
  assert(context.Editor and context.Editor.typing_date)
  context.Editor.typing_date = nil
  if os.getenv("ERGOPTI_LEGACY_RESET_MODE") == "legacy_already_reset" then
   context = {}
   assert(db:exec("UPDATE meta SET value='2026-10-21' WHERE key='today_log_date';") == 0)
  end
  local encoded = json.encode(context):gsub("'", "''")
  assert(db:exec("UPDATE meta SET value='" .. encoded .. "' WHERE key='ngram_ctx_json';") == 0)
  assert(db:exec("UPDATE meta SET value='3' WHERE key='aggregate_cache_revision';") == 0)
  assert(db:exec("DELETE FROM events_typing WHERE app='Editor';") == 0)
 end,
 after_rollover = function(db)
  assert(meta(db, "aggregate_cache_revision") == "0", "legacy cache cannot be certified before replay")
  local replay = json.decode(assert(meta(db, "local_ledger_replay")))
  assert(replay.offset == 0, "replay must start at ledger origin")
  for _ in db:nrows("SELECT id FROM events_typing WHERE app='Editor';") do error("raw cache row was not removed") end
 end,
 after_init = function(_, db, timers, errors)
  for _ = 1, 1000 do
   if meta(db, "aggregate_cache_revision") == "4" and meta(db, "local_ledger_replay") == nil then return end
   local count = #timers
   for index = 1, count do
    local timer = timers[index]
    if timer:running() and timer.seconds < 1 then timer.callback() end
   end
  end
  error("durable ledger replay did not certify recovery: " .. table.concat(errors, " | "))
 end,
 after_recovery = function(db)
  assert(meta(db, "aggregate_cache_revision") == "4")
  assert(meta(db, "local_ledger_replay") == nil)
  local total = 0
  for row in db:nrows("SELECT c FROM ngram_words WHERE date='2026-10-20' AND app='Editor' AND token='hi'") do total = total + row.c end
  assert(total == 1, "canonical replay must credit the old-day word once; observed " .. total)
 end,
}
