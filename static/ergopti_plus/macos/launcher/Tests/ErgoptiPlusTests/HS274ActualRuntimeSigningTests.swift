// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274ActualRuntimeSigningTests.swift
// Native disposable TEST-ONLY signing qualification; no production identity.
// Retained direct Guardians retire before private credential cleanup.

import Darwin
import Foundation
import XCTest

private enum NativeDisposableSigningError: Error { case ownership }

private enum NativeSigningParentError: Error { case invalid; case system(Int32) }

/// Produce the same Foundation-selected parent through the actual Darwin filesystem.
/// The strict signer helper owns creation/custody; this producer acquires no authority.
private func nativeSigningParent(_ selected: URL) throws -> URL {
	guard selected.isFileURL, selected.path.hasPrefix("/"),
		!selected.path.utf8.contains(0) else { throw NativeSigningParentError.invalid }
	return try selected.withUnsafeFileSystemRepresentation { input in
		guard let input, input.pointee == 47 else { throw NativeSigningParentError.invalid }
		errno = 0
		guard let resolved = Darwin.realpath(input, nil) else {
			throw NativeSigningParentError.system(errno)
		}
		defer { Darwin.free(resolved) }
		guard let path = String(validatingUTF8: resolved), !path.isEmpty,
			path.hasPrefix("/") else { throw NativeSigningParentError.invalid }
		let result = URL(fileURLWithFileSystemRepresentation: resolved,
			isDirectory: true, relativeTo: nil)
		guard result.isFileURL, result.path.utf8.elementsEqual(path.utf8) else {
			throw NativeSigningParentError.invalid
		}
		// Refuse a namespace/URL round-trip change before appending the new UUID.
		return try result.withUnsafeFileSystemRepresentation { check in
			guard let check else { throw NativeSigningParentError.invalid }
			errno = 0
			guard let current = Darwin.realpath(check, nil) else {
				throw NativeSigningParentError.system(errno)
			}
			defer { Darwin.free(current) }
			guard Darwin.strcmp(resolved, current) == 0 else {
				throw NativeSigningParentError.invalid
			}
			return result
		}
	}
}

extension HS274NativePolicyQualificationTests {

	/// Actual Darwin calls only; no credentials, subprocesses or native leaf models.
	func testActualSigningParentCanonicalizationRefusesMissingAndLoopInputs() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let manager = FileManager.default
			let real = root.appendingPathComponent("parent-real")
			let alias = root.appendingPathComponent("parent-alias")
			let missing = root.appendingPathComponent("parent-missing")
			let loop = root.appendingPathComponent("parent-loop")
			try manager.createDirectory(at: real, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			try manager.createSymbolicLink(at: alias, withDestinationURL: real)
			try manager.createSymbolicLink(at: loop, withDestinationURL: loop)
			let ordinary = try nativeSigningParent(real)
			let canonical = try nativeSigningParent(alias)
			XCTAssertEqual(canonical.path.utf8.map { $0 }, ordinary.path.utf8.map { $0 })
			XCTAssertTrue(canonical.isFileURL && canonical.path.hasPrefix("/"))
			XCTAssertEqual(try nativeSigningParent(canonical), canonical)
			XCTAssertEqual(try manager.contentsOfDirectory(atPath: real.path), [])
			for (input, expected) in [(missing, ENOENT), (loop, ELOOP)] {
				XCTAssertThrowsError(try nativeSigningParent(input)) { error in
					guard let native = error as? NativeSigningParentError,
						case .system(let actual) = native else {
						XCTFail("Actual native parent errno refusal was not retained")
						return
					}
					XCTAssertEqual(actual, expected)
				}
			}
			let nonFile = try XCTUnwrap(URL(string: "https://example.invalid/signing-parent"))
			XCTAssertThrowsError(try nativeSigningParent(nonFile)) { error in
				guard let native = error as? NativeSigningParentError,
					case .invalid = native else {
					XCTFail("Non-filesystem parent must refuse before native resolution")
					return
				}
			}
			XCTAssertFalse(manager.fileExists(atPath: missing.path))
			XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: root.path)),
				Set(["parent-real", "parent-alias", "parent-loop"]))
		}
	}


	/// One ordinary XCTest retains the existing worker and SDK caller budgets.
	/// A disposable TEST-ONLY certificate is not a production identity fallback.
	/// Native BEFORE control: keep the current Foundation producer unchanged.
	/// Closed observations distinguish its two genuine ancestor checks; no credentials.
	func testActualSigningProducerCanonicalParentAndNewLeafBeforeCredentials() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let helper = source("hs274_native_signing_fixture.py")
			let privateRoot = try nativeSigningParent(FileManager.default.temporaryDirectory)
				.appendingPathComponent("ErgoptiTestOnlySigning-" + UUID().uuidString)
			guard !privateRoot.path.hasPrefix(parent.path + "/"), privateRoot != parent else {
				throw NativeDisposableSigningError.ownership
			}
			let script = root.appendingPathComponent("signing-producer-canonical.py")
			let program = #"""
			"""Observe the unchanged signing producer's filesystem contract without credentials."""

			from contextlib import contextmanager
			import hashlib
			import importlib.util
			import json
			import os
			from pathlib import Path
			import stat
			import sys
			import time

			PIN = "e026f815b4b301fedb96a3be95250637cf1134ed3c14df58212fde5c856c15f0"
			TICKET = "signing-producer-custody.json"


			def require(value):
			    if not value:
			        raise RuntimeError("probe_refused")


			def full(value):
			    return (
			        value.st_dev,
			        value.st_ino,
			        value.st_uid,
			        value.st_gid,
			        value.st_mode,
			        value.st_size,
			        value.st_mtime_ns,
			        value.st_ctime_ns,
			        value.st_nlink,
			    )


			@contextmanager
			def fixed_helper(path):
			    path = Path(path)
			    require(path.is_absolute() and path.resolve(strict=True) == path)
			    before = path.lstat()
			    require(
			        stat.S_ISREG(before.st_mode)
			        and before.st_nlink == 1
			        and before.st_uid == os.geteuid()
			        and 0 < before.st_size <= 256 * 1024
			    )
			    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
			    try:
			        require(full(os.fstat(descriptor)) == full(before))
			        data = bytearray()
			        while True:
			            chunk = os.read(descriptor, min(65536, 256 * 1024 + 1 - len(data)))
			            if not chunk:
			                break
			            data.extend(chunk)
			            require(len(data) <= 256 * 1024)
			        data = bytes(data)
			        require(len(data) == before.st_size and hashlib.sha256(data).hexdigest() == PIN)
			        require(full(os.fstat(descriptor)) == full(before) and full(path.lstat()) == full(before))
			        specification = importlib.util.spec_from_loader(
			            "signing_producer_fixed_helper", loader=None
			        )
			        helper = importlib.util.module_from_spec(specification)
			        helper.__file__ = str(path)
			        sys.modules[specification.name] = helper
			        exec(compile(data, str(path), "exec"), helper.__dict__)
			        yield helper
			        require(full(os.fstat(descriptor)) == full(before) and full(path.lstat()) == full(before))
			    finally:
			        # One close attempt. The real process Guardian owns physical exit ACK.
			        os.close(descriptor)


			def observed_create(helper, target):
			    observed = {
			        "parent_observed": False,
			        "new_leaf_observed": False,
			        "failure_stage": "none",
			        "reason": "none",
			    }
			    require(sys.gettrace() is None)
			    ancestor_code = helper._ancestors.__code__
			    creation_code = helper.create_private.__code__

			    def trace(frame, event, argument):
			        if (
			            frame.f_code is ancestor_code
			            and frame.f_back is not None
			            and frame.f_back.f_code is creation_code
			        ):
			            candidate = frame.f_locals.get("path")
			            stage = (
			                "parent_before_creation"
			                if candidate == target.parent
			                else "new_leaf_after_creation"
			                if candidate == target
			                else "unknown"
			            )
			            if event == "call":
			                if stage == "parent_before_creation":
			                    observed["parent_observed"] = True
			                elif stage == "new_leaf_after_creation":
			                    observed["new_leaf_observed"] = True
			            elif event == "exception" and type(argument[1]) is helper.FixtureRefusal:
			                observed["failure_stage"] = stage
			                check = getattr(argument[1], "ancestry_check", None)
			                observed["reason"] = (
			                    check
			                    if type(check) is str and check in ("canonical_path", "ancestor_directory")
			                    else "unclassified"
			                )
			        if (
			            frame.f_code is creation_code
			            and event == "exception"
			            and type(argument[1]) is helper.FixtureRefusal
			        ):
			            # _ancestors attaches its closed marker while unwinding its handler;
			            # observe that real marker when the exception reaches create_private.
			            check = getattr(argument[1], "ancestry_check", None)
			            observed["reason"] = (
			                check
			                if type(check) is str and check in ("canonical_path", "ancestor_directory")
			                else "unclassified"
			            )
			        return trace

			    sys.settrace(trace)
			    try:
			        try:
			            held = helper.create_private(target)
			        except helper.FixtureRefusal:
			            return None, observed
			        return held, observed
			    finally:
			        sys.settrace(None)


			def stamps(held):
			    return [list(identity) for _, identity in held]


			def current_stamps(helper, path, expected):
			    require(
			        type(expected) is list
			        and all(
			            type(row) is list
			            and len(row) == 4
			            and all(type(value) is int and value >= 0 for value in row)
			            for row in expected
			        )
			    )
			    actual = helper._ancestors(path)
			    require(stamps(actual) == expected)
			    helper._current_ancestors(actual)
			    return actual


			def observe(helper_path, target, scope):
			    target, scope = Path(target), Path(scope)
			    require(
			        target.is_absolute()
			        and target.name.startswith("ErgoptiTestOnlySigning-")
			        and scope.is_absolute()
			        and not os.path.lexists(target)
			    )
			    deadline = time.monotonic() + 30
			    with fixed_helper(helper_path) as helper:
			        scope_held = helper._ancestors(scope)
			        require(scope.stat().st_uid == os.geteuid() and stat.S_IMODE(scope.stat().st_mode) == 0o700)
			        require(not os.path.lexists(scope / TICKET))
			        parent_canonical = target.parent.resolve(strict=True) == target.parent
			        parent_held = helper._ancestors(target.parent) if parent_canonical else None
			        healthy_held, primary = observed_create(helper, target)
			        healthy = healthy_held is not None
			        if healthy:
			            helper._current_ancestors(healthy_held)
			            require(
			                stat.S_IMODE(target.stat().st_mode) == 0o700
			                and target.stat().st_uid == os.geteuid()
			            )
			            require(not tuple(target.iterdir()))
			        # A post-mkdir refusal remains observable, but its unacknowledged
			        # partial directory is retained. Cleanup below cannot admit that node.
			        partial_creation = not healthy and os.path.lexists(target)
			        real, alias = scope / "alias-real", scope / "alias-parent"
			        require(not os.path.lexists(real) and not os.path.lexists(alias))
			        real_held = helper.create_private(real)
			        alias.symlink_to("alias-real", target_is_directory=True)
			        alias_identity = full(alias.lstat())
			        alias_target = alias / "denied-leaf"
			        alias_held, refused = observed_create(helper, alias_target)
			        alias_refused = alias_held is None and refused["reason"] == "canonical_path"
			        alias_before = (
			            refused["failure_stage"] == "parent_before_creation"
			            and not (real / "denied-leaf").exists()
			        )
			        require(alias_refused and alias_before and not tuple(real.iterdir()))
			        helper._current_ancestors(scope_held)
			        if parent_held is not None:
			            helper._current_ancestors(parent_held)
			        helper._current_ancestors(real_held)
			        require(full(alias.lstat()) == alias_identity and os.readlink(alias) == "alias-real")
			        require(time.monotonic() < deadline)
			        ticket = {
			            "scope": stamps(scope_held),
			            "healthy": stamps(healthy_held) if healthy else None,
			            "parent": stamps(parent_held) if parent_held is not None else None,
			            "real": stamps(real_held),
			            "alias": list(alias_identity),
			        }
			        data = json.dumps(ticket, sort_keys=True, separators=(",", ":")).encode()
			        require(len(data) <= 16384)
			        descriptor = os.open(
			            scope / TICKET, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
			        )
			        try:
			            os.fchmod(descriptor, 0o600)
			            view = memoryview(data)
			            while view:
			                written = os.write(descriptor, view)
			                require(written > 0)
			                view = view[written:]
			            os.fsync(descriptor)
			        finally:
			            os.close(descriptor)
			        report = {
			            "healthy": healthy,
			            "parent_canonical": parent_canonical,
			            "new_leaf_canonical": healthy and target.resolve(strict=True) == target,
			            **primary,
			            "alias_refused": alias_refused,
			            "alias_before_creation": alias_before,
			            "source_current": True,
			            "captured_for_retirement": not partial_creation,
			        }
			    return report


			def cleanup(helper_path, target, scope):
			    target, scope = Path(target), Path(scope)
			    require(target.is_absolute() and target.name.startswith("ErgoptiTestOnlySigning-"))
			    with fixed_helper(helper_path) as helper:
			        record = helper.ordinary(scope / TICKET, 0o600, limit=16384)
			        ticket = json.loads(record.data)
			        require(
			            type(ticket) is dict and set(ticket) == {"scope", "healthy", "parent", "real", "alias"}
			        )
			        current_stamps(helper, scope, ticket["scope"])
			        real, alias = scope / "alias-real", scope / "alias-parent"
			        current_stamps(helper, real, ticket["real"])
			        require(
			            type(ticket["alias"]) is list
			            and len(ticket["alias"]) == 9
			            and all(type(v) is int for v in ticket["alias"])
			            and list(full(alias.lstat())) == ticket["alias"]
			            and os.readlink(alias) == "alias-real"
			        )
			        if ticket["parent"] is not None:
			            current_stamps(helper, target.parent, ticket["parent"])
			        if ticket["healthy"] is not None:
			            current_stamps(helper, target, ticket["healthy"])
			            require(
			                target.stat().st_uid == os.geteuid()
			                and stat.S_IMODE(target.stat().st_mode) == 0o700
			                and not tuple(target.iterdir())
			            )
			        else:
			            require(not os.path.lexists(target))
			        require(not tuple(real.iterdir()))
			        helper.current(record)
			        # The Swift caller invokes this only after original real Guardian ACK.
			        # Cooperative owned fixture cleanup; no hostile-writer atomicity claim.
			        if ticket["healthy"] is not None:
			            target.rmdir()
			        alias.unlink()
			        real.rmdir()
			        helper.current(record)
			        (scope / TICKET).unlink()
			    return {"removed": True, "source_current": True}


			if __name__ == "__main__":
			    try:
			        require(len(sys.argv) == 5 and sys.argv[1] in ("observe", "cleanup"))
			        action, helper, target, scope = sys.argv[1:]
			        result = (
			            observe(helper, target, scope)
			            if action == "observe"
			            else cleanup(helper, target, scope)
			        )
			        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
			    except BaseException:
			        print('{"reason":"probe_refused"}')
			        raise SystemExit(1)
			"""#
			try Data(program.utf8).write(to: script, options: .withoutOverwriting)
			try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
			let observed = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", script.path, "observe", helper.path, privateRoot.path, root.path], root: root)
			// A returned string cannot substitute for the actual Guardian's physical ACK.
			try retireOwnedChildren()
			let cleaned = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", script.path, "cleanup", helper.path, privateRoot.path, root.path], root: root)
			try retireOwnedChildren()
			XCTAssertEqual(observed.status, 0, "Native producer observation refused; " + observed.stdout)
			XCTAssertTrue(observed.stderr.isEmpty)
			XCTAssertEqual(observed.stdout,
				#"{"alias_before_creation":true,"alias_refused":true,"captured_for_retirement":true,"failure_stage":"none","healthy":true,"new_leaf_canonical":true,"new_leaf_observed":true,"parent_canonical":true,"parent_observed":true,"reason":"none","source_current":true}"# + "\n",
				"The unchanged Foundation producer must pass its genuine canonical parent and new-leaf checks")
			XCTAssertEqual(cleaned.status, 0, "Exact owned empty-directory retirement refused")
			XCTAssertEqual(cleaned.stdout, #"{"removed":true,"source_current":true}"# + "\n")
			XCTAssertTrue(cleaned.stderr.isEmpty)
		}
	}

	func testActualRuntimeSigningWithDisposableCredential() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let diagnostics = source("hs274_native_build.py").deletingLastPathComponent()
			let repository = diagnostics.deletingLastPathComponent().deletingLastPathComponent()
			let fixtureScript = diagnostics.appendingPathComponent("hs274_native_signing_fixture.py")
			let observerScript = diagnostics.appendingPathComponent("hs274_signed_runtime_observation.py")
			// Kept outside swift-launcher-evidence, including every refusal path.
			let privateRoot = try nativeSigningParent(FileManager.default.temporaryDirectory)
				.appendingPathComponent("ErgoptiTestOnlySigning-" + UUID().uuidString)
			guard !privateRoot.path.hasPrefix(parent.path + "/"), privateRoot != parent else {
				throw NativeDisposableSigningError.ownership
			}
			let publicOwner = root.appendingPathComponent("credential-public")
			let owner = root.appendingPathComponent("signed-compilation")
			let captures = root.appendingPathComponent("signed-observation")
			for directory in [publicOwner, owner, captures] {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
					attributes: [.posixPermissions: 0o700])
			}
			var primaryError: Error?
			do {
				let setup = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3", fixtureScript.path, "setup", privateRoot.path, publicOwner.path], root: root)
				XCTAssertEqual(setup.status, 0, "Native TEST-ONLY credential setup refused")
				XCTAssertTrue(setup.stderr.isEmpty)
				guard setup.status == 0, setup.stderr.isEmpty else { throw NativeDisposableSigningError.ownership }
				let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(setup.stdout.utf8)) as? [String: Any])
				guard Set(record.keys) == Set(["schema", "status", "identity", "public_leaf_sha256", "test_only",
					"shipping_qualified", "installation_qualified", "authentication_qualified"]),
					record["schema"] as? Int == 1, record["status"] as? String == "ready",
					record["test_only"] as? Bool == true,
					record["shipping_qualified"] as? Bool == false,
					record["installation_qualified"] as? Bool == false,
					record["authentication_qualified"] as? Bool == false else { throw NativeDisposableSigningError.ownership }
				let identity = try XCTUnwrap(record["identity"] as? String)
				guard identity.count == 40, identity.allSatisfy({ "0123456789ABCDEF".contains($0) }) else {
					throw NativeDisposableSigningError.ownership
				}
				// The credential exists before the ONE live compile/copy/sign handoff.
				let signed = try runOwnedRuntimeCompilation([repository.path, owner.path, "--sign-owned",
					"--budget", "300", "--signing-identity", identity, "--signing-keychain",
					privateRoot.appendingPathComponent("fixture.keychain-db").path, "--signing-public-leaf",
					privateRoot.appendingPathComponent("public-leaf.der").path], root: root)
				let expected = "PASS unsigned actual owned four-target compilation; signing and activation unqualified\n"
					+ "PASS retained unsigned runtime snapshot; native shipping and installation unqualified\n"
					+ "PASS fixed signed runtime snapshot; shipping, installation and live authentication unqualified\n"
				XCTAssertEqual(signed.status, 0, "Genuine disposable signing mechanics refused")
				XCTAssertEqual(signed.stdout, expected)
				XCTAssertTrue(signed.stderr.isEmpty)
				guard signed.status == 0, signed.stdout == expected, signed.stderr.isEmpty else {
					throw NativeDisposableSigningError.ownership
				}
				let observed = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", observerScript.path,
					repository.path, owner.path, publicOwner.appendingPathComponent("public-leaf.der").path,
					captures.path], root: root)
				XCTAssertEqual(observed.status, 0, "Native readonly signing observation refused")
				XCTAssertTrue(observed.stderr.isEmpty)
				guard observed.status == 0, observed.stderr.isEmpty else { throw NativeDisposableSigningError.ownership }
				let observation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observed.stdout.utf8)) as? [String: Any])
				guard Set(observation.keys) == Set(["schema", "status", "identity", "targets", "architectures",
					"test_only", "shipping_qualified", "installation_qualified", "authentication_qualified"]),
					observation["schema"] as? Int == 1, observation["status"] as? String == "observed",
					observation["identity"] as? String == identity, observation["targets"] as? Int == 5,
					observation["architectures"] as? [String] == ["x86_64", "arm64"],
					observation["test_only"] as? Bool == true,
					observation["shipping_qualified"] as? Bool == false,
					observation["installation_qualified"] as? Bool == false,
					observation["authentication_qualified"] as? Bool == false else { throw NativeDisposableSigningError.ownership }
			} catch { primaryError = error }
			// A thrown finish() can retain a native child. Never erase credentials
			// until the actual Guardian acknowledges retirement of every child.
			try retireOwnedChildren()
			if FileManager.default.fileExists(atPath: privateRoot.path) {
				let cleaned = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3", fixtureScript.path, "cleanup", privateRoot.path], root: root)
				XCTAssertEqual(cleaned.status, 0, "Exact TEST-ONLY keychain cleanup refused")
				XCTAssertEqual(cleaned.stdout, "{\"schema\": 1, \"status\": \"removed\", \"test_only\": true}\n")
				XCTAssertTrue(cleaned.stderr.isEmpty)
				guard cleaned.status == 0, cleaned.stderr.isEmpty,
					!FileManager.default.fileExists(atPath: privateRoot.path) else { throw NativeDisposableSigningError.ownership }
			}
			if let primaryError { throw primaryError }
		}
	}
}
