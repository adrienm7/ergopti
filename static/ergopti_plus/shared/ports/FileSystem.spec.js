// static/ergopti_plus/shared/ports/FileSystem.spec.js

/**
 * ==============================================================================
 * PORT: FileSystem
 * DESCRIPTION:
 * Contract for synchronous file-system operations needed by domain modules.
 * Every driver adapter that touches the file system MUST satisfy this interface.
 * The port abstracts AHK's FileRead/FileAppend/FileExist built-ins (Windows)
 * and Lua's io.open / hs.fs APIs (macOS / Hammerspoon) behind a unified surface
 * so domain logic never imports OS-specific I/O primitives.
 *
 * FEATURES & RATIONALE:
 * 1. Minimal surface: only the five operations domain modules actually need —
 *    read, write, append, exists, and delete. No directory walking, no watching.
 * 2. Synchronous contract: all operations block and return immediately. Async
 *    wrappers are the caller's responsibility if non-blocking I/O is required.
 * 3. Fail-safe returns: read() returns null on any error (missing file, EPERM,
 *    encoding failure) rather than throwing. Callers check for null.
 * 4. UTF-8 everywhere: the adapter MUST read and write files as UTF-8. Platform
 *    default encodings (Windows-1252, etc.) are explicitly forbidden.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition ==============
// ==================================================
// ==================================================

/**
 * The FileSystem port contract.
 * @type {object}
 */
const portContract = {
	name: "FileSystem",
	version: "1.0.0",

	/**
	 * read(path) — Read the entire contents of a file as a UTF-8 string.
	 *   @param {string} path  Absolute path to the file.
	 *   @returns {string|null} File contents, or null on any error.
	 *   @error_behavior "return_null".
	 *
	 * write(path, content) — Overwrite a file with the given UTF-8 string.
	 *   Creates the file and any missing parent directories if needed.
	 *   @param {string} path     Absolute path to the file.
	 *   @param {string} content  UTF-8 content to write.
	 *   @returns {boolean} true on success, false on any error.
	 *   @error_behavior "return_false".
	 *
	 * append(path, content) — Append a UTF-8 string to a file.
	 *   Creates the file if it does not exist.
	 *   @param {string} path     Absolute path to the file.
	 *   @param {string} content  UTF-8 content to append.
	 *   @returns {boolean} true on success, false on any error.
	 *   @error_behavior "return_false".
	 *
	 * exists(path) — Check whether a file or directory exists at the given path.
	 *   @param {string} path  Absolute path to test.
	 *   @returns {boolean} true if the path exists, false otherwise.
	 *   @error_behavior "return_false".
	 *
	 * delete(path) — Delete a file. No-op (returns true) if the file does not exist.
	 *   @param {string} path  Absolute path to the file to delete.
	 *   @returns {boolean} true on success or if the file was already absent,
	 *                      false on any other error.
	 *   @error_behavior "return_false".
	 */
	methods: {
		read:   { arity: 1, required: true },
		write:  { arity: 2, required: true },
		append: { arity: 2, required: true },
		exists: { arity: 1, required: true },
		delete: { arity: 1, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator ==========
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a FileSystem adapter.
 * @param {object} adapter
 * @returns {string[]} Violations. Empty = compliant.
 */
function validateAdapter(adapter) {
	const violations = [];
	if (!adapter || typeof adapter !== "object") {
		return ["adapter must be a non-null object"];
	}
	for (const [name, spec] of Object.entries(portContract.methods)) {
		if (!spec.required) continue;
		if (typeof adapter[name] !== "function") {
			violations.push(`missing method: ${name}`);
		} else if (adapter[name].length !== spec.arity) {
			violations.push(
				`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`
			);
		}
	}
	return violations;
}




// ==================================================
// ==================================================
// ======= 3/ Compliance Test Vectors ===============
// ==================================================
// ==================================================

/**
 * Returns test vectors for FileSystem compliance.
 * Each vector exercises one method and asserts the return-value contract.
 * Vectors use the sentinel path "__FS_TEST_PATH__" — adapters under test
 * may substitute a real temp path; compliance vectors are structural only.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	const TEST_PATH = "__FS_TEST_PATH__";
	return [
		{
			id: "read_missing_returns_null",
			description: "read() on a non-existent path returns null, not an exception.",
			steps: [
				{ call: "read", args: [TEST_PATH + "_missing_9z3k"] },
				{ assert: "return_null" },
			],
		},
		{
			id: "write_creates_file",
			description: "write() succeeds and returns true for a writable path.",
			steps: [
				{ call: "write", args: [TEST_PATH, "hello"] },
				{ assert: "return_true" },
			],
		},
		{
			id: "read_after_write",
			description: "read() returns the content written by write().",
			steps: [
				{ call: "write", args: [TEST_PATH, "content_42"] },
				{ call: "read",  args: [TEST_PATH] },
				{ assert: "return_equals", expected: "content_42" },
			],
		},
		{
			id: "append_adds_content",
			description: "append() concatenates content to an existing file.",
			steps: [
				{ call: "write",  args: [TEST_PATH, "line1"] },
				{ call: "append", args: [TEST_PATH, "line2"] },
				{ call: "read",   args: [TEST_PATH] },
				{ assert: "return_contains", needle: "line2" },
			],
		},
		{
			id: "exists_true_for_written_file",
			description: "exists() returns true after write().",
			steps: [
				{ call: "write",  args: [TEST_PATH, "x"] },
				{ call: "exists", args: [TEST_PATH] },
				{ assert: "return_true" },
			],
		},
		{
			id: "exists_false_for_missing",
			description: "exists() returns false for a path that was never written.",
			steps: [
				{ call: "exists", args: [TEST_PATH + "_never_created_9z3k"] },
				{ assert: "return_false" },
			],
		},
		{
			id: "delete_removes_file",
			description: "delete() returns true and the file no longer exists.",
			steps: [
				{ call: "write",  args: [TEST_PATH, "to_delete"] },
				{ call: "delete", args: [TEST_PATH] },
				{ assert: "return_true" },
				{ call: "exists", args: [TEST_PATH] },
				{ assert: "return_false" },
			],
		},
		{
			id: "delete_missing_is_noop",
			description: "delete() on a non-existent path returns true without error.",
			steps: [
				{ call: "delete", args: [TEST_PATH + "_absent_9z3k"] },
				{ assert: "return_true" },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
