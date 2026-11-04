-- Actual shared Lua core over real, private POSIX files. Windows orchestration
-- is mapped from its source; this is NOT executed AutoHotkey/Win32 evidence.
local root = '/workspace/ergopti'
package.path = root .. '/static/ergopti_plus/_shared/lua/?.lua;' .. root .. '/static/ergopti_plus/_shared/lua/?/init.lua;' .. package.path
local lfs = require('lfs')
local core = require('legacy_folder_migration')
local toml = require('toml_codec.codec')
local base = assert(arg[1], 'private root required')
assert(base:match('^/workspace/scratch/parity%-recovery/windows%-migration/probes/fixtures%-'))
local function parent(p) return p:match('^(.*)/[^/]+$') end
local function mkdir(p)
 if lfs.attributes(p,'mode') == 'directory' then return true end
 local par=parent(p); if par and par~='' and not mkdir(par) then return false end
 return lfs.mkdir(p)
end
local function write(p,s) assert(mkdir(parent(p))); local f=assert(io.open(p,'wb')); assert(f:write(s)); assert(f:close()); return true end
local function read(p) local f=io.open(p,'rb'); if not f then return nil end;local s=f:read('*a');f:close();return s end
local function exists(p) return lfs.symlinkattributes(p) ~= nil end
local function ports(options)
 options=options or {}
 return {exists=exists, read=read, write=function(p,s)
  if p==options.refuse_write then write(p,s:sub(1,5));assert(os.remove(p));return false end
  return write(p,s)
 end,make_dir=mkdir,remove_empty_dir=lfs.rmdir,
 list=function(p)
  if lfs.attributes(p,'mode')~='directory' then return nil end
  local out={};for n in lfs.dir(p) do if n~='.' and n~='..' then out[#out+1]=n end end;table.sort(out);return out
 end,
 rename=function(a,b)
  if a==options.refuse_move then return false,'injected native rename refusal' end
  if exists(b) then return false,'exists' end
  return os.rename(a,b)
 end}
end
local results={}
local function scenario(name, fn)
 local p=base..'/'..name;assert(not exists(p),'new root required');assert(mkdir(p));fn(p)
 results[#results+1]=name; print('PASS '..name)
end
local function setup(p,text)
 local old=p..'/user/.config/old';local new=p..'/local/Ergopti/config';local legacy=p..'/roaming/Ergopti/paths.toml';local locator=p..'/local/Ergopti/paths.toml'
 write(old..'/config.toml','OWNER=PERSONAL\n');write(legacy,text and text(old) or 'ConfigDirPath = "'..old..'/"\n')
 return old,new,legacy,locator
end
local function run(p,old,new,legacy,locator,options)
 local port=ports(options)
 local report=core.apply({{from=legacy,to=locator,backup=p..'/local/Ergopti/bak/paths.toml'},{from=old,to=new,backup=p..'/local/Ergopti/bak/config'}},port)
 report.paths_file=core.rewrite_paths_file(locator,{{key='ConfigDirPath',old={old},new=new}},'.before-folder-migration',port)
 return report,port
end
scenario('control-complete-idempotent',function(p)
 local old,new,legacy,locator=setup(p)
 local r=run(p,old,new,legacy,locator)
 assert(r.paths_file=='rewritten' and read(locator):find(new,1,true) and read(new..'/config.toml')=='OWNER=PERSONAL\n')
 local again=run(p,old,new,legacy,locator)
 assert(again.paths_file=='unchanged' and #again.moved==0)
 print('  locator and personal data agree; second boot unchanged')
end)
scenario('refused-config-move-still-rewrites',function(p)
 local old,new,legacy,locator=setup(p)
 local r=run(p,old,new,legacy,locator,{refuse_move=old})
 assert(#r.kept==1 and r.paths_file=='rewritten')
 assert(read(old..'/config.toml') and not exists(new..'/config.toml') and read(locator):find(new,1,true))
 print('  old data retained but selected new folder has no personal config; kept warning only')
end)
scenario('refused-locator-backup-after-successful-moves',function(p)
 local old,new,legacy,locator=setup(p)
 write(locator..'.before-folder-migration','foreign backup, must not overwrite')
 local r=run(p,old,new,legacy,locator)
 assert(r.paths_file=='backup_refused' and read(new..'/config.toml') and not exists(old))
 assert(read(locator):find(old,1,true))
 -- The Windows boot creates its selected missing folder; prove retry cannot
 -- repair the existing immutable backup by merely re-running migration.
 assert(mkdir(old));local again=run(p,old,new,legacy,locator)
 assert(again.paths_file=='backup_refused' and not exists(old) and read(locator):find(old,1,true))
 print('  locator still selects removed old folder; later boot remains blocked by same backup')
end)
scenario('refused-locator-write-removes-active-file',function(p)
 local old,new,legacy,locator=setup(p,function(o)return 'ConfigDirPath = "'..o..'/"\nLogsDirPath = "D:/custom-logs/"\n'end)
 local r=run(p,old,new,legacy,locator,{refuse_write=locator})
 assert(r.paths_file=='backup_refused' and not exists(locator))
 assert(read(locator..'.before-folder-migration'):find('D:/custom-logs/',1,true))
 print('  active locator absent after destructive failed write; backup contains lost override')
end)
scenario('custom-descendant-override-dangles',function(p)
 local old,new,legacy,locator=setup(p,function(o)return 'ConfigDirPath = "'..o..'/profiles/private/"\n'end)
 write(old..'/profiles/private/config.toml','OWNER=PRIVATE\n')
 local r=run(p,old,new,legacy,locator)
 assert(r.paths_file=='unchanged' and read(locator):find(old..'/profiles/private/',1,true))
 assert(not exists(old..'/profiles/private') and read(new..'/profiles/private/config.toml')=='OWNER=PRIVATE\n')
 print('  chosen descendant was physically moved but exact-only rewrite reports unchanged')
end)
scenario('valid-toml-quoted-key-missed',function(p)
 local old,new,legacy,locator=setup(p,function(o)return '"ConfigDirPath" = "'..o..'/"\n'end)
 local r=run(p,old,new,legacy,locator)
 assert(r.paths_file=='unchanged' and read(locator):find(old,1,true) and not exists(old))
 assert(toml.decode(read(locator)).ConfigDirPath==old..'/')
 print('  semantic reader key unchanged; regex only accepts bare key')
end)
scenario('old-locator-wal-orphaned',function(p)
 local old,new,legacy,locator=setup(p)
 write(legacy..'.config-transition.wal','malformed old WAL must quarantine if inspected\n')
 write(legacy..'.ergopti-transition-held.old','retained old target artifact')
 local r=run(p,old,new,legacy,locator)
 assert(r.paths_file=='rewritten' and exists(legacy..'.config-transition.wal') and not exists(locator..'.config-transition.wal'))
 assert(exists(legacy..'.ergopti-transition-held.old'))
 print('  next recovery namespace is absent; old nonempty WAL and artifact remain outside it')
end)
scenario('control-external-override-stays-live',function(p)
 local custom=p..'/documents/custom'
 local old,new,legacy,locator=setup(p,function(o)return 'ConfigDirPath = "'..custom..'/"\n'end)
 write(custom..'/config.toml','OWNER=CUSTOM\n')
 local r=run(p,old,new,legacy,locator)
 assert(r.paths_file=='unchanged' and read(custom..'/config.toml')=='OWNER=CUSTOM\n')
 print('  chosen folder outside moved roots unaffected')
end)
print('Real-path actual shared core cases='..#results..'; native Windows/AHK NOT executed')

-- Replay the actual committed contract as an independent control. Its sources
-- pin 9 move vectors, 3 POSIX paths vectors; Windows-only slash semantics excluded.
local count=0
local helpers={describe=function(_,f)f()end,it=function(name,f)f();count=count+1;print('CONTRACT PASS '..name)end,assert_eq=function(a,b,msg) assert(a==b,(msg or '')..' values differ')end,assert_true=function(a,msg)assert(a,msg)end}
require('test.legacy_folder_migration_contract').run(helpers,root..'/static/ergopti_plus/_shared')
assert(count==5);print('Committed shared contract groups='..count..'; Windows-only path vector NOT executed')
