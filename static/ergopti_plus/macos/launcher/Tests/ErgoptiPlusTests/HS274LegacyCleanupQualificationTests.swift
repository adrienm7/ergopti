// Native private-file acceptance; user UI and the unavailable original backup remain unqualified.
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension HS274NativePolicyQualificationTests {

	func testLegacyCleanupReceiptRefusesForeignUnretiredAndStalePolicyControls() throws {
		try fixture { root in
			let controller = root.appendingPathComponent("legacy-cleanup.py")
			try Data(Self.cleanupController.utf8).write(to: controller, options: .atomic)
			let repository = source("hs_legacy_cleanup_native.lua").deletingLastPathComponent()
				.deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", controller.path, "--repo", repository.path, "--root", root.path, "--portable"], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS cleanup portable receipt controls tests=11 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.isEmpty)
		}
	}

	func testActualLegacyCleanupPreservesForeignRulesBackupAndStaleDestination() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let controller = root.appendingPathComponent("legacy-cleanup.py")
			try Data(Self.cleanupController.utf8).write(to: controller, options: .atomic)
			let repository = source("hs_legacy_cleanup_native.lua").deletingLastPathComponent()
				.deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", controller.path, "--repo", repository.path, "--root", root.path], root: root)
			XCTAssertEqual(receipt.status, 0,
				"Actual private-file cleanup refused within unchanged SDK30/35/10; evidence: " + root.path
				+ "; " + String(reflecting: String(receipt.stderr.prefix(4096))))
			guard receipt.status == 0 else { return }
			XCTAssertTrue(receipt.stderr.isEmpty)
			let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(receipt.stdout.utf8)) as? [String: Any])
			XCTAssertEqual(packet["status"] as? String, "ok")
			XCTAssertEqual(packet["qualification"] as? String, "actual production legacy cleanup private files")
			XCTAssertEqual(packet["controller_budget_seconds"] as? Int, 25)
			let elapsed = try XCTUnwrap(packet["observation_retirement_seconds"] as? Double)
			XCTAssertTrue(elapsed.isFinite && elapsed >= 0 && elapsed < 25)
			let native = try XCTUnwrap(packet["native_result"] as? [String: Any])
			XCTAssertEqual(native["runtime"] as? String, "native Hammerspoon")
			let cases = try XCTUnwrap(native["case_results"] as? [[String: Any]])
			XCTAssertEqual(cases.compactMap { $0["id"] as? String }, [
				"remove_two_signature_conflicts", "unchanged_second_request",
				"stale_destination_after_verified_backup", "existing_backup_name",
				"backup_readback_changed", "invalid_original_refuses",
			])
			XCTAssertTrue(cases.allSatisfy { ($0["passed"] as? Bool) == true })
			let authority = try XCTUnwrap(native["authority"] as? [String: Any])
			XCTAssertEqual(authority["user_backup"] as? String, "unavailable")
			XCTAssertEqual(authority["physical_input"] as? String, "unexecuted")
			XCTAssertEqual(authority["ui_confirmation"] as? String, "unexecuted")
			XCTAssertEqual(authority["lease_initialized"] as? Bool, false)
			XCTAssertEqual(authority["installation"] as? Bool, false)
			// Keep the full source/owner receipt outside the disposable fixture. A giant
			// log line can interleave with XCTest's case-completion marker.
			let artifact = try Self.persistLegacyCleanupReceipt(receipt.stdout, parent: parent,
				name: "legacy-cleanup-receipt-" + UUID().uuidString + ".json")
			print(Self.legacyCleanupReceiptLog(artifact.name, bytes: artifact.bytes, cases: cases.count), terminator: "")
		}
	}

	private enum LegacyReceiptArtifactError: Error {
		case ownership, persistence
	}

	/// Capture the exact original stdout exclusively, retaining its own file until
	/// readback and ordinary descriptor closure succeed. No receipt is reserialized.
	static func persistLegacyCleanupReceipt(_ stdout: String, parent: URL, name: String) throws -> (name: String, bytes: Int) {
		let prefix = "legacy-cleanup-receipt-"
		let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.".utf8)
		guard parent.path.hasPrefix("/"), parent.resolvingSymlinksInPath() == parent,
			name.hasPrefix(prefix), name.hasSuffix(".json"), name.utf8.count == prefix.utf8.count + 36 + 5,
			name.utf8.allSatisfy({ allowed.contains($0) }),
			UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(5))) != nil else {
			throw LegacyReceiptArtifactError.ownership
		}
		let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
		guard parentDescriptor >= 0 else { throw LegacyReceiptArtifactError.ownership }
		var parentNeedsClose = true
		defer { if parentNeedsClose { close(parentDescriptor) } }
		var parentBefore = stat()
		guard fstat(parentDescriptor, &parentBefore) == 0,
			parentBefore.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), parentBefore.st_uid == geteuid() else {
			throw LegacyReceiptArtifactError.ownership
		}
		let descriptor = openat(parentDescriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else { throw LegacyReceiptArtifactError.persistence }
		let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		var streamNeedsClose = true
		defer { if streamNeedsClose { try? stream.close() } }
		let bytes = Data(stdout.utf8)
		try stream.write(contentsOf: bytes)
		try stream.synchronize()
		try stream.seek(toOffset: 0)
		let readback = try stream.readToEnd() ?? Data()
		var held = stat(), named = stat(), parentAfter = stat()
		guard readback == bytes, fstat(descriptor, &held) == 0,
			fstatat(parentDescriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
			lstat(parent.path, &parentAfter) == 0, parent.resolvingSymlinksInPath() == parent,
			parentAfter.st_dev == parentBefore.st_dev, parentAfter.st_ino == parentBefore.st_ino,
			parentAfter.st_uid == parentBefore.st_uid, parentAfter.st_mode == parentBefore.st_mode,
			held.st_dev == named.st_dev, held.st_ino == named.st_ino,
			held.st_mode == named.st_mode, held.st_uid == named.st_uid, held.st_size == named.st_size,
			held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_uid == geteuid(),
			held.st_mode & 0o7777 == 0o600, held.st_nlink == 1, named.st_nlink == 1,
			held.st_size == off_t(bytes.count) else { throw LegacyReceiptArtifactError.persistence }
		streamNeedsClose = false
		try stream.close()
		parentNeedsClose = false
		guard close(parentDescriptor) == 0 else { throw LegacyReceiptArtifactError.persistence }
		return (name, bytes.count)
	}

	static func legacyCleanupReceiptLog(_ name: String, bytes: Int, cases: Int) -> String {
		"HS274 legacy cleanup receipt file=" + name + " bytes=" + String(bytes) + " cases=" + String(cases) + "\n"
	}

	func testLegacyCleanupReceiptArtifactPreservesFullBytesAndSurvivesChildCleanup() throws {
		try fixture { parent in
			let child = parent.appendingPathComponent("disposable-fixture")
			try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let original = "FULL RECEIPT BEGIN\n" + String(repeating: "é-source-owner-census\n", count: 40_000) + "FULL RECEIPT END\n"
			let name = "legacy-cleanup-receipt-00000000-0000-0000-0000-000000000001.json"
			let artifact = try Self.persistLegacyCleanupReceipt(original, parent: parent, name: name)
			try FileManager.default.removeItem(at: child)
			let path = parent.appendingPathComponent(name)
			XCTAssertEqual(try Data(contentsOf: path), Data(original.utf8))
			XCTAssertEqual(artifact.bytes, original.utf8.count)
			XCTAssertEqual(artifact.name, name)
			let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
			XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
			XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
			let message = Self.legacyCleanupReceiptLog(artifact.name, bytes: artifact.bytes, cases: 6)
			XCTAssertEqual(message, "HS274 legacy cleanup receipt file=" + name + " bytes=" + String(original.utf8.count) + " cases=6\n")
			XCTAssertLessThan(message.utf8.count, 160)
			XCTAssertEqual(message.filter { $0 == "\n" }.count, 1)
			XCTAssertTrue(message.hasSuffix("\n"))
		}
	}

	func testLegacyCleanupReceiptArtifactRefusesExistingFileAndSymlinkWithoutOverwrite() throws {
		try fixture { parent in
			let name = "legacy-cleanup-receipt-00000000-0000-0000-0000-000000000002.json"
			let path = parent.appendingPathComponent(name)
			let foreign = Data("EXISTING RECEIPT MUST SURVIVE\n".utf8)
			try foreign.write(to: path, options: .withoutOverwriting)
			XCTAssertThrowsError(try Self.persistLegacyCleanupReceipt("replacement", parent: parent, name: name))
			XCTAssertEqual(try Data(contentsOf: path), foreign)
			let linkName = "legacy-cleanup-receipt-00000000-0000-0000-0000-000000000003.json"
			let link = parent.appendingPathComponent(linkName)
			try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
			XCTAssertThrowsError(try Self.persistLegacyCleanupReceipt("replacement", parent: parent, name: linkName))
			XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), path.path)
			XCTAssertEqual(try Data(contentsOf: path), foreign)
		}
	}

	func testLegacyCleanupReceiptArtifactRefusesAliasedParentAndInvalidName() throws {
		try fixture { parent in
			let name = "legacy-cleanup-receipt-00000000-0000-0000-0000-000000000004.json"
			let alias = parent.appendingPathComponent("alias")
			try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
			XCTAssertThrowsError(try Self.persistLegacyCleanupReceipt("receipt", parent: alias, name: name))
			XCTAssertThrowsError(try Self.persistLegacyCleanupReceipt("receipt", parent: parent, name: "../foreign.json"))
			XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path))
			XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["alias"])
		}
	}

	static let cleanupController = #"""
	import argparse
	import hashlib
	import json
	import math
	import os
	from pathlib import Path
	import re
	import shutil
	import stat
	import sys
	import time
	import uuid

	CASES = (
	    "remove_two_signature_conflicts",
	    "unchanged_second_request",
	    "stale_destination_after_verified_backup",
	    "existing_backup_name",
	    "backup_readback_changed",
	    "invalid_original_refuses",
	)
	AUTHORITY = {
	    "physical_input": "unexecuted",
	    "user_backup": "unavailable",
	    "ui_confirmation": "unexecuted",
	    "lease_initialized": False,
	    "installation": False,
	}


	def require(condition, message):
	    if not condition:
	        raise ValueError(message)


	def unique(pairs):
	    result = {}
	    for key, value in pairs:
	        require(key not in result, "Duplicate receipt key")
	        result[key] = value
	    return result


	def read_record(path):
	    def finite_float(raw):
	        value = float(raw)
	        require(math.isfinite(value), "Nonfinite JSON number")
	        return value

	    path = Path(path)
	    require(
	        path.is_absolute() and path.parent.resolve(strict=True) == path.parent,
	        "Aliased receipt parent",
	    )
	    info = path.lstat()
	    require(
	        stat.S_ISREG(info.st_mode)
	        and info.st_uid == os.geteuid()
	        and info.st_nlink == 1
	        and 0 < info.st_size <= 65536,
	        "Unsafe receipt",
	    )
	    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
	    try:
	        current = os.fstat(descriptor)
	        require(
	            (
	                current.st_dev,
	                current.st_ino,
	                current.st_size,
	                current.st_nlink,
	                current.st_uid,
	                current.st_mode,
	            )
	            == (info.st_dev, info.st_ino, info.st_size, info.st_nlink, info.st_uid, info.st_mode),
	            "Changed receipt inode",
	        )
	        data = os.read(descriptor, 65537)
	        require(len(data) == current.st_size, "Receipt read incomplete")
	        final = os.fstat(descriptor)
	        require(
	            (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns, final.st_ctime_ns)
	            == (
	                current.st_dev,
	                current.st_ino,
	                current.st_size,
	                current.st_mtime_ns,
	                current.st_ctime_ns,
	            ),
	            "Receipt changed during read",
	        )
	    finally:
	        os.close(descriptor)
	    return json.loads(
	        data,
	        object_pairs_hook=unique,
	        parse_float=finite_float,
	        parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite JSON")),
	    )


	def admit(packet, nonce, pid, version, report, before, after, observed_at, deadline):
	    require(
	        type(packet) is dict
	        and set(packet)
	        == {
	            "schema",
	            "status",
	            "runtime",
	            "pid",
	            "nonce",
	            "version",
	            "case_results",
	            "authority",
	        },
	        "Unexpected receipt fields",
	    )
	    require(
	        type(packet["schema"]) is int
	        and packet["schema"] == 1
	        and packet["status"] == "ok"
	        and packet["runtime"] == "native Hammerspoon",
	        "Native receipt scope differs",
	    )
	    require(
	        type(pid) is int and pid > 0 and type(packet["pid"]) is int and packet["pid"] == pid,
	        "Foreign native PID",
	    )
	    require(
	        type(nonce) is str
	        and re.fullmatch(r"[0-9a-f]{32}", nonce)
	        and packet["nonce"] == nonce
	        and type(version) is str
	        and version
	        and packet["version"] == version,
	        "Foreign runtime identity",
	    )
	    cases = packet["case_results"]
	    require(type(cases) is list and len(cases) == len(CASES), "Incomplete case inventory")
	    for expected, result in zip(CASES, cases, strict=True):
	        require(
	            type(result) is dict
	            and set(result) == {"id", "passed"}
	            and result["id"] == expected
	            and result["passed"] is True,
	            "Case identity or exact acknowledgement differs",
	        )
	    authority = packet["authority"]
	    require(type(authority) is dict and set(authority) == set(AUTHORITY), "Authority fields differ")
	    for key, value in AUTHORITY.items():
	        require(
	            type(authority[key]) is type(value) and authority[key] == value,
	            "Cleanup fixture cannot grant authority",
	        )
	    clock.validate_owner(report, pid)
	    require(
	        type(before) is dict and bool(before) and type(after) is dict and before == after,
	        "Source ownership changed",
	    )
	    for key, value in before.items():
	        require(
	            type(key) is str
	            and key
	            and type(value) is str
	            and re.fullmatch(r"[0-9a-f]{64}", value),
	            "Unqualified source identity",
	        )
	    for value in (observed_at, deadline):
	        require(
	            type(value) in (int, float)
	            and abs(value) <= 1e12
	            and math.isfinite(value)
	            and value >= 0,
	            "Invalid native deadline",
	        )
	    require(observed_at < deadline, "Native receipt completed after deadline")
	    return packet


	def portable():
	    import copy

	    report = {
	        "status": "ok",
	        "native_owner": {
	            "worker_pid": 42,
	            "group_id": 42,
	            "closed": True,
	            "reservation_lost": False,
	            "live_group_members": [],
	            "escaped_sessions_managed": False,
	        },
	    }
	    packet = {
	        "schema": 1,
	        "status": "ok",
	        "runtime": "native Hammerspoon",
	        "pid": 42,
	        "nonce": "0" * 32,
	        "version": "1.1.1",
	        "case_results": [{"id": name, "passed": True} for name in CASES],
	        "authority": dict(AUTHORITY),
	    }
	    before = {"source": "0" * 64}
	    cases = [
	        "healthy_six_exact_retired",
	        "foreign_pid",
	        "foreign_nonce",
	        "missing_case",
	        "duplicated_case",
	        "truthy_fact",
	        "unretired_process",
	        "late_receipt",
	        "source_changed",
	        "unexpected_field",
	        "duplicate_json_key",
	    ]
	    for name in cases:
	        value, owner, after, end = copy.deepcopy(packet), copy.deepcopy(report), dict(before), 1
	        if name == "foreign_pid":
	            value["pid"] += 1
	        elif name == "foreign_nonce":
	            value["nonce"] = "1" * 32
	        elif name == "missing_case":
	            value["case_results"].pop()
	        elif name == "duplicated_case":
	            value["case_results"][1] = dict(value["case_results"][0])
	        elif name == "truthy_fact":
	            value["case_results"][0]["passed"] = 1
	        elif name == "unretired_process":
	            owner["native_owner"]["closed"] = False
	        elif name == "late_receipt":
	            end = 3
	        elif name == "source_changed":
	            after["source"] = "1" * 64
	        elif name == "unexpected_field":
	            value["unexpected"] = True
	        try:
	            if name == "duplicate_json_key":
	                json.loads('{"pid":42,"p\\u0069d":42}', object_pairs_hook=unique)
	            else:
	                admit(value, "0" * 32, 42, "1.1.1", owner, before, after, end, 2)
	        except ValueError:
	            require(name != "healthy_six_exact_retired", "Healthy parser refused")
	        else:
	            require(
	                name == "healthy_six_exact_retired", "Negative parser control accepted: " + name
	            )
	    print("PASS cleanup portable receipt controls tests=11 failures=0 errors=0 skipped=0")


	def source_inventory(repo):
	    files = {}
	    extensions = {".lua", ".json", ".toml"}
	    for relative in ("static/ergopti_plus/macos", "static/ergopti_plus/_shared", "static/layouts"):
	        tree = repo / relative
	        require(tree.is_dir() and tree.resolve(strict=True) == tree, "Unsafe source root")
	        for path in tree.rglob("*"):
	            if any(part in {".build", "node_modules", "__pycache__"} for part in path.parts):
	                continue
	            if path.suffix not in extensions:
	                continue
	            require(path.resolve(strict=True) == path and path.is_file(), "Source alias refused")
	            files[str(path.relative_to(repo))] = hashlib.sha256(path.read_bytes()).hexdigest()
	    for relative in (
	        "tools/diagnostics/hs_legacy_cleanup_native.lua",
	        "tools/diagnostics/fixtures/karabiner-legacy-cleanup-acceptance.json",
	        "tools/diagnostics/macos_physical_clock.py",
	        "tools/diagnostics/macos_tooltip_canvas.py",
	        "tools/diagnostics/macos_owned_process.py",
	        "tools/build/build_macos_app.sh",
	        ".github/workflows/ci-macos.yml",
	        "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274LegacyCleanupQualificationTests.swift",
	    ):
	        path = repo / relative
	        require(path.resolve(strict=True) == path and path.is_file(), "Source alias refused")
	        files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
	    return files


	def native(repo, root):
	    require(
	        sys.platform == "darwin" and sys.version_info >= (3, 13),
	        "Native macOS CPython3.13 required",
	    )
	    start = time.monotonic()
	    deadline = start + 25
	    root = clock.ordinary_owner_root(root)
	    repo = repo.resolve(strict=True)
	    before = source_inventory(repo)
	    output = root / "legacy-cleanup"
	    output.mkdir(mode=0o700)
	    copied = output / "source"
	    for relative in before:
	        destination = copied / relative
	        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
	        shutil.copyfile(repo / relative, destination)
	    executable, provisioning = clock.acquire_runtime(
	        repo, output, min(deadline, time.monotonic() + 10)
	    )
	    nonce = uuid.uuid4().hex
	    owner.exclusive_receipt(
	        output / "configuration.json",
	        {
	            "source": str(copied),
	            "root": str(output),
	            "nonce": nonce,
	            "version": provisioning["version"],
	        },
	    )
	    configuration_hash = hashlib.sha256((output / "configuration.json").read_bytes()).hexdigest()
	    config = output / "init.lua"
	    # Source/JSON/filesystem are actual; only log/config location recording is modeled.
	    config.write_text("""local json = require("hs.json")
	local location = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
	local config = assert(json.read(location .. "/configuration.json"))
	package.path = config.source .. "/static/ergopti_plus/macos/?.lua;" .. config.source .. "/static/ergopti_plus/macos/?/init.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
	local noop = function() end
	package.loaded["infra.logger"] = { info=noop, warn=noop, error=noop, debug=noop, start=noop, done=noop, success=noop, trace=noop }
	package.loaded["infra.config_paths"] = { get_config_dir=function() return config.root .. "/" end }
	local scenario = assert(dofile(config.source .. "/tools/diagnostics/hs_legacy_cleanup_native.lua"))
	local corpus = assert(json.read(config.source .. "/tools/diagnostics/fixtures/karabiner-legacy-cleanup-acceptance.json"))
	local context = scenario.context(config.source .. "/static/ergopti_plus/macos/platform/remap/data/")
	local results = {}
	for _, id in ipairs(corpus.case_ids) do
	    local path = config.root .. "/" .. id
	    assert(hs.fs.mkdir(path))
	    results[#results+1] = scenario.run_case(path, corpus, id, context)
	end
	local controller = package.loaded["platform.remap.lease_controller"]
	assert(controller == nil or controller.is_initialized() == false)
	local packet = {schema=1,status="ok",runtime="native Hammerspoon",pid=hs.processInfo.processID,nonce=config.nonce,version=hs.processInfo.version,case_results=results,authority={physical_input="unexecuted",user_backup="unavailable",ui_confirmation="unexecuted",lease_initialized=false,installation=false}}
	local encoded = assert(json.encode(packet, true))
	local file = assert(io.open(config.root .. "/result.pending", "wb"))
	assert(file:write(encoded))
	assert(file:close())
	assert(os.rename(config.root .. "/result.pending", config.root .. "/result.json"))
	""")
	    config_hash = hashlib.sha256(config.read_bytes()).hexdigest()
	    actual_pid = None

	    def unchanged():
	        require(
	            hashlib.sha256((output / "configuration.json").read_bytes()).hexdigest()
	            == configuration_hash,
	            "Native configuration changed",
	        )
	        require(source_inventory(repo) == before, "Live source changed")
	        for relative, expected in before.items():
	            require(
	                hashlib.sha256((copied / relative).read_bytes()).hexdigest() == expected,
	                "Copied source changed",
	            )
	        require(
	            hashlib.sha256(config.read_bytes()).hexdigest() == config_hash, "Native entry changed"
	        )
	        require(
	            hashlib.sha256(executable.read_bytes()).hexdigest()
	            == provisioning["executable_sha256"],
	            "Native runtime changed",
	        )

	    def operation(group):
	        nonlocal actual_pid
	        actual_pid = group.process.pid
	        probe_deadline = min(deadline, time.monotonic() + 10)
	        while time.monotonic() < probe_deadline:
	            require(group.observe_exit() is None, "Exact Hammerspoon child exited before receipt")
	            unchanged()
	            if (output / "result.json").exists():
	                record = read_record(output / "result.json")
	                require(
	                    group.observe_exit() is None, "Exact Hammerspoon child exited during receipt"
	                )
	                unchanged()
	                require(time.monotonic() < probe_deadline, "Native receipt read deadline")
	                return {"native_result": record}
	            time.sleep(0.01)
	        raise ValueError("Native cleanup observation deadline")

	    unchanged()
	    report = facade.owned_observation(
	        executable, config, output, operation, owner.NativeProcessGroups()
	    )
	    unchanged()
	    after = source_inventory(repo)
	    packet = admit(
	        report.get("native_result"),
	        nonce,
	        actual_pid,
	        provisioning["version"],
	        report,
	        before,
	        after,
	        time.monotonic(),
	        deadline,
	    )
	    result = {
	        "status": "ok",
	        "qualification": "actual production legacy cleanup private files",
	        "native_result": packet,
	        "native_owner": report["native_owner"],
	        "source_identities": before,
	        "provisioning": provisioning,
	        "controller_budget_seconds": 25,
	        "observation_retirement_seconds": time.monotonic() - start,
	    }
	    owner.exclusive_receipt(output / "qualification.json", result)
	    unchanged()
	    require(time.monotonic() < deadline, "Native qualification persistence exceeded deadline")
	    return result


	def main():
	    parser = argparse.ArgumentParser()
	    parser.add_argument("--repo", type=Path, required=True)
	    parser.add_argument("--root", type=Path, required=True)
	    parser.add_argument("--portable", action="store_true")
	    args = parser.parse_args()
	    sys.path.insert(0, str(args.repo / "tools/diagnostics"))
	    global clock, owner, facade
	    import macos_physical_clock as clock
	    import macos_owned_process as owner
	    import macos_tooltip_canvas as facade

	    clock.validate_imports(args.repo)
	    if args.portable:
	        portable()
	    else:
	        print(json.dumps(native(args.repo, args.root), sort_keys=True))


	if __name__ == "__main__":
	    main()
	"""#
}
