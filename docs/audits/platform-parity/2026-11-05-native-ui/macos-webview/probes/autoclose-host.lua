local root,node,artifacts=assert(arg[1],'source root'),assert(arg[2],'node CLI'),assert(arg[3],'artifact root')
local mac=root..'/static/ergopti_plus/macos';local shared=root..'/static/ergopti_plus/_shared/lua'
package.path=mac..'/?.lua;'..mac..'/?/init.lua;'..mac..'/tests/stubs/?.lua;'..shared..'/?.lua;'..shared..'/?/init.lua;'..package.path
local helpers=require('tests.helpers');helpers.warm_timings()
local Json=require('json');local uv=require('luv')
local function read(path)local f=assert(io.open(path,'rb'));local t=assert(f:read('*a'));assert(f:close());return t end
local function write(path,t)local f=assert(io.open(path,'wb'));assert(f:write(t));assert(f:close())end
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local dir=artifacts..'/logs/autoclose-fixture';assert(uv.fs_mkdir(dir,448) or uv.fs_stat(dir))
local initial='[_meta]\nsections_order = ["personal"]\n[_meta.sections]\npersonal = "Personal"\n[[personal]]\n"old" = { output = "old output", is_word = true }\n'
local old_hs=hs
for _,scenario in ipairs({'cas_autoclose','write_autoclose','healthy_autoclose','cas_no_autoclose','cas_menu'}) do
 helpers.with_stub_scope({'ui.hotstring_editor','infra.toml.reader','infra.toml.writer','toml_codec.writer','toml_codec.reader','infra.logger','infra.notifications','infra.paths','infra.i18n','ui.ui_builder','adapters.file_system','adapters.hotkey_registrar','infra.deferred_work','infra.phase_stats'},function()
  local path=dir..'/'..scenario..'.toml';write(path,initial)
  local log,notices,views,callbacks={},0,{},{};local notice_text={}
  local logger=helpers.make_logger_stub();logger.error=function(_,fmt,...)log[#log+1]=string.format(fmt,...)end
  package.loaded['infra.logger']=logger
  package.loaded['infra.i18n']={get=function(k)return k end,get_locale=function()return'en'end}
  package.loaded['infra.paths']={shared=function(rel)return root..'/static/ergopti_plus/_shared/'..rel end}
  package.loaded['infra.notifications']={notify=function(...)notices=notices+1;for _,v in ipairs({...})do notice_text[#notice_text+1]=tostring(v)end end}
  package.loaded['infra.phase_stats']={now=function()return 0 end,stop=function()end}
  package.loaded['infra.deferred_work']={after=function(_,fn)fn();return true end}
  local shortcut,reads,cas_calls,reloads=nil,0,0,0
  package.loaded['adapters.hotkey_registrar']={bind=function(_,fn)shortcut=fn;return{}end,unbind=function()return true end,setEnabled=function()return true end}
  package.loaded['adapters.file_system']={read_with_status=function(candidate)assert(candidate==path);reads=reads+1;return read(path),'ok'end,
   write_if_unchanged=function(candidate,payload,expected)
    assert(candidate==path);cas_calls=cas_calls+1
    if scenario:match('^cas')then write(path,initial..'# external writer won\n')end
    if read(path)~=expected.content then return false,'source changed under publication lock'end
    if scenario=='write_autoclose'then return false,'synthetic write refused'end
    write(path,payload);return true
   end}
  _G.hs={json={encode=Json.encode},webview={windowMasks={},usercontent={new=function()return{setCallback=function(self,fn)if fn then callbacks[#callbacks+1]=fn end;return self end}end}}}
  package.loaded['ui.ui_builder']={get_app_geometry=function()return{width=100,height=100}end,get_centered_frame=function()return{}end,force_focus=function()return true end,
   show_webview=function(options)
    local view={evaluations={},deleted=false};views[#views+1]=view
    function view:evaluateJavaScript(script,completion)assert(not self.deleted);self.evaluations[#self.evaluations+1]=script;if completion then completion(nil,nil)end;return self end
    function view:delete()self.deleted=true;return nil end
    if options.on_webview_created then options.on_webview_created(view)end
    return view
   end}
  package.loaded['ui.hotstring_editor']=nil
  local Editor=require('ui.hotstring_editor')
  Editor.init(path,{PERSONAL_GROUP_NAME='personal',reload_toml=function()reloads=reloads+1;return true end})
  Editor.set_close_on_add(scenario~='cas_no_autoclose')
  assert(Editor.set_shortcut({'cmd','alt'},'h'))
  if scenario=='cas_menu'then assert(Editor.open('menu'))else assert(shortcut);shortcut()end
  assert(Editor.is_open())
  callbacks[1]({body={action='ready'}})
  local init=assert(views[1].evaluations[#views[1].evaluations]):match('window%.initData%((.*)%)$')
  assert(init,'actual host initData missing')
  local seed=Json.decode(init)
  assert(seed.open_mode==(scenario=='cas_menu'and'menu'or'shortcut'))
  assert(seed.auto_close==(scenario~='cas_no_autoclose'))
  local seedfile=dir..'/'..scenario..'-seed.json';local msgfile=dir..'/'..scenario..'-page.json'
  write(seedfile,init)
  local command=table.concat({q(node),q(artifacts..'/probes/autoclose-page.cjs'),q(root),q(seedfile),q(msgfile)},' ')
  local called,why,code=os.execute(command);assert(called==true and code==0,tostring(why)..':'..tostring(code))
  local page=Json.decode(read(msgfile));local scripts_before=#views[1].evaluations
  callbacks[1]({body=page.messages[1]})
  assert(Editor.is_open(),'save alone must keep owner open')
  local failed=scenario~='healthy_autoclose'
  assert((notices>0)==failed)
  assert(cas_calls==1)
  local newbytes=read(path)
  assert((newbytes:find('UNSAVED_DRAFT_MVB002_20261105',1,true)~=nil)==not failed)
  assert(not table.concat(log,'\n'):find('UNSAVED_DRAFT_MVB002_20261105',1,true),'error backstop must not be mistaken for a draft backup')
  assert(not table.concat(notice_text,'\n'):find('UNSAVED_DRAFT_MVB002_20261105',1,true))
  local errors_after_save=#log
  if page.messages[2]then callbacks[1]({body=page.messages[2]})end
  local closed=views[1].deleted
  assert(closed==(#page.messages==2))
  if failed then assert(#views[1].evaluations==scripts_before,'no failure payload recovery is sent')end
  if closed then
   assert(not Editor.is_open());assert(Editor.open('shortcut'))
   callbacks[2]({body={action='ready'}})
   local reopened=views[2].evaluations[#views[2].evaluations]
   local restored=reopened:find('UNSAVED_DRAFT_MVB002_20261105',1,true)~=nil
   assert(restored==not failed)
   print(scenario..': actual_host_mode='..seed.open_mode..' auto_close='..tostring(seed.auto_close)..' messages=save,close CAS_calls='..cas_calls..' errors='..errors_after_save..' notifications='..notices..' native_delete_requested=true draft_restored_on_reopen='..tostring(restored)..' reloads='..reloads)
  else
   assert(Editor.is_open());assert(page.page_draft_present_before_native_delete)
   print(scenario..': actual_host_mode='..seed.open_mode..' auto_close='..tostring(seed.auto_close)..' messages=save CAS_calls='..cas_calls..' errors='..errors_after_save..' notifications='..notices..' native_delete_requested=false page_draft_retained=true reloads='..reloads)
  end
  Editor.close();assert(uv.fs_unlink(path));assert(uv.fs_unlink(seedfile));assert(uv.fs_unlink(msgfile))
 end)
end
_G.hs=old_hs
print('actual production JS saveEntry/persist/toLua and public macOS editor+real parser/writer; private real-file CAS boundary; native WebKit receiving not exercised')
