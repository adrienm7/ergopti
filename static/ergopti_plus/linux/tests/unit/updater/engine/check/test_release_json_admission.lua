--- tests/unit/updater/engine/check/test_release_json_admission.lua

--- ==============================================================================
--- MODULE: Release Page JSON Admission Tests (Linux)
--- DESCRIPTION:
--- Exercises the public updater with independently fixed release bytes through
--- a simulated completed HTTP receipt; native TLS checks live in tests/hardware.
--- Existing release metadata and channel selection policies remain unchanged.
--- ==============================================================================

local helpers = require("tests.helpers")
local vectors = {
	{ label = "unknown escape", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":\"\\q\"}]", refuses = true, tag = "v1.2.0" },
	{ label = "raw newline", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":\"a\010b\"}]", refuses = true, tag = "v1.2.0" },
	{ label = "raw tab", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":\"a\009b\"}]", refuses = true, tag = "v1.2.0" },
	{ label = "raw NUL", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":\"a\000b\"}]", refuses = true, tag = "v1.2.0" },
	{ label = "positive leading zero", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":01}]", refuses = true, tag = "v1.2.0" },
	{ label = "negative leading zero", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":-01}]", refuses = true, tag = "v1.2.0" },
	{ label = "trailing decimal point", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":1.}]", refuses = true, tag = "v1.2.0" },
	{ label = "leading zero exponent", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":01e1}]", refuses = true, tag = "v1.2.0" },
	{ label = "lone high surrogate", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":\"\\ud800\"}]", refuses = true, tag = "v1.2.0" },
	{ label = "lone low surrogate", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":\"\\udc00\"}]", refuses = true, tag = "v1.2.0" },
	{ label = "nested lone high surrogate", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":{\"text\":\"\\udbff\"}}]", refuses = true, tag = "v1.2.0" },
	{ label = "nested lone low surrogate", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":[\"\\udfff\"]}]", refuses = true, tag = "v1.2.0" },
	{ label = "positive nonfinite number", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":1e999}]", refuses = true, tag = "v1.2.0" },
	{ label = "negative nonfinite number", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":-1e999}]", refuses = true, tag = "v1.2.0" },
	{ label = "nested positive nonfinite", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":{\"count\":1e999}}]", refuses = true, tag = "v1.2.0" },
	{ label = "nested negative nonfinite", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":[-1e999]}]", refuses = true, tag = "v1.2.0" },
	{ label = "duplicate ignored field", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":1,\"audit\":2}]", refuses = true, tag = "v1.2.0" },
	{ label = "duplicate nested field", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":{\"x\":1,\"x\":2}}]", refuses = true, tag = "v1.2.0" },
	{ label = "duplicate selected tag", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"tag_name\":\"v1.3.0\"}]", refuses = true, tag = "v1.2.0" },
	{ label = "duplicate assets", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"assets\":[{\"name\": \"ergopti-plus-linux.tar.gz\", \"browser_download_url\": \"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"}, {\"name\": \"ergopti-plus-linux.tar.gz.sha256\", \"browser_download_url\": \"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}]}]", refuses = true, tag = "v1.2.0" },
	{ label = "duplicate asset name", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"obsolete\",\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}]}]", refuses = true, tag = "v1.2.0" },
	{ label = "duplicate after null", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":{\"x\":null,\"x\":2}}]", refuses = true, tag = "v1.2.0" },
	{ label = "ordinary release", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}]}]", refuses = false, tag = "v1.2.0" },
	{ label = "surrogate pair", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":\"\\ud83d\\ude00\"}]", refuses = false, tag = "v1.2.0" },
	{ label = "literal unicode", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":\"é漢字😀\"}]", refuses = false, tag = "v1.2.0" },
	{ label = "null ignored metadata", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":null}]", refuses = false, tag = "v1.2.0" },
	{ label = "nested null metadata", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":{\"x\":null}}]", refuses = false, tag = "v1.2.0" },
	{ label = "zero", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":0}]", refuses = false, tag = "v1.2.0" },
	{ label = "negative zero", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":-0}]", refuses = false, tag = "v1.2.0" },
	{ label = "fraction", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":0.125}]", refuses = false, tag = "v1.2.0" },
	{ label = "finite exponent", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":1e2}]", refuses = false, tag = "v1.2.0" },
	{ label = "escaped JSON delimiters", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}],\"audit\":\"[] {} \\\\ \\\"\"}]", refuses = false, tag = "v1.2.0" },
	{ label = "structural whitespace", body = " \009[\010{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}]}\013]\010", refuses = false, tag = "v1.2.0" },
	{ label = "higher release ordering", body = "[{\"tag_name\":\"v1.2.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.2.0/ergopti-plus-linux.tar.gz.sha256\"}]},{\"tag_name\":\"v1.3.0\",\"body\":\"ordinary notes\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-01T00:00:00Z\",\"assets\":[{\"name\":\"ergopti-plus-linux.tar.gz\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.3.0/ergopti-plus-linux.tar.gz\"},{\"name\":\"ergopti-plus-linux.tar.gz.sha256\",\"browser_download_url\":\"https://github.com/adrienm7/ergopti/releases/download/v1.3.0/ergopti-plus-linux.tar.gz.sha256\"}]}]", refuses = false, tag = "v1.3.0" },
}

helpers.describe("public updater release JSON admission", function()
	for _, vector in ipairs(vectors) do
		helpers.it("release JSON admission: " .. vector.label, function()
			local previous = package.loaded["updater.engine.manager"]
			local M = helpers.load_module("updater.engine.manager")
			local ok, problem = pcall(function()
				M.current_version = function() return "1.0.0" end
				M.release_api_url = function() return "https://example.invalid/releases?per_page=100" end
				local requests, calls, answer = 0, 0
				M._http_client = { get = function(url, _, _, callback)
					requests = requests + 1
					helpers.assert_eq(url, "https://example.invalid/releases?per_page=20&page=1")
					callback({ ok = true, status = 200, body = vector.body, error_body = "", headers = {} })
					return true
				end }
				M._http_client = require("tests.support.updater.release_http_fixture").attach(M._http_client)
				helpers.assert_true(M.check_for_updates("main", function(available, release, err, result)
					calls = calls + 1
					answer = { available = available, release = release, error = err, result = result }
				end))
				helpers.assert_eq(requests, 1)
				helpers.assert_eq(calls, 1)
				helpers.assert_true(answer ~= nil)
				if vector.refuses then
					helpers.assert_eq(answer.available, false)
					helpers.assert_eq(answer.release, nil)
					helpers.assert_true(answer.error ~= nil)
					helpers.assert_eq(answer.result.state, "error")
					helpers.assert_eq(answer.result.reason_key, "updater.parse_failed")
					helpers.assert_eq(M.get_cached_release(), nil)
				else
					helpers.assert_true(answer.available)
					helpers.assert_eq(answer.error, nil)
					helpers.assert_eq(answer.result.state, "available")
					helpers.assert_eq(answer.release.tag, vector.tag)
					helpers.assert_eq(answer.release.download_url, "https://github.com/adrienm7/ergopti/releases/download/" .. vector.tag .. "/ergopti-plus-linux.tar.gz")
					helpers.assert_eq(answer.release.checksum_url, "https://github.com/adrienm7/ergopti/releases/download/" .. vector.tag .. "/ergopti-plus-linux.tar.gz.sha256")
					helpers.assert_eq(answer.release.notes, "ordinary notes")
					helpers.assert_eq(answer.release.published_at, "2026-10-01T00:00:00Z")
					helpers.assert_eq(answer.release.prerelease, false)
					helpers.assert_eq(M.get_cached_release(), answer.release)
				end
			end)
			package.loaded["updater.engine.manager"] = previous
			if not ok then error(problem, 0) end
		end)
	end
end)

-- UPD-1 (decided by the maintainer on 2026-11-11): an answer that is not the
-- release list (a proxy or captive-portal page served with HTTP 200, a 304 the
-- check cannot answer from a cached page) is « no connection » and the public
-- feed is read, as on macOS; a malformed JSON array stays a parse failure.
helpers.describe("updater: an answer that is not the release list (upd1-captive-portal)", function()
	local function check(answer)
		local M = helpers.load_module("updater.engine.manager")
		local feeds, result = 0, nil
		local ok, problem = pcall(function()
			M.current_version = function() return "1.0.0" end
			M.release_api_url = function() return "https://example.invalid/releases?per_page=100" end
			M._fetch_feed = function(callback) feeds = feeds + 1; callback(nil, "feed unavailable in this fixture"); return true end
			M._http_client = require("tests.support.updater.release_http_fixture").attach({ get = function(_, _, _, callback)
				callback(answer)
				return true
			end })
			helpers.assert_true(M.check_for_updates("main", function(_, _, _, checked) result = checked end))
		end)
		package.loaded["updater.engine.manager"] = nil
		if not ok then error(problem, 0) end
		return result, feeds
	end

	helpers.it("reads a captive-portal page as no connection and tries the feed (upd1-captive-portal)", function()
		local result, feeds = check({ ok = true, status = 200, error_body = "", headers = {},
			body = "<!DOCTYPE html><html><body>Please sign in to the hotel Wi-Fi</body></html>" })
		helpers.assert_eq(result.state, "error")
		helpers.assert_eq(result.reason_key, "updater.no_connection")
		helpers.assert_eq(feeds, 1, "the public feed is the fallback of an answer that is not the list")
	end)

	helpers.it("keeps a malformed JSON array a parse failure, with no feed (upd1-captive-portal)", function()
		local result, feeds = check({ ok = true, status = 200, error_body = "", headers = {}, body = "[{\"tag_name\":}]" })
		helpers.assert_eq(result.reason_key, "updater.parse_failed")
		helpers.assert_eq(feeds, 0)
	end)

	helpers.it("reads a 304 with no cached page as no connection and tries the feed (upd1-captive-portal)", function()
		local result, feeds = check({ ok = false, status = 304, error_body = "", headers = {}, body = "" })
		helpers.assert_eq(result.reason_key, "updater.no_connection")
		helpers.assert_eq(feeds, 1)
	end)
end)
