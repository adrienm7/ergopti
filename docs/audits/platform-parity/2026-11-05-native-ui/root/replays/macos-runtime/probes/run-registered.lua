local root=assert(arg[1], 'explicit source root required')
local case=assert(arg[2], 'exact test module required')
local artifact=assert(arg[3], 'artifact root required')
assert(root:sub(1,1)=='/' and artifact:sub(1,1)=='/')
local original_tmpname=os.tmpname
local id=0
os.tmpname=function()
 id=id+1
 local path=artifact..'/probes/fixture-'..tostring(id)..'-'..tostring(os.time())
 local file=assert(io.open(path,'w'));file:close();return path
end
arg={'--only',case}
dofile(root..'/static/ergopti_plus/macos/tests/run.lua')
