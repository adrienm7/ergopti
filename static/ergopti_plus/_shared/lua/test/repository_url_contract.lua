--- _shared/lua/test/repository_url_contract.lua

--- ==============================================================================
--- MODULE: Repository URL Policy Contract
--- DESCRIPTION:
--- Replays the rule that decides which release-note links a native host opens:
--- https on github.com, this repository's path only. The same cases are the
--- JavaScript predicate's (_shared/ui/repository_links.js), so the page and the
--- host agree on what is clickable and what is opened.
--- ==============================================================================

--- The repository identity comes from the shared updater defaults, the single
--- source every link the app builds derives from; no spelling lives here.
local function read_repository(helpers)
	local Json = require("json")
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/modules/updater/defaults.json", "rb"))
	local raw = handle:read("*a")
	handle:close()
	local defaults = assert(Json.decode(raw), "updater defaults.json must decode")
	return defaults.github.owner, defaults.github.repo
end

return function(helpers)
	local RepositoryUrl = require("updater.repository_url")
	local OWNER, REPO = read_repository(helpers)
	local HOST = "https://github.com/"
	local ROOT = HOST .. OWNER .. "/" .. REPO
	local OTHER_OWNER = "other"

	helpers.it("repository_url: opens the root and anything below it", function()
		for _, url in ipairs({
			ROOT, ROOT .. "/", ROOT .. "/releases", ROOT .. "/releases/tag/v0.0.0-dev.150",
			ROOT .. "/compare/v1.2.2...v1.2.3", ROOT .. "?tab=readme", ROOT .. "#readme",
			ROOT .. "/issues?q=is%3Aopen",
		}) do
			helpers.assert_true(RepositoryUrl.is_repository_url(url, OWNER, REPO), url)
		end
	end)

	helpers.it("repository_url: refuses every other host, scheme, repository and spelling", function()
		local path = OWNER .. "/" .. REPO
		for _, url in ipairs({
			"http://github.com/" .. path, "https://example.com/" .. path,
			ROOT .. "-fork", ROOT .. "2/releases",
			HOST .. OTHER_OWNER .. "/" .. REPO, "https://github.com.evil.test/" .. path,
			"https://user@github.com/" .. path, "https://github.com:444/" .. path,
			ROOT .. "@evil.test/x", ROOT .. "/a b",
			ROOT .. "/\nx", "javascript:alert(1)", "file:///etc/passwd", "",
		}) do
			helpers.assert_eq(RepositoryUrl.is_repository_url(url, OWNER, REPO), false, url)
		end
	end)

	helpers.it("repository_url: refuses anything but strings and a malformed repository identity", function()
		for _, value in ipairs({ 1, true, {}, function() end }) do
			helpers.assert_eq(RepositoryUrl.is_repository_url(value, OWNER, REPO), false)
		end
		helpers.assert_eq(RepositoryUrl.is_repository_url(nil, OWNER, REPO), false)
		for _, identity in ipairs({ { nil, REPO }, { OWNER, nil }, { "", REPO }, { OWNER, "" },
			{ "a/b", REPO }, { OWNER, "er gopti" }, { 1, 2 } }) do
			helpers.assert_eq(RepositoryUrl.is_repository_url(ROOT, identity[1], identity[2]), false)
		end
	end)
end
