package.path='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;'..package.path
local helpers=require('tests.helpers')
local builder=helpers.load_with_stubs('ui.menu.builder')
local builder_counter=require('ui.menu.hotstring_counter')
local counts
local with_counter=require('tests.support.hotstring_counter_fixture')
with_counter(function(counter,state,context)
 state.content='[[arrows]]\n"a" = { output = "A" }\n[[arrows]]\n"b" = { output = "B" }\n'
 local reader=require('infra.toml.reader')
 reader.set_cache_provider(nil)
 local parsed,committed=reader.parse('/virtual/extensions/demo/hotstrings/demo.toml')
 assert(committed and #parsed.sections_order==1 and #parsed.sections.arrows.entries==2)
 counts=counter.count_all(context,{})
 local sections=counts.ext_details[1].files[1].sections
 assert(counts.ext==2 and #sections==2)
 print('canonical_sections=1 canonical_entries=2 counter_sections='..#sections..' counter_total='..counts.ext)
end)
 builder_counter.count_all=function() return counts end
 local actions=setmetatable({}, {__index=function() return function() end end})
 local menu=builder.generate({config={log_level=2},paused=false,hotfiles={},state={hotstrings={}},save_prefs=function()end,updateMenu=function()end},{hotstrings={}},actions)
 local duplicate=0
 local function visit(rows)
  for _,row in ipairs(rows or {}) do
   if row.title=='arrows (1)' then duplicate=duplicate+1; assert(row.disabled==true) end
   if type(row.menu)=='table' then visit(row.menu) end
  end
 end
 visit(menu)
 print('rendered_arrows_1_rows='..duplicate)
 assert(duplicate==2)
