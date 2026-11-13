--- _shared/tests/lua/layouts/catalogue_source_contract.lua

--- Pins which registry a refresh reads: a source run (a clone, the developer
--- mode included) reads the published registry like a release unless the
--- clone's registry folder differs from HEAD, and a git failure shows the
--- clone's folder with a logged error.
return function(helpers, RegistryStore, Catalogue, Json, settings)
	local SHIPPED_DIR = "/clone/" .. settings.folder .. "/"
	local SHIPPED = '{"schema_version":1,"layouts":[]}'
	local PUBLISHED = '{"schema_version":1,"layouts":[]}'

	--- A store whose logger records the warnings and errors.
	--- @return table store
	--- @return table seen { error = {} }
	local function new_store()
		local seen = { error = {} }
		local logger = {}
		for _, level in ipairs({ "start", "success", "info", "debug", "warn" }) do logger[level] = function() end end
		logger.error = function(_, fmt, ...) seen.error[#seen.error + 1] = string.format(fmt, ...) end
		local store = RegistryStore.new({ logger = logger, log = "test.source", shipped_noun = "clone",
			prepare_parent = function() return true, nil end })
		return store, seen
	end

	--- Collaborators of one refresh.
	--- @param local_source boolean
	--- @param changes function|nil registry_changes port.
	--- @return table deps
	--- @return table state { requests, probes }
	local function deps_for(local_source, changes)
		local state = { requests = {}, probes = {} }
		local files = { [SHIPPED_DIR .. "index.json"] = SHIPPED }
		local deps = {
			settings = settings, local_dir = "/cfg/", bundled_dir = SHIPPED_DIR, local_source = local_source,
			decode_json = Json.decode, encode_json = Json.encode,
			exists = function(path) return files[path] ~= nil end,
			read = function(path) return files[path] end,
			write = function(path, text) files[path] = text; return true, nil end,
			delete = function(path) files[path] = nil; return true end,
			transport = { get = function(url, _, _, callback)
				state.requests[#state.requests + 1] = url
				callback(200, PUBLISHED, nil, { etag = '"v1"' })
			end },
		}
		if changes then
			deps.registry_changes = function(dir, callback)
				state.probes[#state.probes + 1] = dir
				changes(callback)
			end
		end
		return deps, state
	end

	helpers.describe("layout catalogue source in a clone run (layout-catalogue-source)", function()
		helpers.it("decides the source from the run kind and the clone's changes", function()
			for _, case in ipairs({
				{ false, "", nil, false, Catalogue.REGISTRY_RELEASE },
				{ true, "", nil, false, Catalogue.REGISTRY_UNMODIFIED },
				{ true, " M index.json\n", nil, true, Catalogue.REGISTRY_MODIFIED },
				{ true, "?? ergopti/new.keylayout\n", nil, true, Catalogue.REGISTRY_MODIFIED },
				{ true, nil, "git is not installed", true, Catalogue.REGISTRY_GIT_FAILED },
			}) do
				local use_clone, reason = Catalogue.registry_source(case[1], case[2], case[3])
				helpers.assert_eq(use_clone, case[4], reason)
				helpers.assert_eq(reason, case[5])
			end
		end)

		helpers.it("reads the published registry when the clone's registry matches HEAD", function()
			local store, seen = new_store()
			local deps, state = deps_for(true, function(callback) callback("", nil) end)
			local outcome
			store.refresh(deps, nil, function(result) outcome = result end)
			helpers.assert_eq(state.probes, { SHIPPED_DIR })
			helpers.assert_eq(#state.requests, 1, "an unmodified clone must read the published registry")
			helpers.assert_eq(outcome.source, Catalogue.SOURCE_NETWORK)
			helpers.assert_eq(#seen.error, 0)
		end)

		helpers.it("reads the clone's registry when it differs from HEAD", function()
			local store = new_store()
			local deps, state = deps_for(true, function(callback) callback(" M index.json\n", nil) end)
			local outcome
			store.refresh(deps, nil, function(result) outcome = result end)
			helpers.assert_eq(#state.requests, 0, "a modified clone registry must not be replaced by the published one")
			helpers.assert_eq(outcome.source, Catalogue.SOURCE_BUNDLED)
		end)

		helpers.it("shows the clone's registry and logs the error when git fails", function()
			local store, seen = new_store()
			local deps, state = deps_for(true, function(callback) callback(nil, "git is not installed") end)
			local outcome
			store.refresh(deps, nil, function(result) outcome = result end)
			helpers.assert_eq(#state.requests, 0)
			helpers.assert_eq(outcome.source, Catalogue.SOURCE_BUNDLED)
			helpers.assert_eq(#seen.error, 1, "a git failure is never a silent choice")
			helpers.assert_true(seen.error[1]:find("git is not installed", 1, true) ~= nil, seen.error[1])
		end)

		helpers.it("never asks git in a release", function()
			local store = new_store()
			local deps, state = deps_for(false, function() error("a release must not probe git") end)
			store.refresh(deps, nil, function() end)
			helpers.assert_eq(#state.probes, 0)
			helpers.assert_eq(#state.requests, 1)
		end)

		helpers.it("refuses a source run without the git port", function()
			local store = new_store()
			local deps = deps_for(true, nil)
			local ok, err = pcall(store.refresh, deps, nil, function() end)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("registry_changes", 1, true) ~= nil, tostring(err))
		end)

		helpers.it("lists tracked edits and untracked files with the shared git arguments", function()
			local root = os.tmpname()
			os.remove(root)
			-- The exit status rides in the output: LuaJIT's popen close reports none.
			local function sh(command)
				local pipe = assert(io.popen("{ " .. command .. "; } 2>&1; printf '\\n%s' \"$?\""))
				local out = pipe:read("*a")
				pipe:close()
				local body, status = out:match("^(.-)\n(%d+)$")
				return status == "0", body
			end
			local function quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end
			local dir = root .. "/" .. settings.folder
			local function changes()
				local argv = { "git" }
				for _, arg in ipairs(Catalogue.registry_changes_args(dir)) do argv[#argv + 1] = quote(arg) end
				local ok, out = sh(table.concat(argv, " "))
				assert(ok, out)
				return out
			end
			local ok, failure = pcall(function()
				assert(sh("mkdir -p " .. quote(dir)))
				assert(sh("printf '{}' > " .. quote(dir .. "/index.json")))
				assert(sh("printf 'x' > " .. quote(root .. "/outside.txt")))
				local git = "git -C " .. quote(root) .. " -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "
				local inited, init_out = sh(git .. "init -q && " .. git .. "add -A && " .. git .. "commit -q -m init")
				assert(inited, init_out)
				helpers.assert_eq(changes(), "", "a committed registry has no changes")
				assert(sh("printf 'y' > " .. quote(root .. "/outside.txt")))
				helpers.assert_eq(changes(), "", "an edit outside the registry folder does not count")
				assert(sh("printf '[]' > " .. quote(dir .. "/index.json")))
				helpers.assert_true(changes():match("%S") ~= nil, "an edited index.json counts")
				assert(sh(git .. "checkout -q -- ."))
				assert(sh("mkdir -p " .. quote(dir .. "/new") .. " && printf 'k' > " .. quote(dir .. "/new/new.keylayout")))
				helpers.assert_true(changes():match("%S") ~= nil, "an untracked layout file counts")
			end)
			sh("rm -rf " .. quote(root))
			assert(ok, failure)
		end)
	end)
end
