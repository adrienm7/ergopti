--- infra/vscode_bridge.lua

--- ==============================================================================
--- MODULE: VSCode Bridge
--- DESCRIPTION:
--- Exposes the exact pixel position of the VSCode caret via an auto-generated
--- extension and a local HTTP server.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local text_utils = require("infra.text_utils")
local i18n   = require("infra.i18n")
local LOG    = "vscode_bridge"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local PORT          = 7878
local SERVER_INTERFACE = "loopback"
local EXT_ID        = "hs-caret-bridge"
local EXT_VERSION   = "0.0.3"
-- HOME is always set on macOS, but this concatenation runs at MODULE LOAD, so a
-- nil there does not degrade the feature — it raises before a single function is
-- defined and takes down whatever required the module. Defaulting keeps the
-- failure inside the feature that needs the path.
local HOME          = os.getenv("HOME") or ""
local EXT_DIR       = HOME .. "/.vscode/extensions/" .. EXT_ID .. "-" .. EXT_VERSION
local EXTENSION_STAGE_SUFFIX = ".ergoptiplus-stage"
local EXTENSION_BACKUP_SUFFIX = ".ergoptiplus-backup"
local EXTENSION_RESTORE_SUFFIX = ".ergoptiplus-restore"
local EXTENSION_JOURNAL_NAME = ".ergoptiplus-extension-transaction"
local EXTENSION_JOURNAL_STAGE_NAME = ".ergoptiplus-extension-transaction-stage"
local EXTENSION_JOURNAL_MAGIC = "ergoptiplus-vscode-extension-transaction-v1"

local _extension_cleanup = nil

-- AX frame cache: the accessibility call can block for up to 100 ms on a
-- busy VSCode instance. Cache the result for FRAME_CACHE_TTL_S so that rapid
-- consecutive calls to estimate_position() (one per streaming token) do not
-- each stall the Hammerspoon main thread (vscode-bridge-blocking-ax-call).
local _ax_frame_cache  = nil
local _ax_frame_ts     = 0
-- Validity is tracked separately from the cached VALUE because nil is a
-- legitimate result (no focused element, or an editor frame too small to use).
-- Keying freshness on `_ax_frame_cache ~= nil` therefore never cached a negative
-- lookup, so the expensive round trip re-ran on every single call — exactly the
-- case the cache exists to absorb.
local _ax_frame_valid  = false
local FRAME_CACHE_TTL_S = 0.2

-- VSCode rendering constants for pixel math.
M.LINE_HEIGHT  = 19
M.CHAR_WIDTH   = 7.65
M.GUTTER_WIDTH = 62





-- ====================================
-- ====================================
-- ======= 2/ Extension Scripts =======
-- ====================================
-- ====================================

local PACKAGE_JSON = string.format([[{
  "name": "%s",
  "displayName": "Hammerspoon Caret Bridge",
  "description": "Sends caret pixel-position data to Hammerspoon",
  "version": "%s",
  "publisher": "local",
  "engines": { "vscode": "^1.60.0" },
  "activationEvents": ["onStartupFinished"],
  "main": "./extension.js",
  "contributes": {}
}]], EXT_ID, EXT_VERSION)

local EXTENSION_JS = [[
'use strict';
const vscode = require('vscode');
const http   = require('http');

let _timer = null;

function post(payload) {
    const body = JSON.stringify(payload);
    const req  = http.request({
        hostname: '127.0.0.1',
        port:     7878,
        path:     '/caret',
        method:   'POST',
        headers:  {
            'Content-Type':   'application/json',
            'Content-Length': Buffer.byteLength(body)
        }
    }, res => { res.resume(); });
    req.on('error', () => {});
    req.write(body);
    req.end();
}

function send() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) { post({ active: false }); return; }

    const pos = editor.selection.active;
    const vr  = editor.visibleRanges[0];

    post({
        active:           true,
        line:             pos.line,
        character:        pos.character,
        visibleStartLine: vr ? vr.start.line : 0,
        visibleEndLine:   vr ? vr.end.line   : 0,
        lineCount:        editor.document.lineCount,
        tabSize:          (typeof editor.options.tabSize === 'number')
                              ? editor.options.tabSize : 4,
    });
}

function debouncedSend() {
    clearTimeout(_timer);
    _timer = setTimeout(send, 40);
}

function activate(ctx) {
    ctx.subscriptions.push(
        vscode.window.onDidChangeTextEditorSelection(debouncedSend),
        vscode.window.onDidChangeActiveTextEditor(debouncedSend),
        vscode.window.onDidChangeTextEditorVisibleRanges(debouncedSend)
    );
    send();
}

function deactivate() {}
module.exports = { activate, deactivate };
]]





-- =========================================
-- =========================================
-- ======= 3/ Extension Installation =======
-- =========================================
-- =========================================

--- Formats one protected native-operation failure without losing its detail.
--- @param call_ok boolean Whether the protected call returned.
--- @param result any Primary native result or thrown error.
--- @param native_error any Secondary native error.
--- @param fallback string Fallback detail.
--- @return string detail Failure detail.
local function native_failure_detail(call_ok, result, native_error, fallback)
	if not call_ok then return tostring(result) end
	return tostring(native_error or result or fallback)
end

--- Reads exact bytes while distinguishing native absence from uncertainty.
--- @param path string Target file path.
--- @return boolean read_safe Whether absence or exact content was proven.
--- @return string|nil content Exact bytes, or nil only for native ENOENT.
--- @return string|nil error_message Failure detail.
local function read_file_with_status(path)
	local open_ok, handle, open_error, error_code = pcall(io.open, path, "rb")
	if open_ok and handle == nil and error_code == 2 then return true, nil, nil end
	if not open_ok or handle == nil or handle == false then
		return false, nil,
			native_failure_detail(open_ok, handle, open_error, "open refused")
	end

	local read_ok, content, read_error = pcall(handle.read, handle, "*a")
	local close_ok, close_result, close_error = pcall(handle.close, handle)
	local read_committed = read_ok and type(content) == "string"
	local close_committed = close_ok and close_result == true
	if read_committed and close_committed then return true, content, nil end

	local failures = {}
	if not read_committed then
		failures[#failures + 1] = "read: "
			.. native_failure_detail(read_ok, content, read_error, "read refused")
	end
	if not close_committed then
		failures[#failures + 1] = "close: "
			.. native_failure_detail(close_ok, close_result, close_error, "close refused")
	end
	return false, nil, table.concat(failures, "; ")
end

--- Closes one retained file handle and consumes its Lua ownership exactly once.
--- A failed native close may still leave a Lua file object permanently closed, so
--- retaining and invoking that object again would create unrecoverable cleanup debt.
--- @param entry table Transaction entry.
--- @param role string Sidecar role.
--- @param context string Diagnostic context.
--- @return boolean closed Whether no handle remains owned.
local function close_owned_handle(entry, role, context)
	local handle_key = role .. "_handle"
	local handle = entry[handle_key]
	if not handle then return true end
	entry[handle_key] = nil

	local close_ok, close_result, close_error = pcall(handle.close, handle)
	if close_ok and close_result == true then return true end
	Logger.error(LOG, "Extension %s could not close '%s': %s.",
		context,
		tostring(entry[role .. "_path"]),
		native_failure_detail(close_ok, close_result, close_error, "close refused"))
	return false
end

--- Removes one owned path, accepting native ENOENT as already settled.
--- @param path string Owned path.
--- @param context string Diagnostic context.
--- @return boolean removed Whether the path is proven absent.
local function remove_owned_path(path, context)
	local remove_ok, remove_result, remove_error, error_code = pcall(os.remove, path)
	if remove_ok and (remove_result == true or error_code == 2) then return true end
	Logger.error(LOG, "Extension %s could not remove '%s': %s.",
		context,
		path,
		native_failure_detail(remove_ok, remove_result, remove_error, "remove refused"))
	return false
end

--- Removes one private sidecar while retaining any unsettled handle or pathname.
--- @param entry table Transaction entry.
--- @param role string Sidecar role.
--- @param context string Diagnostic context.
--- @return boolean settled Whether all ownership for the sidecar settled.
local function cleanup_sidecar(entry, role, context)
	local handle_settled = close_owned_handle(entry, role, context)
	local owned_key = role .. "_owned"
	local path_settled = true
	if entry[owned_key] then
		path_settled = remove_owned_path(entry[role .. "_path"], context)
		if path_settled then entry[owned_key] = false end
	end
	return handle_settled and path_settled
end

--- Writes one private sidecar and proves write, flush, and close exactly.
--- @param entry table Transaction entry.
--- @param role string Sidecar role.
--- @param content string Exact payload bytes.
--- @return boolean staged Whether the payload is durable and closed.
--- @return string|nil error_message Failure detail.
local function stage_payload(entry, role, content)
	local path = entry[role .. "_path"]
	local open_ok, handle, open_error = pcall(io.open, path, "wb")
	if not open_ok or handle == nil or handle == false then
		return false, native_failure_detail(open_ok, handle, open_error, "open refused")
	end

	entry[role .. "_handle"] = handle
	entry[role .. "_owned"] = true

	local write_ok, write_result, write_error = pcall(handle.write, handle, content)
	local write_committed = write_ok and write_result == handle
	local flush_ok, flush_result, flush_error = false, nil, nil
	if write_committed then
		flush_ok, flush_result, flush_error = pcall(handle.flush, handle)
	end
	local flush_committed = flush_ok and flush_result == true
	local close_committed = close_owned_handle(entry, role, "staging")

	if not write_committed then
		return false, native_failure_detail(write_ok, write_result, write_error, "write refused")
	end
	if not flush_committed then
		return false, native_failure_detail(flush_ok, flush_result, flush_error, "flush refused")
	end
	if not close_committed then return false, "close refused" end
	return true
end

--- Publishes one private sidecar over its final path on exact rename success.
--- @param source string Owned source path.
--- @param destination string Final path.
--- @param context string Diagnostic context.
--- @return boolean renamed Whether publication committed.
--- @return string|nil error_message Failure detail.
local function rename_owned_path(source, destination, context)
	local rename_ok, rename_result, rename_error = pcall(os.rename, source, destination)
	if rename_ok and rename_result == true then return true end
	local detail = native_failure_detail(rename_ok, rename_result, rename_error, "rename refused")
	Logger.error(LOG, "Extension %s rename '%s' -> '%s' failed: %s.",
		context, source, destination, detail)
	return false, detail
end

--- Returns every deterministic pathname owned by the extension transaction.
--- @return table paths Transaction path set.
local function extension_transaction_paths()
	local package_path = EXT_DIR .. "/package.json"
	local extension_path = EXT_DIR .. "/extension.js"
	return {
		package_path = package_path,
		extension_path = extension_path,
		journal_path = EXT_DIR .. "/" .. EXTENSION_JOURNAL_NAME,
		journal_stage_path = EXT_DIR .. "/" .. EXTENSION_JOURNAL_STAGE_NAME,
		orphan_paths = {
			package_path .. EXTENSION_STAGE_SUFFIX,
			package_path .. EXTENSION_BACKUP_SUFFIX,
			package_path .. EXTENSION_RESTORE_SUFFIX,
			extension_path .. EXTENSION_STAGE_SUFFIX,
			extension_path .. EXTENSION_BACKUP_SUFFIX,
			extension_path .. EXTENSION_RESTORE_SUFFIX,
			EXT_DIR .. "/" .. EXTENSION_JOURNAL_STAGE_NAME,
		},
	}
end

--- Encodes the only persisted recovery facts in one canonical payload.
--- @param package_existed boolean Whether package.json initially existed.
--- @param extension_existed boolean Whether extension.js initially existed.
--- @return string payload Canonical journal bytes.
local function extension_journal_payload(package_existed, extension_existed)
	return string.format("%s\npackage_existed=%s\nextension_existed=%s\n",
		EXTENSION_JOURNAL_MAGIC,
		tostring(package_existed),
		tostring(extension_existed))
end

--- Decodes only one exact canonical journal schema.
--- @param payload string Candidate journal bytes.
--- @return table|nil facts Initial-existence facts, or nil when invalid.
local function decode_extension_journal(payload)
	for _, facts in ipairs({
		{ package_existed = false, extension_existed = false },
		{ package_existed = false, extension_existed = true },
		{ package_existed = true, extension_existed = false },
		{ package_existed = true, extension_existed = true },
	}) do
		if payload == extension_journal_payload(
			facts.package_existed,
			facts.extension_existed
		) then
			return facts
		end
	end
	return nil
end

--- Creates one deterministic entry owned by a transaction.
--- @param path string Final path.
--- @param content string New payload.
--- @param original string|nil Original bytes when observed in this process.
--- @param existed boolean Initial existence fact.
--- @return table entry Owned entry.
local function new_extension_entry(path, content, original, existed)
	return {
		path = path,
		content = content,
		original = original,
		existed = existed,
		stage_path = path .. EXTENSION_STAGE_SUFFIX,
		backup_path = path .. EXTENSION_BACKUP_SUFFIX,
		restore_path = path .. EXTENSION_RESTORE_SUFFIX,
		stage_owned = false,
		backup_owned = false,
		restore_owned = false,
		published = false,
	}
end

--- Creates one new transaction from an exact observed original pair.
--- @param paths table Deterministic transaction paths.
--- @param package_original string|nil Original package bytes.
--- @param extension_original string|nil Original extension bytes.
--- @return table transaction Owned transaction.
local function new_extension_transaction(paths, package_original, extension_original)
	local transaction = {
		phase = "pre_journal",
		journal_path = paths.journal_path,
		journal_published = false,
		journal = {
			stage_path = paths.journal_stage_path,
			stage_owned = false,
		},
		entries = {
			new_extension_entry(
				paths.package_path,
				PACKAGE_JSON,
				package_original,
				package_original ~= nil
			),
			new_extension_entry(
				paths.extension_path,
				EXTENSION_JS,
				extension_original,
				extension_original ~= nil
			),
		},
	}
	_extension_cleanup = transaction
	return transaction
end

--- Rebuilds recovery ownership using only the durable journal facts.
--- @param paths table Deterministic transaction paths.
--- @param facts table Decoded journal facts.
--- @return table transaction Recovery transaction.
local function new_recovery_transaction(paths, facts)
	local transaction = new_extension_transaction(paths, nil, nil)
	transaction.phase = "recovery"
	transaction.journal_published = true
	transaction.entries[1].existed = facts.package_existed
	transaction.entries[2].existed = facts.extension_existed
	transaction.journal.stage_owned = true
	for _, entry in ipairs(transaction.entries) do
		entry.stage_owned = true
		entry.backup_owned = true
		entry.restore_owned = true
	end
	return transaction
end

--- Removes transaction sidecars only after no live journal needs them.
--- @param transaction table Owned transaction.
--- @param context string Diagnostic context.
--- @return boolean settled Whether all sidecars are proven absent.
local function cleanup_extension_sidecars(transaction, context)
	local settled = true
	for _, entry in ipairs(transaction.entries) do
		for _, role in ipairs({ "stage", "backup", "restore" }) do
			if not cleanup_sidecar(entry, role, context) then settled = false end
		end
	end
	if not cleanup_sidecar(transaction.journal, "stage", context) then settled = false end
	return settled
end

--- Removes deterministic sidecars that cannot belong to a committed journal.
--- @param paths table Deterministic transaction paths.
--- @return boolean settled Whether all orphans are proven absent.
local function cleanup_pre_journal_orphans(paths)
	local settled = true
	for _, path in ipairs(paths.orphan_paths) do
		if not remove_owned_path(path, "orphan cleanup") then settled = false end
	end
	return settled
end

--- Restores one final path without consuming its durable backup.
--- @param entry table Recovery entry.
--- @param index number Entry index for diagnostics.
--- @return boolean restored Whether the exact initial state was restored.
local function restore_extension_entry(entry, index)
	if not entry.existed then
		local removed = remove_owned_path(entry.path, "rollback " .. tostring(index))
		if removed then entry.published = false end
		return removed
	end

	local read_safe, original, read_error = read_file_with_status(entry.backup_path)
	if not read_safe or original == nil then
		Logger.error(LOG, "Extension rollback cannot read backup '%s': %s.",
			entry.backup_path,
			tostring(read_error or "backup missing"))
		return false
	end
	local staged, stage_error = stage_payload(entry, "restore", original)
	if not staged then
		Logger.error(LOG, "Extension rollback cannot stage restore '%s': %s.",
			entry.restore_path, tostring(stage_error))
		return false
	end
	local restored = rename_owned_path(entry.restore_path, entry.path,
		"rollback " .. tostring(index))
	if restored then
		entry.restore_owned = false
		entry.published = false
	end
	return restored
end

--- Replays one durable journal idempotently, including across module reloads.
--- Backups are copied through restore sidecars and remain intact until both
--- final paths are exact and the journal has been deleted.
--- @param transaction table Recovery transaction.
--- @return boolean settled Whether recovery and cleanup fully settled.
local function recover_extension_transaction(transaction)
	local restored = true
	for index = #transaction.entries, 1, -1 do
		if not restore_extension_entry(transaction.entries[index], index) then
			restored = false
		end
	end
	if not restored then return false end

	if not remove_owned_path(transaction.journal_path, "rollback journal commit") then
		return false
	end
	transaction.journal_published = false
	transaction.phase = "cleanup_only"
	local cleaned = cleanup_extension_sidecars(transaction, "rollback cleanup")
	if cleaned and _extension_cleanup == transaction then _extension_cleanup = nil end
	return cleaned
end

--- Commits a fully published pair by deleting its recovery journal first.
--- @param transaction table Fully published transaction.
--- @return boolean durable Whether the logical commit point was reached.
--- @return boolean settled Whether post-commit sidecars also settled.
local function finalize_extension_commit(transaction)
	if not remove_owned_path(transaction.journal_path, "commit journal") then
		Logger.error(LOG, "Extension pair is published but its journal still requires retry.")
		return false, false
	end
	transaction.journal_published = false
	transaction.phase = "cleanup_only"
	local cleaned = cleanup_extension_sidecars(transaction, "post-commit cleanup")
	if cleaned then
		if _extension_cleanup == transaction then _extension_cleanup = nil end
	else
		Logger.warn(LOG, "Extension pair committed with retryable orphan cleanup debt.")
	end
	return true, cleaned
end

--- Settles retained in-process ownership before another install attempt.
--- @param transaction table Owned transaction.
--- @return boolean settled Whether a new transaction may start.
local function settle_extension_transaction(transaction)
	local settled = false
	if transaction.phase == "recovery" then
		settled = recover_extension_transaction(transaction)
	elseif transaction.phase == "commit_pending" then
		local durable, cleaned = finalize_extension_commit(transaction)
		settled = durable and cleaned
	elseif transaction.phase == "pre_journal" then
		transaction.phase = "cleanup_only"
		settled = cleanup_extension_sidecars(transaction, "pre-journal cleanup")
	elseif transaction.phase == "cleanup_only" then
		settled = cleanup_extension_sidecars(transaction, "orphan cleanup retry")
	else
		Logger.error(LOG, "Extension transaction has unknown phase '%s'.",
			tostring(transaction.phase))
	end
	if settled and _extension_cleanup == transaction then _extension_cleanup = nil end
	if not settled then
		Logger.error(LOG, "Extension transaction cleanup remains pending; installation is blocked.")
	end
	return settled
end

--- Recovers a durable journal or cleans only harmless pre-journal orphans.
--- @param paths table Deterministic transaction paths.
--- @return boolean settled Whether a new transaction may start.
local function settle_persisted_extension_state(paths)
	local read_safe, payload, read_error = read_file_with_status(paths.journal_path)
	if not read_safe then
		Logger.error(LOG, "Extension recovery journal is unreadable at '%s': %s.",
			paths.journal_path, tostring(read_error))
		return false
	end
	if payload == nil then
		if cleanup_pre_journal_orphans(paths) then return true end
		Logger.error(LOG, "Extension orphan cleanup remains pending; installation is blocked.")
		return false
	end

	local facts = decode_extension_journal(payload)
	if not facts then
		Logger.error(LOG, "Extension recovery journal is invalid at '%s'; installation is blocked.",
			paths.journal_path)
		return false
	end
	local transaction = new_recovery_transaction(paths, facts)
	if recover_extension_transaction(transaction) then return true end
	Logger.error(LOG, "Extension durable recovery remains pending; installation is blocked.")
	return false
end

--- Settles both in-process and reload-persistent transaction ownership.
--- @param paths table Deterministic transaction paths.
--- @return boolean settled Whether a new transaction may start.
local function settle_extension_state(paths)
	if _extension_cleanup then
		return settle_extension_transaction(_extension_cleanup)
	end
	return settle_persisted_extension_state(paths)
end

--- Aborts one transaction and retains any recovery debt for retry or reload.
--- @param transaction table Owned transaction.
--- @param stage string Failed transaction stage.
--- @param detail any Failure detail.
--- @return boolean Always false.
local function abort_extension_transaction(transaction, stage, detail)
	Logger.error(LOG, "Extension install %s failed in '%s': %s.", stage, EXT_DIR, tostring(detail))
	local settled
	if transaction.phase == "recovery" then
		settled = recover_extension_transaction(transaction)
	else
		transaction.phase = "cleanup_only"
		settled = cleanup_extension_sidecars(transaction, "pre-journal abort cleanup")
	end
	if settled then
		if _extension_cleanup == transaction then _extension_cleanup = nil end
	else
		Logger.error(LOG, "Extension install recovery remains pending after %s failure.", stage)
	end
	return false
end

--- Publishes the durable recovery journal before either final path changes.
--- @param transaction table Fully staged transaction.
--- @return boolean published Whether recovery is reload-safe.
local function publish_extension_journal(transaction)
	local payload = extension_journal_payload(
		transaction.entries[1].existed,
		transaction.entries[2].existed
	)
	local staged, stage_error = stage_payload(transaction.journal, "stage", payload)
	if not staged then
		return abort_extension_transaction(transaction, "journal staging", stage_error)
	end
	local published, publish_error = rename_owned_path(
		transaction.journal.stage_path,
		transaction.journal_path,
		"journal publication"
	)
	if not published then
		return abort_extension_transaction(transaction, "journal publication", publish_error)
	end
	transaction.journal.stage_owned = false
	transaction.journal_published = true
	transaction.phase = "recovery"
	return true
end

--- Publishes both candidates after the durable journal, then commits logically.
--- POSIX cannot atomically replace two unrelated pathnames: an external observer
--- between these renames may briefly see a mixed pair. The observable contract at
--- function return or after reload recovery is all-or-nothing.
--- @param transaction table Fully staged and journaled transaction.
--- @return boolean committed Whether the logical commit point was reached.
local function publish_extension_transaction(transaction)
	-- extension.js lands first; package.json is the manifest/commit marker. VS Code
	-- does not reload this unpacked extension until the post-commit notice asks the
	-- user to do so. A manually concurrent reload could still observe a new script
	-- under an incompatible old manifest; future incompatible schema changes (or a
	-- hot-reload lifecycle) require a versioned directory pointer instead.
	for publication_index, entry_index in ipairs({ 2, 1 }) do
		local entry = transaction.entries[entry_index]
		local published, publish_error = rename_owned_path(
			entry.stage_path,
			entry.path,
			"publication " .. tostring(publication_index)
		)
		if not published then
			return abort_extension_transaction(transaction, "publication", publish_error)
		end
		entry.stage_owned = false
		entry.published = true
	end

	transaction.phase = "commit_pending"
	local durable = finalize_extension_commit(transaction)
	return durable == true
end

--- Installs or updates the VSCode extension files locally.
--- @return boolean True if installation occurred and VSCode reload is required.
function M.install_extension()
	Logger.debug(LOG, "Verifying VSCode extension installation…")
	os.execute("mkdir -p " .. text_utils.shell_quote(EXT_DIR))

	local paths = extension_transaction_paths()
	if not settle_extension_state(paths) then return false end
	local pkg_path = paths.package_path
	local ext_path = paths.extension_path
	local pkg_read_safe, pkg_original, pkg_read_error = read_file_with_status(pkg_path)
	if not pkg_read_safe then
		Logger.error(LOG, "Extension install could not read existing '%s': %s.",
			pkg_path, tostring(pkg_read_error))
		return false
	end
	local ext_read_safe, ext_original, ext_read_error = read_file_with_status(ext_path)
	if not ext_read_safe then
		Logger.error(LOG, "Extension install could not read existing '%s': %s.",
			ext_path, tostring(ext_read_error))
		return false
	end
	local already_ok = (pkg_original == PACKAGE_JSON) and (ext_original == EXTENSION_JS)

	if already_ok then
		Logger.info(LOG, string.format("Extension already up to date (v%s).", EXT_VERSION))
		return false
	end

	local transaction = new_extension_transaction(paths, pkg_original, ext_original)
	local pkg_entry = transaction.entries[1]
	local ext_entry = transaction.entries[2]
	local ok_pkg, pkg_error = stage_payload(pkg_entry, "stage", pkg_entry.content)
	local ok_ext, ext_error = false, "package staging did not commit"
	if ok_pkg then ok_ext, ext_error = stage_payload(ext_entry, "stage", ext_entry.content) end
	if not ok_pkg or not ok_ext then
		return abort_extension_transaction(
			transaction,
			"staging",
			ok_pkg and ext_error or pkg_error
		)
	end

	for _, entry in ipairs(transaction.entries) do
		if entry.existed then
			local backed_up, backup_error = stage_payload(entry, "backup", entry.original)
			if not backed_up then
				return abort_extension_transaction(transaction, "backup staging", backup_error)
			end
		end
	end
	if not publish_extension_journal(transaction) then return false end
	if not publish_extension_transaction(transaction) then return false end

	Logger.info(LOG, string.format("Extension installed in %s.", EXT_DIR))
	-- A transient toast, through the layer that actually provides one.
	-- dialog_util.alert forwards to hs.dialog.alert, whose leading parameters are
	-- coordinates and a callback — passing it (message, duration) raised, and the
	-- throw travelled out of install_extension and aborted setup() before
	-- start_server() had run. The notice is cosmetic; it is also pcall'd, so it can
	-- no longer take anything with it.
	local ok_notify, notifications = pcall(require, "infra.notifications")
	if ok_notify and type(notifications.notify) == "function" then
		local ok_toast, err = pcall(notifications.notify, i18n.get("vscode.reload_required"), nil, "info")
		if not ok_toast then
			Logger.warn(LOG, "Reload notice could not be shown: %s.", tostring(err))
		end
	end
	return true
end





--- ==================================
--- ==================================
--- ======= 4/ HTTP Server API =======
--- ==================================
--- ==================================

local _caret  = nil
local _server = nil
local _server_cleanup = nil

--- Handles one request from the local VS Code extension.
--- @param method string HTTP method.
--- @param path string Request path.
--- @param _headers table Request headers.
--- @param body string Request body.
--- @return string body Response body.
--- @return number status HTTP status.
--- @return table headers Response headers.
local function handle_server_request(method, path, _headers, body)
	if path == "/caret" and method == "POST" then
		local ok, data = pcall(hs.json.decode, body)
		if ok and data then
			data._ts = hs.timer.secondsSinceEpoch()
			_caret = data
		end
	end
	return "{}", 200, { ["Content-Type"] = "application/json" }
end

--- Stops the exact committed server or uncommitted cleanup candidate.
--- Ownership is released only after the native result and listening port both
--- prove settlement, so a throw, refusal, or still-live socket remains retryable.
--- @param context string Lifecycle context for diagnostics.
--- @return boolean stopped Exact settlement result.
local function stop_owned_server(context)
	if _server and _server_cleanup and _server ~= _server_cleanup then
		Logger.error(LOG, "HTTP server %s found conflicting native owners.", context)
		return false
	end
	local owned = _server_cleanup or _server
	if not owned then return true end

	local stopped, stop_result = xpcall(function() return owned:stop() end, debug.traceback)
	if not stopped or stop_result ~= owned then
		Logger.error(LOG, "HTTP server %s did not stop transactionally: %s.",
			context, tostring(stop_result))
		return false
	end
	local port_ok, listening_port = xpcall(function() return owned:getPort() end, debug.traceback)
	if not port_ok or listening_port ~= 0 then
		Logger.error(LOG, "HTTP server %s remained live after stop (reported=%s).",
			context, tostring(listening_port))
		return false
	end

	if _server == owned then _server = nil end
	if _server_cleanup == owned then _server_cleanup = nil end
	return true
end

--- Rejects one uncommitted candidate and attempts exact rollback.
--- @param stage string Failed lifecycle stage.
--- @param detail any Native result or traceback.
--- @return boolean Always false.
local function reject_server_candidate(stage, detail)
	Logger.error(LOG, "HTTP server %s failed on port %d: %s.",
		stage, PORT, tostring(detail))
	if _server_cleanup and stop_owned_server("startup rollback") ~= true then
		Logger.error(LOG, "HTTP server cleanup remains pending after %s failure.", stage)
	end
	return false
end

--- Starts the HTTP server listening for caret payloads.
--- @return boolean started Exact commitment result.
function M.start_server()
	if _server or _server_cleanup then
		if M.stop_server() ~= true then return false end
	end
	Logger.debug(LOG, "Starting HTTP server on port %d…", PORT)

	local constructed, candidate = xpcall(function()
		return hs.httpserver.new(false, false)
	end, debug.traceback)
	if not constructed or candidate == nil or candidate == false then
		Logger.error(LOG, "HTTP server construction failed on port %d: %s.",
			PORT, tostring(candidate))
		return false
	end
	-- Publish cleanup ownership before the first native configuration call;
	-- `_server` itself remains unpublished until the socket proves its bind
	_server_cleanup = candidate

	local interface_set, interface_result = xpcall(function()
		return candidate:setInterface(SERVER_INTERFACE)
	end, debug.traceback)
	if not interface_set or interface_result ~= candidate then
		return reject_server_candidate("interface configuration", interface_result)
	end
	local port_set, port_result = xpcall(function()
		return candidate:setPort(PORT)
	end, debug.traceback)
	if not port_set or port_result ~= candidate then
		return reject_server_candidate("port configuration", port_result)
	end
	local callback_set, callback_result = xpcall(function()
		return candidate:setCallback(handle_server_request)
	end, debug.traceback)
	if not callback_set or callback_result ~= candidate then
		return reject_server_candidate("callback configuration", callback_result)
	end

	local started, start_result = xpcall(function() return candidate:start() end, debug.traceback)
	if not started or start_result ~= candidate then
		return reject_server_candidate("activation", start_result)
	end
	local port_ok, bound_port = xpcall(function() return candidate:getPort() end, debug.traceback)
	if not port_ok or bound_port ~= PORT then
		return reject_server_candidate("bind verification", bound_port)
	end

	_server = candidate
	_server_cleanup = nil
	Logger.info(LOG, "HTTP server started on %s:%d.", SERVER_INTERFACE, PORT)
	return true
end

--- Stops the HTTP server.
--- @return boolean stopped Exact settlement result.
function M.stop_server()
	if not _server and not _server_cleanup then return true end
	Logger.debug(LOG, "Stopping HTTP server…")
	if stop_owned_server("shutdown") ~= true then return false end
	Logger.info(LOG, "HTTP server stopped.")
	return true
end

--- Returns the latest caret data if it is fresh enough.
--- @param max_age number Maximum allowed age in seconds.
--- @return table|nil The caret data table.
function M.get_caret(max_age)
	if not _caret then return nil end
	if hs.timer.secondsSinceEpoch() - _caret._ts > (max_age or 5) then
		return nil
	end
	return _caret
end





-- =========================================
-- =========================================
-- ======= 5/ VSCode Window Tracking =======
-- =========================================
-- =========================================

--- Evaluates if VSCode is the currently active window.
--- @return boolean True if VSCode is active.
function M.is_vscode()
	local app = hs.application.frontmostApplication()
	return app ~= nil and app:bundleID() == "com.microsoft.VSCode"
end

--- Extracts the accessibility frame of the active editor, with a short-lived cache.
--- The raw AX call can block the Hammerspoon main thread for up to 100 ms on a
--- busy VSCode instance. Caching for FRAME_CACHE_TTL_S ensures that rapid calls
--- (e.g. one per streaming token) pay the AX cost at most once per 200 ms
--- (vscode-bridge-blocking-ax-call).
--- @return table|nil The bounds frame table, or nil on error / empty editor.
local function get_editor_ax_frame()
	local now = hs.timer.secondsSinceEpoch()
	-- Gate on the validity flag, not on the cached value: a negative lookup is a
	-- real result worth caching for the TTL just like a successful one.
	if _ax_frame_valid and (now - _ax_frame_ts) < FRAME_CACHE_TTL_S then
		return _ax_frame_cache
	end
	local ok, frame = pcall(function()
		local ax      = require("hs.axuielement")
		local focused = ax.systemWideElement():attributeValue("AXFocusedUIElement")
		if not focused then return nil end
		local f = focused:attributeValue("AXFrame")
		if f and f.x and f.y and f.w and f.h and f.w > 100 and f.h > 50 then
			return f
		end
		return nil
	end)
	local result = ok and frame or nil
	_ax_frame_cache = result
	_ax_frame_ts    = now
	-- The lookup completed, so the cache is authoritative for the next TTL window
	-- whether the outcome was a frame or nil.
	_ax_frame_valid = true
	return result
end





-- =======================================
-- =======================================
-- ======= 6/ Position Estimation ========
-- =======================================
-- =======================================

--- Calculates the estimated pixel position based on API telemetry and AX bounds.
--- @return table|nil The estimated coordinates.
function M.estimate_position()
	if not M.is_vscode() then return nil end

	local caret = M.get_caret(5)
	if not caret or not caret.active then return nil end

	-- Guard required numeric fields: a POST body like {"active":true} without
	-- line/visibleStartLine/character would throw on the arithmetic below.
	if type(caret.line) ~= "number"
		or type(caret.visibleStartLine) ~= "number"
		or type(caret.character) ~= "number" then
		return nil
	end

	local editor_frame = get_editor_ax_frame()
	if not editor_frame then return nil end

	local relative_line = caret.line - caret.visibleStartLine
	if relative_line < 0 then return nil end

	local x = editor_frame.x + M.GUTTER_WIDTH + (caret.character * M.CHAR_WIDTH)
	local y = editor_frame.y + (relative_line * M.LINE_HEIGHT)

	if y > editor_frame.y + editor_frame.h - M.LINE_HEIGHT then return nil end
	if x > editor_frame.x + editor_frame.w - 20 then
		x = editor_frame.x + editor_frame.w - 20
	end

	return { x = x, y = y, h = M.LINE_HEIGHT, type = "vscode_caret" }
end

--- Initializes the bridge: starts the HTTP server, then installs the VS Code
--- extension. Called explicitly from init.lua after the tooltip subsystem is ready.
---
--- The server goes FIRST and the install is isolated. These two used to be chained
--- in the other order with nothing between them, so any throw inside the install —
--- including from the purely cosmetic "reload VS Code" notice at its very last
--- line — aborted setup() before the server existed. That happened on exactly the
--- boot that installed or updated the extension, and init.lua's call site pcalls
--- setup(), so the log said the bridge had failed and nothing said the server had
--- never been reached.
--- @return boolean started True when the caret server owns port 7878.
function M.setup()
	if M.start_server() ~= true then return false end
	local ok, err = pcall(M.install_extension)
	if not ok then
		Logger.error(LOG, "Extension install failed: %s — the caret server is up regardless.",
			tostring(err))
	end
	return true
end

return M
