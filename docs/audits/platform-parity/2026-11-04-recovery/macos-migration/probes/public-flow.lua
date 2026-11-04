local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
local lfs=require('lfs')
local home=assert(os.getenv('HOME'))
assert(home:find('/workspace/scratch/parity-recovery/macos-migration/probes/tmp-',1,true)==1)
local mode=assert(arg[1])
_G.hs={fs={attributes=lfs.attributes,symlinkAttributes=lfs.symlinkattributes,mkdir=lfs.mkdir,rmdir=lfs.rmdir,dir=lfs.dir}}
local logged={}
local function log(level) return function(_,fmt,...) logged[#logged+1]=level..' '..fmt:format(...) end end
local Logger=setmetatable({info=log('INFO'),warn=log('WARN'),error=log('ERROR')},{__index=function()return function()end end})
package.loaded['infra.logger']=Logger
local Migration=require('adapters.legacy_folder_migration')
local dirs=require('app_dirs')
local ports=Migration.native_ports()
local function write(path,text)
 assert(ports.make_dir(assert(require('native_path').dirname(path))))
 assert(ports.write(path,text))
end
local function read(path)return ports.read(path)end
local old=home..'/'..dirs.migration.macos.legacy_config_relative
local new=home..'/'..dirs.config.macos_relative
local bootstrap=home..'/'..dirs.config.macos_paths_file
local old_boot=home..'/'..dirs.migration.macos.legacy_support_relative..'/paths.toml'
local old_config_file=old..'/hammerspoon/config.toml'
write(old_config_file,'[script]\nlocale = "de"\n')
local chosen=mode=='nested-override' and old..'/custom' or (mode=='custom-override' and home..'/custom-config' or old)
if mode=='nested-override' then write(chosen..'/hammerspoon/config.toml','[script]\nlocale="nl"\n')end
if mode=='custom-override' then write(chosen..'/hammerspoon/config.toml','CUSTOM-USER-CONFIG')end
write(old_boot,'# keep this unrelated comment\nConfigDirPath = '..(mode=='literal-override' and "'"..chosen.."/'" or '"'..chosen..'/"')..'\nLogsDirPath = ""\n')
local original=read(old_boot)
local function resolve()
 package.loaded['infra.config_paths']=nil
 package.loaded['adapters.file_system']={read_with_status=function(path)
  local data=read(path)
  if data~=nil then return data,'ok' end
  return nil,'absent'
 end}
 return require('infra.config_paths').get_config_dir()
end
local supplied=ports
if mode=='rename-refusal' then
 local rename=ports.rename
 ports.rename=function(from,to)if from==old then return nil,'synthetic native rename refusal' end;return rename(from,to)end
elseif mode=='rewrite-refusal' then
 local writer=ports.write
 ports.write=function(path,text)if path==bootstrap then return false end;return writer(path,text)end
elseif mode=='partial-write' then
 local writer=ports.write
 ports.write=function(path,text)if path==bootstrap then assert(writer(path,'ConfigDirPath = "'));return false end;return writer(path,text)end
elseif mode=='destination-race' then
 local rename=ports.rename
 ports.rename=function(from,to)
  if from==old_boot then assert(not ports.exists(to));write(to,'NEWER-CONCURRENT-BOOTSTRAP') end
  return rename(from,to)
 end
elseif mode=='symlink-source' then
 local legacy=home..'/'..dirs.migration.macos.legacy_logs_relative
 local outside=home..'/unrelated-shared-logs'
 write(outside..'/foreign.log','FOREIGN-SENTINEL')
 assert(ports.make_dir(require('native_path').dirname(legacy)))
 assert(lfs.link(outside,legacy,true))
elseif mode=='native-list-denied' then
 assert(os.execute('chmod 000 '..require('text_utils').shell_quote(home..'/'..dirs.migration.macos.legacy_support_relative)))
elseif mode=='destination-clash' or mode=='occupied-backup' then
 write(new..'/hammerspoon/config.toml','NEWER-CONFIG')
 if mode=='occupied-backup' then write(home..'/'..dirs.macos.support_relative..'/'..dirs.migration.backup_folder..'/'..dirs.migration.macos.legacy_config_relative..'/hammerspoon/config.toml','PRIOR-BACKUP')end
end
local ok,report=pcall(Migration.run,Logger,{home=home,ports=supplied})
if mode=='native-list-denied' then
 assert(os.execute('chmod 700 '..require('text_utils').shell_quote(home..'/'..dirs.migration.macos.legacy_support_relative)))
 assert(not ok and tostring(report):find('Permission denied',1,true))
 print('REPRO real unprivileged POSIX directory denial throws from public native list; original files retained; no report returned: '..tostring(report))
 return
end
assert(ok,report)
if mode=='rename-refusal' then
 assert(#report.kept==1 and ports.exists(old_config_file) and not ports.exists(new..'/hammerspoon/config.toml'))
 assert(report.paths_file=='rewritten' and resolve()==new..'/')
 print('REPRO rename refused, old config remains; paths.toml rewritten and actual next-start resolver selects absent new config')
elseif mode=='rewrite-refusal' or mode=='partial-write' then
 assert(report.paths_file=='backup_refused' and not ports.exists(old_config_file) and ports.exists(new..'/hammerspoon/config.toml'))
 assert(read(bootstrap..dirs.migration.backup_suffix)==original)
 local first=read(bootstrap)
 local retry=Migration.run(Logger,{home=home})
 assert(retry.paths_file==(mode=='partial-write' and 'unchanged' or 'backup_refused'))
 assert(read(bootstrap)==first)
 if mode=='rewrite-refusal' then
  assert(resolve()==old..'/' and not ports.exists(old))
  print('REPRO rewrite refused after full backup/config move; retry blocked by backup; actual next-start resolver keeps nonexistent old config')
 else
  assert(require('infra.toml.codec').decode(first)==nil)
  resolve()
  assert(require('infra.config_paths').init(home..'/scratch-driver/')==false)
  print('REPRO partial rewrite truncates bootstrap; restart leaves malformed bytes while reporting unchanged; complete backup never adopted')
 end
elseif mode=='nested-override' or mode=='literal-override' then
 assert(report.paths_file=='unchanged' and resolve()==chosen..'/' and not ports.exists(chosen))
 assert(ports.exists(new..(mode=='nested-override' and '/custom' or '')..'/hammerspoon/config.toml'))
 print('REPRO valid '..mode..' remains unchanged after containing root moves; actual resolver selects nonexistent old path')
elseif mode=='destination-race' then
 assert(report.paths_file=='rewritten' and read(bootstrap)~='NEWER-CONCURRENT-BOOTSTRAP')
 print('REPRO real POSIX os.rename replaces destination created after exists check; report records moved, no clash/newer-owner warning')
elseif mode=='symlink-source' then
 assert(not ports.exists(home..'/unrelated-shared-logs/foreign.log'))
 assert(read(home..'/'..dirs.macos.relative..'/foreign.log')=='FOREIGN-SENTINEL')
 assert(lfs.symlinkattributes(home..'/'..dirs.migration.macos.legacy_logs_relative,'mode')=='link')
 print('OBSERVATION legacy logs symlink followed; target drained into new logs while symlink remains; explicit follow/refuse policy unknown')
elseif mode=='custom-override' then
 assert(report.paths_file=='unchanged' and resolve()==chosen..'/')
 assert(read(chosen..'/hammerspoon/config.toml')=='CUSTOM-USER-CONFIG')
 print('CONTROL unrelated custom override and user bytes preserved; legacy default still migrates')
elseif mode=='destination-clash' or mode=='occupied-backup' then
 assert(read(new..'/hammerspoon/config.toml')=='NEWER-CONFIG')
 local backup=home..'/'..dirs.macos.support_relative..'/'..dirs.migration.backup_folder..'/'..dirs.migration.macos.legacy_config_relative..'/hammerspoon/config.toml'
 if mode=='destination-clash' then assert(read(backup)=='[script]\nlocale = "de"\n' and #report.backed_up==1)
 else assert(read(backup)=='PRIOR-BACKUP' and ports.exists(old_config_file) and #report.kept==1)end
 print('CONTROL destination and occupied backup bytes preserved; expected clash/kept diagnostic recorded')
else
 assert(report.paths_file=='rewritten' and resolve()==new..'/')
 assert(read(bootstrap..dirs.migration.backup_suffix)==original)
 assert(read(new..'/hammerspoon/config.toml')=='[script]\nlocale = "de"\n')
 local again=Migration.run(Logger,{home=home})
 assert(again.paths_file=='unchanged' and #again.moved==0 and #again.kept==0)
 print('CONTROL normal public migration/real resolver preserves config bytes+unrelated bootstrap comment; second run no-op')
end
for _,line in ipairs(logged)do print(line)end
