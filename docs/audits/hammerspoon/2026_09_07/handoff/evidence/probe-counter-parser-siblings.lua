package.path='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;'..package.path
local helpers=require('tests.helpers')
local with_counter=require('tests.support.hotstring_counter_fixture')
local cases={
 {name='BOM',content=string.char(239,187,191)..'[[arrows]]\n"a" = { output = "A" }\n',runtime=1,count=0},
 {name='quoted-description',content='[[arrows]]\n"description" = "Arrow shortcuts"\n"a" = { output = "A" }\n',runtime=1,count=2},
}
for _,case in ipairs(cases) do
 with_counter(function(counter,state,context)
  helpers.with_fresh_modules({'infra.toml.reader','toml_codec.reader','modules.keymap.registry_groups','modules.hotstrings.hotstrings_config'},function()
   state.content=case.content
   local reader=require('infra.toml.reader'); reader.set_cache_provider(nil)
   local parsed,committed=reader.parse('/virtual/extensions/demo/hotstrings/demo.toml')
   assert(committed==true)
   local entries=#parsed.sections.arrows.entries
   package.loaded['modules.hotstrings.hotstrings_config']={get_user_override=function()return nil end}
   local groups=require('modules.keymap.registry_groups')
   local runtime={groups={},mappings={},SECTION_DELAYS={}}
   local noop=function()end
   assert(groups.init(runtime,{add=function(trigger,output)runtime.mappings[#runtime.mappings+1]={trigger=trigger,output=output}end,
    sort_mappings=noop,is_section_enabled=function()return true end,resolve_priority=function()return 1 end,
    rebuild_lookup=noop,rebuild_tail_indexes=noop,drop_classify_cache=noop}))
   assert(groups.load_toml('ext:demo:demo','/virtual/extensions/demo/hotstrings/demo.toml'))
   assert(#runtime.mappings==case.runtime)
   local result=counter.count_all(context,{})
   print(case.name..': canonical_entries='..entries..' registered='..#runtime.mappings..' counter='..result.ext)
   assert(entries==case.runtime and result.ext==case.count)
  end)
 end)
end
with_counter(function(counter,state,context)
 helpers.with_fresh_modules({'infra.toml.reader','toml_codec.reader'},function()
  -- Construct TOML's single escaped quote without depending on shell escaping
  state.manifest_content='[extension]\nname = "Demo '..string.char(92)..'"Quoted'..string.char(92)..'" Pack"\n'
  local reader=require('infra.toml.reader'); reader.set_cache_provider(nil)
  local parsed,committed=reader.parse('/virtual/extensions/demo/manifest.toml')
  assert(committed==true)
  local actual=counter.count_all(context,{}).ext_details[1].name
  print('escaped-manifest: canonical='..parsed.sections.extension.name..' counter='..actual)
  assert(parsed.sections.extension.name=='Demo "Quoted" Pack')
  assert(actual=='Demo '..string.char(92))
 end)
end)
