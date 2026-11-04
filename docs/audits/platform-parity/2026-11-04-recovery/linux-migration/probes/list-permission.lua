local repo='/workspace/ergopti/static/ergopti_plus/'
package.path=repo..'linux/?.lua;'..repo..'_shared/lua/?.lua;'..repo..'_shared/lua/?/init.lua;'..package.path
local uv=require('luv');local Migration=require('infra.legacy_folder_migration')
local r=assert(arg[1]);local function mkdir(p)assert(uv.fs_mkdir(p,448))end
mkdir(r..'/cfg');mkdir(r..'/state');mkdir(r..'/data');mkdir(r..'/cache');mkdir(r..'/cfg/ergopti_plus')
local source=r..'/cfg/ergopti_plus';local file=assert(io.open(source..'/storage.json','wb'));assert(file:write('{"locale":"en"}'));assert(file:close())
assert(uv.fs_chmod(source,0))
local p={config_home=function()return r..'/cfg'end,state_home=function()return r..'/state'end,data_home=function()return r..'/data'end,cache=function()return r..'/cache/ergopti'end}
local report=Migration.run{config_paths=p}
assert(#report.moved==0 and #report.kept==0 and #report.backed_up==0 and report.cache_ready)
print('NATIVE_PERMISSION_REFUSAL','uid='..uv.getuid(),'moved='..#report.moved,'kept='..#report.kept,'cache='..tostring(report.cache_ready))
assert(uv.fs_chmod(source,448));assert(io.open(source..'/storage.json','rb'))
local again=Migration.run{config_paths=p};assert(#again.moved==1 and #again.kept==0)
print('PERMISSION_RESTORED','moved='..#again.moved,'legacy-storage-preserved=true')
