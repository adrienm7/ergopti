local repo='/workspace/ergopti/static/ergopti_plus/'
package.path=repo..'linux/?.lua;'..repo..'linux/?/init.lua;'..repo..'_shared/lua/?.lua;'..repo..'_shared/lua/?/init.lua;'..package.path
local uv=require('luv')
local Migration=require('infra.legacy_folder_migration')
local Core=require('legacy_folder_migration')
local Json=require('json')
local dir=assert(uv.fs_mkdtemp('/workspace/scratch/parity-recovery/linux-migration/probes/native-XXXXXX'))
local function mkdir(path)
 local cur=''
 for part in path:gmatch('[^/]+') do cur=cur..'/'..part;if not uv.fs_stat(cur) then assert(uv.fs_mkdir(cur,448)) end end
end
local function write(path,bytes) mkdir(assert(require('native_path').dirname(path)));local f=assert(io.open(path,'wb'));assert(f:write(bytes));assert(f:close()) end
local function read(path) local f=io.open(path,'rb');if not f then return nil end;local t=f:read('*a');f:close();return t end
local function remove(path)
 local s=uv.fs_lstat(path);if not s then return end
 if s.type=='directory' then local req=assert(uv.fs_scandir(path));while true do local n=uv.fs_scandir_next(req);if not n then break end;remove(path..'/'..n) end;assert(uv.fs_rmdir(path)) else assert(uv.fs_unlink(path)) end
end
local function paths(label)
 local root=dir..'/'..label
 return {config_home=function()return root..'/cfg'end,state_home=function()return root..'/state'end,data_home=function()return root..'/data'end,cache=function()return root..'/cache/ergopti'end},root
end
local function summary(label,r) print(label,'moved='..#r.moved,'backed='..#r.backed_up,'kept='..#r.kept,'removed='..#r.removed,'cache='..tostring(r.cache_ready)) end
local cases={}
function cases.healthy()
 local p,r=paths('healthy');write(r..'/cfg/ergopti_plus/storage.json','old');write(r..'/cfg/ergopti/occupied','new');write(r..'/cfg/ergopti_plus/occupied','old-clash');mkdir(r..'/cfg/ergopti/empty');write(r..'/cfg/ergopti_plus/empty/payload','old-empty')
 local report=Migration.run{config_paths=p};summary('healthy',report)
 assert(read(r..'/cfg/ergopti/storage.json')=='old');assert(read(r..'/cfg/ergopti/occupied')=='new');assert(read(r..'/cfg/ergopti/before-folder-migration/ergopti_plus/occupied')=='old-clash');assert(read(r..'/cfg/ergopti/empty/payload')=='old-empty')
 local again=Migration.run{config_paths=p};summary('healthy-restart',again);assert(#again.moved==0 and #again.kept==0 and #again.backed_up==0)
end
function cases.race()
 local p,r=paths('race');local src=r..'/cfg/ergopti_plus/storage.json';local dst=r..'/cfg/ergopti/storage.json';write(src,'LEGACY');local ports=Migration.native_ports();local rename=ports.rename;local arrived=false
 ports.rename=function(from,to)
  if from==src and to==dst then write(dst,'CONCURRENT-NEW');arrived=true end
  return rename(from,to)
 end
 local report=Migration.run{config_paths=p,ports=ports};summary('race',report)
 assert(arrived and read(dst)=='LEGACY' and not read(src));assert(#report.moved==1 and #report.kept==0 and #report.backed_up==0)
 print('race-newer-target-replaced=true', 'native=os.rename', 'report=successful-move')
end
function cases.newline()
 local p,r=paths('newline');local src=r..'/cfg/ergopti_plus/line\nbreak';write(src,'preserve')
 local listed=Migration.native_ports().list(r..'/cfg/ergopti_plus');print('newline-list',Json.encode(listed));assert(#listed==2)
 local report=Migration.run{config_paths=p};summary('newline',report)
 assert(read(src)=='preserve' and not read(r..'/cfg/ergopti/line\nbreak'));assert(#report.moved==0 and #report.kept==0)
 print('newline-restart-same-silent-stall=true');local again=Migration.run{config_paths=p};assert(#again.moved==0 and #again.kept==0)
end
function cases.refused_rename()
 local p,r=paths('refuse');local src=r..'/cfg/ergopti_plus/storage.json';write(src,'preserve');local ports=Migration.native_ports();ports.rename=function()return nil,'controlled refusal'end
 local report=Migration.run{config_paths=p,ports=ports};summary('refusal',report);assert(read(src)=='preserve' and #report.kept==1 and report.kept[1].reason=='rename_failed')
 local again=Migration.run{config_paths=p};assert(#again.moved==1);print('rename-refusal-restart-recovers=true')
end
function cases.override()
 local p,r=paths('override');local old=r..'/cfg/ergopti_plus/custom';local new=r..'/cfg/ergopti/custom'
 write(old..'/config.toml','[script]\nlocale = "en"\n');write(r..'/cfg/ergopti_plus/storage.json',Json.encode({['paths.config_dir']=old}))
 local report=Migration.run{config_paths=p};summary('override',report);assert(read(new..'/config.toml'))
 local getenv=os.getenv
 os.getenv=function(name)if name=='XDG_CONFIG_HOME' then return r..'/cfg' elseif name=='HOME' then return r end;return getenv(name)end
 package.loaded['infra.config_paths']=nil;package.loaded['adapters.storage']=nil
 local Paths=require('infra.config_paths');local Storage=require('adapters.storage');local effective=Paths.config('config.toml')
 assert(Storage.path()==r..'/cfg/ergopti/storage.json');assert(Storage.get('paths.config_dir')==old);assert(effective==old..'/config.toml' and not read(effective));assert(read(new..'/config.toml'))
 print('override-effective='..effective,'relocated='..new..'/config.toml','active_config_absent=true')
 os.getenv=getenv;package.loaded['infra.config_paths']=nil;package.loaded['adapters.storage']=nil
end
function cases.symlink()
 local p,r=paths('symlink');local external=r..'/external';write(external..'/payload','external-data');mkdir(r..'/cfg');assert(uv.fs_symlink(external,r..'/cfg/ergopti_plus'))
 local report=Migration.run{config_paths=p};summary('symlink-observation',report)
 assert(not read(external..'/payload') and read(r..'/cfg/ergopti/payload')=='external-data');assert(uv.fs_lstat(r..'/cfg/ergopti_plus').type=='link')
 print('symlink-source-target-drained=true','policy=unresolved-not-finding')
end
function cases.alias()
 local p,r=paths('alias');local target=r..'/cfg/ergopti';write(target..'/config.toml','ACTIVE');assert(uv.fs_symlink(target,r..'/cfg/ergopti_plus'))
 local report=Migration.run{config_paths=p};summary('same-root-alias',report)
 assert(not read(target..'/config.toml'));assert(read(target..'/before-folder-migration/ergopti_plus/config.toml')=='ACTIVE');assert(#report.backed_up==1)
 print('same-root-alias-active-config-archived=true')
 local again=Migration.run{config_paths=p};summary('same-root-alias-restart',again)
 assert(not read(target..'/config.toml') and read(target..'/before-folder-migration/ergopti_plus/config.toml')=='ACTIVE')
end
function cases.backup_retry()
 local p,r=paths('backupretry');local src=r..'/cfg/ergopti_plus/item';local dst=r..'/cfg/ergopti/item';local backup=r..'/cfg/ergopti/before-folder-migration/ergopti_plus/item'
 write(src,'OLD');write(dst,'NEW');write(backup,'PRIOR')
 local report=Migration.run{config_paths=p};assert(#report.kept==1 and report.kept[1].reason=='backup_exists');assert(read(src)=='OLD' and read(dst)=='NEW' and read(backup)=='PRIOR')
 assert(uv.fs_unlink(backup));local again=Migration.run{config_paths=p};assert(#again.backed_up==1 and read(backup)=='OLD' and read(dst)=='NEW');print('backup-exists-refused-and-retry-safe=true')
end
function cases.name_controls()
 local p,r=paths('names');local names={"single'quote",'tab\tname','é-文件','--option','back\\slash'}
 for _,name in ipairs(names) do write(r..'/cfg/ergopti_plus/'..name,name) end
 local report=Migration.run{config_paths=p};assert(#report.moved==#names and #report.kept==0)
 for _,name in ipairs(names)do assert(read(r..'/cfg/ergopti/'..name)==name)end
 print('name-controls-quote-tab-unicode-dash-backslash-preserved=true')
end
function cases.parent_refusal()
 local p,r=paths('parentrefusal');write(r..'/cfg/ergopti_plus/storage.json','OLD');write(r..'/cfg/ergopti','BLOCKING-FILE')
 local report=Migration.run{config_paths=p};assert(#report.kept==1 and report.kept[1].reason=='parent_unavailable');assert(read(r..'/cfg/ergopti_plus/storage.json')=='OLD')
 assert(uv.fs_unlink(r..'/cfg/ergopti'));local again=Migration.run{config_paths=p};assert(#again.moved==1);print('parent-refused-and-restart-recovers=true')
end
function cases.cache_refusal()
 local p,r=paths('cache');write(r..'/cache/ergopti','BLOCKING-FILE')
 local report=Migration.run{config_paths=p};assert(report.cache_ready==false)
 local warnings=0;Migration.log({info=function()end,warn=function()warnings=warnings+1 end},report);assert(warnings==1)
 print('cache-refusal-logged=true')
end
local modes=arg[1] and {arg[1]} or {'healthy','race','newline','refused_rename','override','symlink','alias'}
local ok,err=xpcall(function() for _,mode in ipairs(modes) do assert(cases[mode],mode)() end end,debug.traceback)
remove(dir)
assert(ok,err)
print('PASS scratch fixture retired; no live user paths or driver boot executed')
