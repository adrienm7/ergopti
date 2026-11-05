local root=assert(arg[1]);local artifact=assert(arg[2]);assert(root:sub(1,1)=='/' and artifact:sub(1,1)=='/')
local mac=root..'/static/ergopti_plus/macos';local shared=root..'/static/ergopti_plus/_shared/lua'
local id=0
os.tmpname=function()id=id+1;local path=artifact..'/probes/group-fixture-'..id..'-'..os.time();local f=assert(io.open(path,'w'));f:close();return path end
package.path=mac..'/?.lua;'..mac..'/?/init.lua;'..shared..'/?.lua;'..shared..'/?/init.lua;'..mac..'/tests/stubs/?.lua;'..package.path
require('test.runner_home').isolate()
local h=require('tests.helpers');h.initialize_timing();h.warm_timings();h.reset_results()
local isolation=require('tests.support.module_isolation')
local cases={
 'platform.remap.runtime_install.test_runtime_install','platform.remap.runtime_approval_watch.test_runtime_approval_watch',
 'platform.remap.runtime_vhid_update.test_runtime_vhid_update','adapters.runtime_owner_ports.test_runtime_owner_ports',
 'platform.remap.runtime_artifact_fetch.test_runtime_artifact_fetch','platform.remap.runtime_owner.test_runtime_owner_admission',
 'platform.remap.runtime_owner.test_runtime_owner_lifecycle','platform.remap.runtime_owner.test_runtime_dormant',
 'platform.remap.runtime_activation.test_runtime_activation',
}
for _,name in ipairs(cases)do
 isolation.purge(mac,shared)
 local ok,why=h.measure_module('tests.unit.'..name,function()return require('tests.unit.'..name)end)
 assert(ok,why)
end
local r=h.get_results();print('GROUP modules='..#cases..' passed='..r.passed..' failed='..r.failed)
os.exit(r.failed==0 and 0 or 1)
