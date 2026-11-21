--- tests/unit/ai/engine/ollama/test_install_errors.lua

--- ==============================================================================
--- MODULE: Linux Managed Ollama Install Error Tests
--- DESCRIPTION:
--- Replays the shared install-error corpus through the shared classifier the
--- Linux driver reads, the free-space rule and the native free-space reader,
--- and proves a failed transfer keeps its native detail up to the message the
--- user reads (OLL-04, OLL-05). No network, no install, no real filesystem.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local InstallErrors = require("ai.engine.ollama.install_errors")
local Messages = require("ai.engine.ollama.install_error_messages")
local Files = require("ai.engine.ollama.install_files")
local retained_fixture = require("tests.support.ollama_retained_fixture")

local function corpus()
	local path = assert(require("core.fs.engine.paths").shared("tests/corpus/llm/ollama_install_error_vectors.json"))
	local handle = assert(io.open(path, "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded
end

helpers.describe("Managed Ollama install errors (Linux)", function()
	helpers.it("ollama-install-error-vectors: classes every shared vector as Windows and macOS do", function()
		local vectors = corpus()
		local classifier = Messages.classifier()
		helpers.assert_true(#vectors.cases > 0, "the corpus names its cases")
		local seen = {}
		for _, case in ipairs(vectors.cases) do
			local class = classifier.classify(case.evidence)
			helpers.assert_eq(class, case.class, case.id)
			helpers.assert_eq(classifier.message_key(class), "ollama.install_error." .. class, case.id)
			seen[class] = true
		end
		for _, class in ipairs({ "network", "disk_full", "checksum", "permission", "cancelled", "unknown" }) do
			helpers.assert_true(seen[class], "the corpus covers " .. class)
		end
	end)

	helpers.it("ollama-install-error-vectors: the free-space rule of every shared vector", function()
		for _, case in ipairs(corpus().free_space) do
			helpers.assert_eq(InstallErrors.fits(case.asset_bytes, case.unpacked_bytes, case.margin_bytes, case.free_bytes),
				case.fits, case.id)
		end
		helpers.assert_true(not pcall(InstallErrors.fits, nil, 0, 0, 1), "a missing asset size is refused, not guessed")
		helpers.assert_true(not pcall(InstallErrors.fits, 1, nil, 0, 1), "a missing unpacked size is refused, not guessed")
	end)

	helpers.it("ollama-install-error-vectors: a malformed data file is refused", function()
		for _, data in ipairs({ {}, { schema_version = 1, messages = {}, classes = { { "x", "network" } } },
			{ schema_version = 1, messages = { unknown = "ollama.install_error.unknown" }, classes = { { "X", "unknown" } } },
			{ schema_version = 1, messages = { unknown = "ollama.install_error.unknown" }, classes = { { "x", "network" } } } }) do
			helpers.assert_true(not pcall(InstallErrors.new, data))
		end
		helpers.assert_true(not pcall(Messages.classifier().message_key, "no_such_class"))
	end)

	helpers.it("ollama-install-errors: a failed repair shows its install class, another the generic message", function()
		helpers.assert_eq(Messages.for_result({ ok = false, error = "runtime_install_failed",
			install_failure = "archive_download_failed curl: (6) Could not resolve host: github.com" }),
			"ollama.install_error.network")
		helpers.assert_eq(Messages.for_result({ ok = false, error = "runtime_install_failed",
			install_failure = "install_disk_full free=1 required=2" }), "ollama.install_error.disk_full")
		helpers.assert_eq(Messages.for_result({ ok = false, error = "runtime_service_unavailable" }),
			"ollama.runtime_repair_failed")
	end)

	helpers.it("ollama-install-errors: the repair failure notice sends the classified message", function()
		local path = assert(package.searchpath("ai.engine.prediction.engine", package.path))
		local handle = assert(io.open(path, "rb"))
		local source = handle:read("*a")
		handle:close()
		local notice = source:match('request:on_result%(function%(result%)(.-)\n\t\t\t\tend%)')
		helpers.assert_true(notice ~= nil, "the repair result observer is found")
		helpers.assert_true(notice:find('require("ai.engine.ollama.install_error_messages").for_result(result)', 1, true) ~= nil,
			"the observer classifies the failed repair")
		helpers.assert_true(notice:find('notifier").send(I18n.get(message_key)', 1, true) ~= nil,
			"the notice shows the classified message")
		helpers.assert_true(notice:find('I18n.get("ollama.runtime_repair_failed")', 1, true) == nil,
			"no install failure shows the generic repair message")
	end)

	helpers.it("ollama-install-errors: a failed retained download keeps curl's words", function()
		local f = retained_fixture()
		local op = f.start()
		f.through(4)
		local download = f.calls[5]
		helpers.assert_eq(download.program, "HTTP")
		download.deliver({ ok = false, status = 0, error = "curl exited with code 6",
			failure_receipt = { curl_exit = 6, stage = "connect" } })
		download.retire()
		helpers.assert_true(op:is_settled())
		helpers.assert_eq(op.result.error, "archive_download_failed")
		helpers.assert_eq(op.result.detail, "curl exited with code 6 curl_exit=6")
		helpers.assert_eq(Messages.classifier().classify(op.result.error .. " " .. op.result.detail), "network")
	end)

	helpers.it("ollama-install-errors: a full disk during the download is a full disk, not the network", function()
		local f = retained_fixture()
		local op = f.start()
		f.through(4)
		f.calls[5].deliver({ ok = false, status = 0, error = "curl: (23) Failure writing output to destination" })
		f.calls[5].retire()
		helpers.assert_eq(Messages.classifier().classify(op.result.error .. " " .. op.result.detail), "disk_full")
	end)

	helpers.it("ollama-install-free-space: the free bytes of the nearest existing ancestor", function()
		local stats = { ["/home/user/.local"] = { type = "directory" } }
		local asked
		local fs = {
			fs_lstat = function(path)
				if stats[path] then return stats[path] end
				return nil, "ENOENT: no such file", "ENOENT"
			end,
			fs_statfs = function(path) asked = path; return { bavail = 25, bsize = 4096 } end,
		}
		helpers.assert_eq(Files.free_bytes(fs, "/home/user/.local/share/ergopti"), 25 * 4096)
		helpers.assert_eq(asked, "/home/user/.local")
		stats["/home/user/.local"] = { type = "file" }
		local free, reason = Files.free_bytes(fs, "/home/user/.local/share/ergopti")
		helpers.assert_eq(free, nil)
		helpers.assert_eq(reason, "install_parent_not_directory")
		stats["/home/user/.local"] = { type = "directory" }
		fs.fs_statfs = function() return nil, "EIO" end
		free, reason = Files.free_bytes(fs, "/home/user/.local/share/ergopti")
		helpers.assert_eq(free, nil)
		helpers.assert_eq(reason, "native_statfs_refused")
		free, reason = Files.free_bytes({ fs_lstat = fs.fs_lstat }, "/home/user")
		helpers.assert_eq(reason, "native_filesystem_unavailable")
	end)
end)
