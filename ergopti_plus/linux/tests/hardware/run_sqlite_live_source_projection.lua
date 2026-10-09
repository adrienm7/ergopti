--- tests/hardware/run_sqlite_live_source_projection.lua
---
--- Public Linux live-source regression using owned native SQLite and software input.

-- Owned public live synthetic-source projection; real SQLite/software input.
local uv = require("luv")
require("compat.utf8").install()
local Json = require("json")
local owned = assert(uv.fs_mkdtemp("/tmp/ergopti-live-extra-source-XXXXXX"))
for _, name in ipairs({"CONFIG", "DATA", "CACHE", "STATE"}) do
 assert(uv.os_setenv("XDG_" .. name .. "_HOME", owned .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(owned .. "/config", 448))
assert(uv.fs_mkdir(owned .. "/config/ergopti", 448))
local config = assert(io.open(owned .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())
local K = require("modules.keylogger.keylogger")
local W = require("modules.keylogger.sqlite_writer")
local db = owned .. "/metrics.sqlite"
assert(K.init({ sqlite_path = db, log_dir = owned .. "/logs" }) ~= false)
assert(K.is_enabled() and W.is_available())
local checks, failures = 0, 0
local function check(name, fn)
 checks = checks + 1
 local ok, err = xpcall(fn, debug.traceback)
 print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ": " .. err))
 if not ok then failures = failures + 1 end
end
check("initial real SQLite has no ngrams", function()
 assert(W.query_rows("SELECT COUNT(*) FROM ngram_chars;")[1] == "0")
end)
K.record_synthetic_output("owned-flushed", "aa", "other", 1000)
K.flush()
check("ordinary other output reached real SQLite once", function()
 assert(W.query_rows("SELECT SUM(c),SUM(json_extract(esrc_json,'$.other')) FROM ngram_chars WHERE app='owned-flushed' AND token='a';")[1] == "2|2")
 local row = assert(K.get_range_payload().today["owned-flushed"].c.a)
 assert(row.c == 2 and row.o == 2 and row.hs == 0 and row.llm == 0)
end)
local vectors = {
 {app="owned-clipboard", source="clipboard", hs=0,llm=0,o=2},
 {app="owned-action", source="action", hs=0,llm=0,o=2},
 {app="owned-empty", source="", hs=0,llm=0,o=2},
 {app="owned-case", source="None", hs=0,llm=0,o=2},
 {app="owned-hotstring", source="hotstring", hs=2,llm=0,o=0},
 {app="owned-llm", source="llm", hs=0,llm=2,o=0},
 {app="owned-other", source="other", hs=0,llm=0,o=2},
 {app="owned-none", source="none", hs=0,llm=0,o=0},
}
for _, v in ipairs(vectors) do K.record_synthetic_output(v.app, "aa", v.source, 1100) end
K.on_keydown("a",1200,"owned-manual");K.on_keydown("a",1300,"owned-manual")
K.record_synthetic_output("owned-flushed", "aaa", "action", 1400)
local function tuple(payload, app, c, hs, llm, o)
 local row = assert(payload.today[app].c.a)
 print("OBSERVED " .. app .. " " .. Json.encode(row))
 assert(row.c == c, app .. " exact character count")
 assert(row.hs == hs and row.llm == llm and row.o == o, app .. " exact source tuple")
end
for _, v in ipairs(vectors) do
 check("public unflushed " .. v.app, function() tuple(K.get_range_payload(), v.app,2,v.hs,v.llm,v.o) end)
end
check("manual software input preserves no generated source",function() tuple(K.get_range_payload(),"owned-manual",2,0,0,0) end)
check("public extra label adds only pending delta to flushed other",function() tuple(K.get_range_payload(),"owned-flushed",5,0,0,5) end)
check("repeated range leaves pending extra source stable",function()
 for _=1,3 do tuple(K.get_range_payload(),"owned-action",2,0,0,2) end
end)
check("public dashboard prefetch retains extra source",function()
 local dashboard=K.get_dashboard_payload()
 assert(dashboard.driver_meta.os=="linux")
 tuple(dashboard._prefetch_data,"owned-clipboard",2,0,0,2)
end)
check("projections never flush pending software rows",function()
 assert(W.query_rows("SELECT COUNT(*) FROM ngram_chars WHERE app<>'owned-flushed';")[1]=="0")
 assert(W.query_rows("SELECT SUM(c) FROM ngram_chars WHERE app='owned-flushed' AND token='a';")[1]=="2")
end)
assert(checks==15,"native live source subject floor15")
W.close_db()
local function remove(path)
 local stat=assert(uv.fs_lstat(path))
 if stat.type=="directory" then
  for name in uv.fs_scandir_next,assert(uv.fs_scandir(path)) do remove(path.."/"..name) end
  assert(uv.fs_rmdir(path))
 else assert(uv.fs_unlink(path)) end
end
remove(owned)
print(string.format("Native public live source: %d checks, %d failures",checks,failures))
os.exit(failures==0 and 0 or 1)
