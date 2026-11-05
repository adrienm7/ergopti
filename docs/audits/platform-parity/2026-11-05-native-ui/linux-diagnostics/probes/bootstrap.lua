local root=assert(os.getenv('ERGOPTI_AUDIT_SOURCE_ROOT'),'source root required')
local b=root..'/static/ergopti_plus/'
package.path=b..'linux/?.lua;'..b..'linux/?/init.lua;'..b..'_shared/lua/?.lua;'..b..'_shared/lua/?/init.lua;'..package.path
return root,b
