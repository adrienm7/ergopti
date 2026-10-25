--- _shared/lua/test/repository_url_contract.lua

--- ==============================================================================
--- MODULE: Repository URL Policy Contract
--- DESCRIPTION:
--- Replays the rule that decides which release-note links a native host opens:
--- https on github.com, this repository's path only. The same cases are the
--- JavaScript predicate's (_shared/ui/repository_links.js), so the page and the
--- host agree on what is clickable and what is opened.
--- ==============================================================================

return function(helpers)
	local RepositoryUrl = require("updater.repository_url")
	local ROOT = "https://github.com/adrienm7/ergopti"

	helpers.it("repository_url: opens the root and anything below it", function()
		for _, url in ipairs({
			ROOT, ROOT .. "/", ROOT .. "/releases", ROOT .. "/releases/tag/v0.0.0-dev.150",
			ROOT .. "/compare/v1.2.2...v1.2.3", ROOT .. "?tab=readme", ROOT .. "#readme",
			ROOT .. "/issues?q=is%3Aopen",
		}) do
			helpers.assert_true(RepositoryUrl.is_repository_url(url, "adrienm7", "ergopti"), url)
		end
	end)

	helpers.it("repository_url: refuses every other host, scheme, repository and spelling", function()
		for _, url in ipairs({
			"http://github.com/adrienm7/ergopti", "https://example.com/adrienm7/ergopti",
			"https://github.com/adrienm7/ergopti-fork", "https://github.com/adrienm7/ergopti2/releases",
			"https://github.com/other/ergopti", "https://github.com.evil.test/adrienm7/ergopti",
			"https://user@github.com/adrienm7/ergopti", "https://github.com:444/adrienm7/ergopti",
			"https://github.com/adrienm7/ergopti@evil.test/x", "https://github.com/adrienm7/ergopti/a b",
			"https://github.com/adrienm7/ergopti/\nx", "javascript:alert(1)", "file:///etc/passwd", "",
		}) do
			helpers.assert_eq(RepositoryUrl.is_repository_url(url, "adrienm7", "ergopti"), false, url)
		end
	end)

	helpers.it("repository_url: refuses anything but strings and a malformed repository identity", function()
		for _, value in ipairs({ 1, true, {}, function() end }) do
			helpers.assert_eq(RepositoryUrl.is_repository_url(value, "adrienm7", "ergopti"), false)
		end
		helpers.assert_eq(RepositoryUrl.is_repository_url(nil, "adrienm7", "ergopti"), false)
		for _, identity in ipairs({ { nil, "ergopti" }, { "adrienm7", nil }, { "", "ergopti" }, { "adrienm7", "" },
			{ "a/b", "ergopti" }, { "adrienm7", "er gopti" }, { 1, 2 } }) do
			helpers.assert_eq(RepositoryUrl.is_repository_url(ROOT, identity[1], identity[2]), false)
		end
	end)
end
