local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('test.runner_home').isolate()
local S=require('modules.shortcuts.manager');S.init({enabled=true,persist=false})
require('infra.i18n').init('en')
local menu=require('ui.menu.menu_shortcuts').build({shortcuts=S,is_paused=function() return false end})
assert(type(menu)=='table','genuine menu must be built')
local labels={}
local function walk(rows)
 for _,row in ipairs(rows) do
  local label=row.title or row.label
  if type(label)=='string' then labels[label]=true end
  for _,key in ipairs({'menu','submenu','children','items'}) do if type(row[key])=='table' then walk(row[key]) end end
 end
end
walk(menu.menu or menu.submenu or {menu})
local count=0
for label in pairs(labels) do if label:find(' … ',1,true) then count=count+1 end end
assert(labels['( … )'],'healthy built-in pair row must reach genuine menu')
assert(labels['„ … “'],'later collision pair must remain')
assert(not labels['“ … ”'],'earlier pair disappears from menu')
print('ACTUAL_MENU parens=true german_curly=true standard_curly=false pair_rows='..count)
print('CATALOGUE_PAIRS '..#S.get_wrap_pair_list())
local left,right=S.resolve_wrap_pair('“');assert(left=='“' and right=='”')
print('EXPLICIT_ACTION standard_curly=true')
print('PASS genuine menu builder and genuine catalogue; no native menu/display')
