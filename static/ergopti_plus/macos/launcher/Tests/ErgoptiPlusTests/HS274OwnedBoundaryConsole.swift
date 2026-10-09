// TEST ONLY: bounded observations after the original Guardian ACK; no native authority.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum HS274OwnedBoundaryConsole {
	private static let fields: Set<String> = ["schema", "seq", "event", "span", "parent", "stage",
		"phase", "mono_ns", "elapsed_ns", "sync_ns", "code"]
	private static let integers: Set<String> = ["schema", "seq", "span", "parent", "mono_ns", "elapsed_ns", "sync_ns"]
	private static let stages: Set<String> = ["compilation", "inputs", "products", "product_capture",
		"staged_source", "pristine_source", "source_prepare", "source_dependencies", "source_materialize",
		"native_dispatch", "artifact_capture", "tool_acquisition"]
	private static let phases: Set<String> = Set(["", "unclassified", "xcode_version", "xcodegen_acquisition",
		"xcodegen_version", "sdk_path", "acquisition", "checkout", "submodules", "identity_upstream",
		"identity_cpm", "identity_vhd", "source_clean", "version", "instrumentation", "duktape_generate",
		"duktape_build", "duktape_architectures", "core_generate", "core_build", "core_architectures",
		"console_generate", "console_build", "console_architectures", "cli_generate", "cli_build", "cli_architectures",
		"signing_identity"]).union(Set((0..<3).flatMap { index in (0..<2).flatMap { level in
			["_sign", "_verify", "_x86_64_requirement", "_arm64_requirement", "_x86_64_leaf", "_arm64_leaf"]
				.map { "signing_\(index)_\(level)\($0)" }
		} }))
	private static let codes: Set<String> = ["", "unexpected", "other_refusal", "limit", "source_identity",
		"source_changed", "dependency_changed", "inventory", "unsafe_path", "owner_path", "owner_mode",
		"owner_identity", "tool_unavailable", "invalid_budget", "deadline", "phase_deadline", "phase_failed",
		"phase_log_limit", "phase_exit", "product_identity", "product_architectures", "product_metadata",
		"held_product_changed", "opened_incarnation", "read_currentness"]
	private static let events: Set<String> = ["writer_start", "writer_end", "enter", "complete", "refused",
		"overflow", "product_difference"]

	private enum Value {
		case integer(String), text(String)
		var literal: String {
			switch self { case .integer(let value), .text(let value): return value }
		}
	}

	/// Keep natural integer lexemes exact through 99999999999999999999.
	/// Foundation decodes only string fragments; no NSNumber/Double/Int64 conversion occurs.
	private struct FlatObject {
		let bytes: [UInt8]
		var offset = 0
		mutating func whitespace() {
			while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
		}
		mutating func take(_ byte: UInt8) -> Bool {
			whitespace()
			guard offset < bytes.count, bytes[offset] == byte else { return false }
			offset += 1
			return true
		}
		mutating func text() -> String? {
			whitespace()
			let start = offset
			guard offset < bytes.count, bytes[offset] == 34 else { return nil }
			offset += 1
			var escaped = false
			while offset < bytes.count {
				let byte = bytes[offset]
				offset += 1
				if escaped { escaped = false; continue }
				if byte == 92 { escaped = true; continue }
				if byte == 34 {
					let fragment = Data([91] + Array(bytes[start..<offset]) + [93])
					guard let values = try? JSONSerialization.jsonObject(with: fragment) as? [String],
						values.count == 1 else { return nil }
					return values[0]
				}
			}
			return nil
		}
		mutating func integer() -> String? {
			whitespace()
			let start = offset
			while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
			guard offset > start, offset - start <= 20,
				offset - start == 1 || bytes[start] != 48 else { return nil }
			return String(bytes: bytes[start..<offset], encoding: .utf8)
		}
		mutating func parse() -> [String: Value]? {
			guard take(123) else { return nil }
			var result: [String: Value] = [:]
			while true {
				guard result.count < 11, let key = text(), HS274OwnedBoundaryConsole.fields.contains(key), result[key] == nil,
					take(58) else { return nil }
				if HS274OwnedBoundaryConsole.integers.contains(key) {
					guard let value = integer() else { return nil }
					result[key] = .integer(value)
				} else {
					guard let value = text() else { return nil }
					result[key] = .text(value)
				}
				if take(125) { break }
				guard take(44) else { return nil }
			}
			whitespace()
			guard offset == bytes.count, Set(result.keys) == HS274OwnedBoundaryConsole.fields else { return nil }
			return result
		}
	}

	private struct Row {
		let values: [String: Value]
		subscript(_ key: String) -> String { values[key]!.literal }
	}
	private struct Span {
		let entered: Row
		var last: Row
		var finished: Bool
	}

	private static func decode(_ data: Data) -> (String, Int, [Span])? {
		guard !data.isEmpty, data.count <= 131072, data.last == 10,
			String(data: data, encoding: .utf8) != nil else { return nil }
		let lines = Array(data).split(separator: 10, omittingEmptySubsequences: false)
		guard lines.count > 1, lines.count - 1 <= 512 else { return nil }
		var order: [String] = [], spans: [String: Span] = [:]
		var state = "partial"
		for (index, line) in lines.dropLast().enumerated() {
			var scanner = FlatObject(bytes: Array(line))
			guard let values = scanner.parse() else { return nil }
			let row = Row(values: values), event = row["event"], span = row["span"], parent = row["parent"]
			guard row["schema"] == "1", row["seq"] == String(index + 1), events.contains(event),
				stages.contains(row["stage"]), phases.contains(row["phase"]), codes.contains(row["code"])
				else { return nil }
			if index == 0 && event != "writer_start" { return nil }
			switch event {
			case "writer_start", "writer_end", "overflow":
				guard span == "0", parent == "0", row["stage"] == "compilation", row["phase"].isEmpty
					else { return nil }
				if event == "writer_start" {
					guard index == 0, row["elapsed_ns"] == "0", row["code"].isEmpty else { return nil }
				} else {
					guard index == lines.count - 2,
						row["code"] == (event == "overflow" ? "limit" : "") else { return nil }
					state = event == "overflow" ? "overflow" : "writer_end_observed"
				}
			case "product_difference":
				guard span == "0", parent == "0", row["stage"] == "products", row["phase"].isEmpty,
					["held_product_changed", "opened_incarnation", "read_currentness"].contains(row["code"])
					else { return nil }
			case "enter":
				guard span != "0", spans[span] == nil, parent == "0" || spans[parent]?.finished == false,
					row["stage"] != "compilation",
					row["stage"] == "native_dispatch" ? !row["phase"].isEmpty : row["phase"].isEmpty,
					row["elapsed_ns"] == "0",
					row["code"].isEmpty else { return nil }
				order.append(span)
				spans[span] = Span(entered: row, last: row, finished: false)
			case "complete", "refused":
				guard var existing = spans[span], parent == "0" || spans[parent]?.finished == false,
					!spans.values.contains(where: { $0.entered["parent"] == span && !$0.finished }),
					existing.entered["parent"] == parent, existing.entered["stage"] == row["stage"],
					existing.entered["phase"] == row["phase"], event != "complete" || row["code"].isEmpty
					else { return nil }
				let productCut = existing.finished && event == "refused" && row["stage"] == "products"
					&& row["phase"].isEmpty && existing.last["event"] == "refused"
					&& existing.last["code"] == "source_identity"
					&& ["held_product_changed", "opened_incarnation", "read_currentness"].contains(row["code"])
				guard !existing.finished || productCut else { return nil }
				existing.last = row
				existing.finished = true
				spans[span] = existing
			default: return nil
			}
		}
		return (state, lines.count - 1, order.compactMap { spans[$0] }.filter {
			$0.entered["stage"] == "native_dispatch"
		})
	}

	static func project(_ data: Data?, workerStatus: Int32, guardianClosed: Bool) -> Data? {
		guard guardianClosed else { return nil }
		let decoded = data.flatMap { decode($0) }
		let state = decoded?.0 ?? "unsupported", all = decoded?.2 ?? []
		let selected = all.suffix(32)
		let rows = selected.map { span -> String in
			let row = span.last, elapsed = span.finished ? row["elapsed_ns"] : "null"
			return "{\"span\":\(row["span"]),\"phase\":\"\(row["phase"])\",\"event\":\"\(row["event"])\",\"elapsed_ns\":\(elapsed),\"code\":\"\(row["code"])\",\"phase_exit_status\":null}"
		}.joined(separator: ",")
		let output = "OWNED-BOUNDARY-OBSERVATION {\"schema\":1,\"authority\":false,\"native_verdict\":\"unchanged\",\"worker_exit_status\":\(workerStatus),\"group_scope\":\"original_closed_inherited_pgid\",\"escaped_sessions_managed\":false,\"journal_state\":\"\(state)\",\"writer_end_observed\":\(state == "writer_end_observed"),\"source_record_count\":\(decoded?.1 ?? 0),\"observed_native_spans\":\(all.count),\"omitted_native_spans\":\(all.count - selected.count),\"spans\":[\(rows)]}\n"
		let bytes = Data(output.utf8)
		return bytes.count <= 8192 ? bytes : nil
	}

	private static func directoryIdentity(_ a: stat, _ b: stat) -> Bool {
		a.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && b.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
			&& a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode
	}
	private static func fileIdentity(_ a: stat, _ b: stat) -> Bool {
		guard a.st_dev == b.st_dev, a.st_ino == b.st_ino, a.st_uid == b.st_uid, a.st_mode == b.st_mode,
			a.st_nlink == b.st_nlink, a.st_size == b.st_size else { return false }
		#if canImport(Darwin)
		return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
			&& a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
		#else
		return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec
			&& a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec
		#endif
	}

	/// One content read; held and named metadata cuts are observations, not an atomic snapshot.
	/// The optional cut is test-only and never used by the native invocation hook.
	static func capture(owner: URL, root: URL, afterSingleRead: (() -> Void)? = nil) -> Data? {
		guard root.isFileURL, owner.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0"),
			root.path.utf8.count <= 4096, root.resolvingSymlinksInPath() == root,
			owner == root.appendingPathComponent("owned") || owner == root.appendingPathComponent("owned-preparation")
			else { return nil }
		let components = owner.path.split(separator: "/").map(String.init)
		guard components.count <= 64, !components.contains("."), !components.contains("..") else { return nil }
		var held: [(Int32, URL, stat)] = []
		defer { for (descriptor, _, _) in held.reversed() { _ = close(descriptor) } }
		var path = URL(fileURLWithPath: "/", isDirectory: true)
		for component in [""] + components {
			let descriptor: Int32
			if held.isEmpty { descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
			else {
				path.appendPathComponent(component, isDirectory: true)
				descriptor = openat(held.last!.0, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			}
			guard descriptor >= 0 else { return nil }
			var info = stat(), named = stat()
			guard fstat(descriptor, &info) == 0 else { _ = close(descriptor); return nil }
			held.append((descriptor, path, info))
			guard lstat(path.path, &named) == 0, directoryIdentity(info, named) else { return nil }
			if path.path == root.path || path.path == owner.path {
				guard info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else { return nil }
			}
		}
		let basename = "owned-compilation-boundaries.jsonl", parent = held.last!.0
		let descriptor = openat(parent, basename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
		guard descriptor >= 0 else { return nil }
		defer { _ = close(descriptor) }
		var before = stat()
		guard fstat(descriptor, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
			before.st_uid == geteuid(), before.st_mode & 0o7777 == 0o600, before.st_nlink == 1,
			before.st_size > 0, before.st_size <= 131072 else { return nil }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
		guard let data = try? handle.read(upToCount: Int(before.st_size + 1)), data.count == Int(before.st_size)
			else { return nil }
		afterSingleRead?()
		var after = stat(), named = stat()
		guard fstat(descriptor, &after) == 0,
			fstatat(parent, basename, &named, AT_SYMLINK_NOFOLLOW) == 0,
			fileIdentity(before, after), fileIdentity(after, named) else { return nil }
		for (directory, selected, original) in held {
			var current = stat(), selectedInfo = stat()
			guard fstat(directory, &current) == 0, lstat(selected.path, &selectedInfo) == 0,
				directoryIdentity(original, current), directoryIdentity(current, selectedInfo) else { return nil }
		}
		guard owner.resolvingSymlinksInPath() == owner else { return nil }
		return data
	}

	static func observe(arguments: [String], root: URL, repository: URL,
		workerStatus: Int32, guardianClosed: Bool) {
		guard guardianClosed, workerStatus != 0, arguments.count == 5, arguments[0] == repository.path,
			["--compile-owned", "--prepare-owned"].contains(arguments[2]), arguments[3] == "--budget",
			arguments[4] == "300" else { return }
		let owner = URL(fileURLWithPath: arguments[1])
		guard owner.path == arguments[1], owner == root.appendingPathComponent("owned")
			|| owner == root.appendingPathComponent("owned-preparation") else { return }
		let captured = capture(owner: owner, root: root)
		guard let output = project(captured, workerStatus: workerStatus, guardianClosed: guardianClosed) else { return }
		do { try FileHandle.standardError.write(contentsOf: output) }
		catch { /* Diagnostic write refusal never replaces the original native Receipt. */ }
	}
}
