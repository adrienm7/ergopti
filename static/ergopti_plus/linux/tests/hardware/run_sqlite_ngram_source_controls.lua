--- tests/hardware/run_sqlite_ngram_source_controls.lua
--- ==============================================================================
--- MODULE: Native SQLite Source Scalar and Shape Controls (Linux)
--- DESCRIPTION:
--- Existing scalar admission, JSON shape and malformed fallback remain explicit.
--- Owned SQLite software data only; no physical or foreign runtime claims.
--- ==============================================================================

-- Native metadata controls keep existing scalar admission and malformed fallback.
local uv=require("luv")
require("compat.utf8").install()
local W=require("modules.keylogger.sqlite_writer")
local R=require("modules.keylogger.sqlite_reader")
local root=assert(uv.fs_mkdtemp("/tmp/ergopti-source-types-XXXXXX"))
local db=root.."/metrics.sqlite"
assert(W.open_db(db))
local checks,failures=0,0
local function check(name,raw,hs,llm,other)
 checks=checks+1
 local token="owned-"..checks
 assert(W.exec_sql("INSERT INTO ngram_chars (device_id,date,app,token,c,td,e,esrc_json) VALUES ('owned','2026-10-01','owned','"..token.."',9,30,2,'"..raw.."');"))
 assert(assert(W.query_rows("SELECT c,td,e,esrc_json FROM ngram_chars WHERE token='"..token.."';"))[1]=="9|30|2|"..raw)
 local ok,err=xpcall(function()
  local v=R.read_ngrams(db,"2026-10-01","2026-10-01",{"owned"}).c[token]
  assert(v.c==9 and v.t==30 and v.e==2 and v.hs==hs and v.llm==llm and v.o==other)
 end,debug.traceback)
 if ok then print("PASS "..name) else failures=failures+1;io.stderr:write("FAIL "..name..": "..err.."\n") end
end
check("mixed nonnumeric metadata retains safe recognized scalar admission",[[{"hotstring":"3","llm":"4","other":"2","none":100,"string":"owned","table":{},"bool":true,"nil":null,"array":[9]}]],3,4,2)
check("JSON array numeric keys are not source labels",'[1,2,3]',0,0,0)
check("JSON null source blob preserves zero fallback",[[null]],0,0,0)
check("JSON null source values preserve zero fallback",[[{"hotstring":null,"llm":null,"other":null,"owned":null}]],0,0,0)
check("JSON scalar shape preserves zero fallback",[[false]],0,0,0)
check("malformed legacy source retains existing literal counter fallback",[[{"hotstring":3,"llm":4,"other":5,owned]],3,4,5)
check("extra numeric values retain existing tonumber scalar admission",[[{"hotstring":1.5,"llm":2.5,"other":"3","case-transform":4.5,"owned-extension":"5","none":100}]],1.5,2.5,12.5)
assert(checks==7,"all seven native source-type controls must execute")
W.close_db()
local function remove_owned(path)
 local st=assert(uv.fs_lstat(path))
 if st.type=="directory" then for name in uv.fs_scandir_next,assert(uv.fs_scandir(path)) do remove_owned(path.."/"..name) end;assert(uv.fs_rmdir(path)) else assert(uv.fs_unlink(path)) end
end
remove_owned(root)
print(string.format("Native Reader source type/fallback controls: %d checks, %d failures",checks,failures))
os.exit(failures==0 and 0 or 1)
