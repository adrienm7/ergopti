--- tests/hardware/run_sqlite_unicode_metrics.lua
--- ==============================================================================
--- MODULE: Native Unicode Metrics Ingestion (Linux)
--- DESCRIPTION:
--- Public software metrics and actual SQLite conserve Unicode codepoint payloads.
--- The independent Python oracle checks native lengths and canonical class counts.
--- ==============================================================================

-- Genuine public software metrics ingestion; native SQLite, no clock/provider doubles.
local uv=require("luv")
require("compat.utf8").install()
local Json=require("json")
local root=assert(os.getenv("OWN_METRICS_UNICODE_ROOT"))
assert(uv.fs_mkdir(root,448))
for _,name in ipairs({"CONFIG","DATA","CACHE","STATE"}) do
 assert(uv.os_setenv("XDG_"..name.."_HOME",root.."/"..name:lower()))
end
assert(uv.fs_mkdir(root.."/config",448));assert(uv.fs_mkdir(root.."/config/ergopti",448))
local cfg=assert(io.open(root.."/config/ergopti/config.toml","w"))
assert(cfg:write("[metrics]\nenabled = true\n") and cfg:close())
local K=require("modules.keylogger.keylogger")
local W=require("modules.keylogger.sqlite_writer")
local R=require("modules.keylogger.sqlite_reader")
local Clock=require("infra.monotonic")
assert(Clock.backend()=="luv.hrtime")
K.init({sqlite_path=root.."/metrics.sqlite",log_dir=root.."/logs"})
assert(K.is_enabled() and W.is_available())
local cases={ascii="A1! \n",accent="éĀ",han="中",emoji="🙂",spaces="\194\160\226\128\175\n",combining="é"}
for name,text in pairs(cases) do
 for _,cp in utf8.codes(text) do
  K.on_keydown(utf8.char(cp),math.floor(Clock.now_ms()),"manual-"..name)
 end
end
K.record_synthetic_output("synthetic-ascii","abc","llm",math.floor(Clock.now_ms()))
K.record_synthetic_output("synthetic-unicode","Aé中🙂é\n","llm",math.floor(Clock.now_ms()))
K.flush()
local manifest,complete=R.read_manifest(root.."/metrics.sqlite")
assert(complete==true)
local payload=K.get_dashboard_payload({include_prefetch=false})
assert(W.exec_sql("VACUUM INTO '"..root.."/accepted.sqlite';"))
W.close_db()
print(Json.encode({root=root,manifest=manifest,public_manifest=payload.metrics_manifest,
 runtime=_VERSION,libuv=uv.version_string()}))
