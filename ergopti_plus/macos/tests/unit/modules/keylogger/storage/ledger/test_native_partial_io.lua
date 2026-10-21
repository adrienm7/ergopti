--- tests/unit/modules/keylogger/storage/ledger/test_native_partial_io.lua

--- ==============================================================================
--- MODULE: Real Partial Ledger IO and Cache Loss
--- DESCRIPTION:
--- Process-owned RLIMIT_FSIZE induces a real libc short write. A fresh child
--- resumes the exact canonical bytes, or reconstructs its deleted SQLite cache
--- only after the durable tail is complete. No native macOS result is claimed.
--- ==============================================================================

if arg and arg[0] and arg[0]:match("test_native_partial_io%.lua$") then
	local driver = assert(arg[3]) .. "/static/ergopti_plus/macos"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. package.path
	require("tests.support.keylogger.ledger_native_process")(); return
end

local helpers = require("tests.helpers")
local quote = require("text_utils").shell_quote
local source = assert(debug.getinfo(1, "S").source):gsub("^@", "")

local function verify(cache_loss)
	local script = [[
import importlib.util,json,os,resource,signal,sqlite3,subprocess,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location("ledger_bridge",root/"tools/diagnostics/hs274_persistence_test.py")
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge);bridge.ROOT=root
os.environ["ERGOPTI_PHYSICAL_SOURCE_ROOT"]=str(root)
limits=resource.getrlimit(resource.RLIMIT_FSIZE)
case=sys.argv[4]
with tempfile.TemporaryDirectory(prefix="ergopti-ledger-partial-") as temporary:
    folder=Path(temporary);device=folder/"metrics/by_device/device";device.mkdir(parents=True)
    cache=folder/"ergopti_metrics/device";cache.mkdir(parents=True)
    ledger=device/"data.sql";database=cache/"db.sqlite"
    prefix="-- canonical existing prefix\nBEGIN TRANSACTION;\n"
    prefix+="INSERT OR IGNORE INTO events_system VALUES ('device',0,'2026-10-19 12:00:00','2026-10-19','sleep','{}');\nCOMMIT;\n"
    batch="\n-- === ingest batch 2026-10-20 12:00:00.000 (offset 0 -> 123, 100 entry(ies)) ===\nBEGIN TRANSACTION;\n"
    batch+="".join("INSERT OR IGNORE INTO events_system VALUES ('device',%d,'2026-10-20 12:00:00','2026-10-20','wake','{\"pad\":\"%s\"}');\n"%(i,"x"*80) for i in range(1,101))+"COMMIT;\n"
    ledger.write_text(prefix)
    (device/"device.json").write_text(json.dumps({"device_id":"device","host_signature":"fixture-host-identity"}))
    with sqlite3.connect(database) as db:
        for name in ("schema.sql","media_schema.sql"):
            db.executescript((root/"static/ergopti_plus/_shared/data/db"/name).read_text())
        db.execute("INSERT OR REPLACE INTO meta VALUES('local_data_sql_outbox',?)",(batch,))
    def run(phase):
        os.environ["ERGOPTI_LEDGER_IO_PHASE"]=phase
        return bridge.run_fixture(sys.argv[2],temporary,Path(sys.argv[3]).resolve())
    assert run("prepare")["remaining"]==len(batch.encode())
    assert ledger.read_text()==prefix
    original_popen=subprocess.Popen
    def child_limit():
        signal.signal(signal.SIGXFSZ,signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE,(1024,limits[1]))
    def limited_popen(*args,**kwargs):
        kwargs["preexec_fn"]=child_limit
        return original_popen(*args,**kwargs)
    subprocess.Popen=limited_popen
    try: partial=run("partial")
    finally: subprocess.Popen=original_popen
    assert partial["remaining"]==len(batch.encode()),partial
    assert ledger.stat().st_size==1024
    assert ledger.read_bytes().startswith(prefix.encode())
    if case=="cache_loss": database.unlink()
    result=run(case)
    assert result["remaining"]==0 and result["timers_retired"] is True,result
    assert ledger.read_text()==prefix+batch,"canonical prefix or batch changed/duplicated"
    if case=="cache_loss":
        assert result["events"]==101 and result["cursor"]==123 and result["timers"]==1,result
    with sqlite3.connect(":memory:") as db:
        db.executescript((root/"static/ergopti_plus/_shared/data/db/schema.sql").read_text())
        db.executescript(ledger.read_text())
        assert db.execute("SELECT COUNT(*) FROM events_system").fetchone()[0]==101
    assert resource.getrlimit(resource.RLIMIT_FSIZE)==limits,"parent limits changed"
assert not Path(temporary).exists(),"private process directory leaked"
print("PASS: actual ledger short write "+case)
]]
	local executable = os.getenv("LUA") or arg[-1]
	assert(type(executable) == "string" and executable ~= "", "actual suite Lua executable required")
	local case = cache_loss and "cache_loss" or "retry"
	local command = "python3 -c " .. quote(script) .. " " .. quote(helpers.driver_root() .. "../../..")
		.. " " .. quote(executable) .. " " .. quote(source) .. " " .. quote(case) .. " 2>&1"
	local pipe = assert(io.popen(command, "r"))
	local output = assert(pipe:read("*a"))
	local ok, kind, status = pipe:close()
	helpers.assert_eq(ok, true, output); helpers.assert_eq(kind, "exit", output); helpers.assert_eq(status, 0, output)
	helpers.assert_eq(output, "PASS: actual ledger short write " .. case .. "\n")
end

helpers.describe("real local ledger short write", function()
	helpers.it("resumes after an actual partial write in a fresh Lua process", function() verify(false) end)
	helpers.it("repairs before actual manager startup replays a deleted cache", function() verify(true) end)
end)
