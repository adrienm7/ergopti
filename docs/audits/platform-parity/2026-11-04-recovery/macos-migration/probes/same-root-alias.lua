local bundle='/workspace/scratch/parity-recovery/macos-migration/probes/immutable-bundle/'
package.path=bundle..'?.lua;'..bundle..'?/init.lua'
local lfs=require('lfs')
local home=assert(os.getenv('HOME'))
assert(home:find('/workspace/scratch/parity-recovery/macos-migration/probes/tmp-alias-',1,true)==1)
local mode=assert(arg[1])
_G.hs={fs={attributes=lfs.attributes,symlinkAttributes=lfs.symlinkattributes,mkdir=lfs.mkdir,rmdir=lfs.rmdir,dir=lfs.dir}}
local Migration=require('adapters.legacy_folder_migration')
local AppDirs=require('app_dirs')
local ports=Migration.native_ports()
local function write(path,text)
 assert(ports.make_dir(assert(require('native_path').dirname(path))))
 assert(ports.write(path,text))
end
local current=home..'/'..AppDirs.macos.relative
local legacy=home..'/'..AppDirs.migration.macos.legacy_logs_relative
local current_file=current..'/active.log'
local backup=home..'/'..AppDirs.macos.support_relative..'/'..AppDirs.migration.backup_folder..'/'..AppDirs.migration.macos.legacy_logs_relative..'/active.log'
write(current_file,'CURRENT-ACTIVE-SENTINEL')
assert(ports.make_dir(assert(require('native_path').dirname(legacy))))
if mode=='alias' then
 assert(lfs.link(current,legacy,true))
 local x,y=lfs.attributes(current),lfs.attributes(legacy)
 assert(x.dev==y.dev and x.ino==y.ino)
 local a,b=lfs.attributes(current_file),lfs.attributes(legacy..'/active.log')
 assert(a.dev==b.dev and a.ino==b.ino)
 print('before: legacy/current active.log same dev+ino=true')
elseif mode=='distinct' then
 write(legacy..'/active.log','DISTINCT-OLD-SENTINEL')
else
 assert(mode=='absent')
end
local lines={}
local function log(level)return function(_,fmt,...)lines[#lines+1]=level..' '..fmt:format(...)end end
local logger={info=log('INFO'),warn=log('WARN')}
local prior=lfs.attributes(current_file)
local report=Migration.run(logger,{home=home})
if mode=='alias' then
 assert(not ports.exists(current_file))
 assert(ports.read(backup)=='CURRENT-ACTIVE-SENTINEL')
 local saved=lfs.attributes(backup)
 assert(saved.dev==prior.dev and saved.ino==prior.ino)
 assert(#report.backed_up==1 and #report.kept==0)
 assert(lfs.symlinkattributes(legacy,'mode')=='link')
 local again=Migration.run(logger,{home=home})
 assert(not ports.exists(current_file) and #again.backed_up==0 and #again.kept==0)
 assert(ports.read(backup)=='CURRENT-ACTIVE-SENTINEL')
 print('REPRO: active destination inode archived through legacy alias; current path absent; backup same dev+ino; next public run does not restore')
elseif mode=='distinct' then
 assert(ports.read(current_file)=='CURRENT-ACTIVE-SENTINEL')
 assert(ports.read(backup)=='DISTINCT-OLD-SENTINEL')
 assert(#report.backed_up==1 and #report.kept==0)
 print('CONTROL: distinct legacy/current roots preserve active destination and archive only distinct old file')
else
 assert(ports.read(current_file)=='CURRENT-ACTIVE-SENTINEL')
 assert(not ports.exists(backup) and #report.backed_up==0 and #report.kept==0)
 print('CONTROL: no legacy root leaves active destination unchanged')
end
for _,line in ipairs(lines)do print(line)end
for name in pairs(package.loaded)do
 if name=='adapters.legacy_folder_migration' or name=='legacy_folder_migration' or name=='native_path' or name=='app_dirs' then
  local info=package.searchpath(name,package.path)
  assert(info and info:find(bundle,1,true)==1)
 end
end
print('immutable-source modules only; actual public plan/core/native POSIX ports; no live repository modules or tests loaded')
