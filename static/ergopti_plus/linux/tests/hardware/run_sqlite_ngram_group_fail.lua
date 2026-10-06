--- tests/hardware/run_sqlite_ngram_group_fail.lua
--- ==============================================================================
--- MODULE: Native Ngram Group Statement-Failure Regression (Linux)
--- DESCRIPTION:
--- Actual public Writer groups and trigger effects settle on SQLite refusal.
--- ==============================================================================

--- Actual public Writer multirow SQLite FAIL diagnostic; supplied software metrics.
local uv = require('luv')
require('compat.utf8').install()
local Json = require('json')
local W = require('modules.keylogger.sqlite_writer')
local root = assert(os.getenv('OWN_NGRAM_FAIL_ROOT'))
assert(uv.fs_mkdir(root, 448))
assert(W.open_db(root .. '/metrics.sqlite'))
assert(W.register_device('owned-device', 'owned', 'linux', 'audit', 'owned'))
assert(W.exec_sql('CREATE TABLE owned_trigger_effect(app TEXT, token TEXT);'))
local date = '2026-10-05'
local group = {
 alpha = {c=3,td=20,cd=2,e=1,sources={hotstring=1,addon=2}},
 beta = {c=5,td=40,cd=3,e=2,sources={llm=2,addon=3}},
}
local order={}
for token in pairs(group) do order[#order+1]=token end
assert(#order==2)
local receipts={}
for _, spec in ipairs({{'first','FAIL',1},{'last','FAIL',2},{'abort','ABORT',2}}) do
 local app,mode,bad = spec[1],spec[2],order[spec[3]]
 assert(W.upsert_ngrams('owned-device',date,app,{
  alpha={c=10,td=100,cd=5,e=3,sources={addon=4}},
  beta={c=20,td=200,cd=6,e=4,sources={addon=5}},
 }))
 assert(W.exec_sql("CREATE TRIGGER owned_ngram_failure BEFORE INSERT ON ngram_chars BEGIN "
  .. "INSERT INTO owned_trigger_effect VALUES (NEW.app,NEW.token); "
  .. "SELECT CASE WHEN NEW.app='"..app.."' AND NEW.token='"..bad.."' "
  .. "THEN RAISE("..mode..", 'owned-ngram-refusal') END; END;"))
 local accepted=W.upsert_ngrams('owned-device',date,app,group)
 assert(W.exec_sql("VACUUM INTO '"..root.."/"..app.."-refused.sqlite';"))
 assert(W.exec_sql('DROP TRIGGER owned_ngram_failure;'))
 assert(W.upsert_ngrams('owned-device',date,app,group))
 assert(W.exec_sql("VACUUM INTO '"..root.."/"..app.."-retry.sqlite';"))
 receipts[app]={accepted=accepted,bad=bad,mode=mode}
end
local healthy=W.upsert_ngrams('owned-device',date,'healthy',group)
assert(W.exec_sql("VACUUM INTO '"..root.."/healthy.sqlite';"))
local version=assert(W.query_rows('SELECT sqlite_version();'))[1]
W.close_db()
print(Json.encode({root=root,order=order,receipts=receipts,healthy=healthy,
 runtime=_VERSION,libuv=uv.version_string(),sqlite=version}))
