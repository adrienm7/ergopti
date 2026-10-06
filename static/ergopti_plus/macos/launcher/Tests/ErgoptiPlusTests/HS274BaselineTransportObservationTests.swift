// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274BaselineTransportObservationTests.swift
// Closed metadata evidence only; native transport and compilation remain unqualified.

import CoreFoundation
import Foundation
import XCTest

enum HS274BaselineTransportObservation {
	static let unsupported = #"{"acquisition_stage":null,"authority":false,"errno":null,"http_status":null,"kind":"xcodegen_transport_observation","native_verdict":"unchanged","schema":1,"status":"unsupported","transport_kind":null,"verify_code":null}"# + "\n"

	static func admitted(_ text: String) -> String? {
		let data = Data(text.utf8)
		guard data.count <= 2048, data.last == 10,
			let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			Set(value.keys) == Set(["schema", "kind", "status", "native_verdict", "authority",
				"acquisition_stage", "transport_kind", "http_status", "verify_code", "errno"]),
			value["kind"] as? String == "xcodegen_transport_observation",
			value["native_verdict"] as? String == "unchanged",
			let authority = value["authority"] as? NSNumber,
			CFGetTypeID(authority) == CFBooleanGetTypeID(), !authority.boolValue,
			let status = value["status"] as? String else { return nil }
		func integer(_ field: String, low: Int64, high: Int64) -> Bool {
			guard let number = value[field] as? NSNumber,
				CFGetTypeID(number) != CFBooleanGetTypeID(),
				Set(["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]).contains(String(cString: number.objCType)),
				number.doubleValue >= Double(low), number.doubleValue <= Double(high),
				number.doubleValue == Double(number.int64Value) else { return false }
			return true
		}
		guard integer("schema", low: 1, high: 1) else { return nil }
		let details = ["acquisition_stage", "transport_kind", "http_status", "verify_code", "errno"]
		if status == "unsupported" {
			guard details.allSatisfy({ value[$0] is NSNull }) else { return nil }
		} else {
			guard status == "observed", let stage = value["acquisition_stage"] as? String,
				Set(["metadata", "archive"]).contains(stage),
				let kind = value["transport_kind"] as? String,
				Set(["http_status", "tls_certificate_verification", "os_error", "tls_error",
					"timeout", "dns_resolution", "connection_refused", "connection_reset",
					"connection_error", "protocol_error", "other_transport", "deadline"]).contains(kind)
				else { return nil }
			for (field, allowedKind, low, high) in [
				("http_status", "http_status", Int64(100), Int64(599)),
				("verify_code", "tls_certificate_verification", Int64(0), Int64(2_147_483_647)),
				("errno", "os_error", Int64(1), Int64(4095)),
			] {
				if value[field] is NSNull { continue }
				guard kind == allowedKind, integer(field, low: low, high: high) else { return nil }
			}
		}
		guard let canonical = try? JSONSerialization.data(withJSONObject: value,
			options: [.sortedKeys, .withoutEscapingSlashes]), canonical + Data([10]) == data else { return nil }
		return String(data: canonical + Data([10]), encoding: .utf8)
	}
}

extension HS274NativePolicyQualificationTests {
	// Called only after the existing source-calibration invoker returned its
	// real retired result. This new fixed SDK child never executes a build.
	func printRetiredBaselineTransport(owner: URL, status: Int32, root: URL) {
		guard status != 0 else { return }
		do {
			let result = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("hs274_native_build_observation.py").path,
					owner.path, String(status), "--transport"], root: root)
			if result.status == 0, result.stderr.isEmpty,
				let admitted = HS274BaselineTransportObservation.admitted(result.stdout) {
				print(admitted, terminator: "")
			} else { print(HS274BaselineTransportObservation.unsupported, terminator: "") }
		} catch { print(HS274BaselineTransportObservation.unsupported, terminator: "") }
	}

	func testPortableTransportObservationUsesActualMetadataAndClosedControls() throws {
		try fixture { root in
			let result = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("hs274_native_build_transport_observation_test.py").path], root: root)
			XCTAssertEqual(result.status, 0)
			XCTAssertEqual(result.stdout,
				"PASS portable transport observation tests=24 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(result.stderr.contains("Ran 24 tests in "))
			XCTAssertTrue(result.stderr.hasSuffix("\nOK\n"))
		}
	}

	func testClosedTransportSummaryRejectsPrivateOrMalformedEvidence() {
		let http = #"{"acquisition_stage":"metadata","authority":false,"errno":null,"http_status":403,"kind":"xcodegen_transport_observation","native_verdict":"unchanged","schema":1,"status":"observed","transport_kind":"http_status","verify_code":null}"# + "\n"
		let tls = #"{"acquisition_stage":"archive","authority":false,"errno":null,"http_status":null,"kind":"xcodegen_transport_observation","native_verdict":"unchanged","schema":1,"status":"observed","transport_kind":"tls_certificate_verification","verify_code":7}"# + "\n"
		let errno = #"{"acquisition_stage":"metadata","authority":false,"errno":113,"http_status":null,"kind":"xcodegen_transport_observation","native_verdict":"unchanged","schema":1,"status":"observed","transport_kind":"os_error","verify_code":null}"# + "\n"
		XCTAssertEqual(HS274BaselineTransportObservation.admitted(http), http)
		XCTAssertEqual(HS274BaselineTransportObservation.admitted(tls), tls)
		XCTAssertEqual(HS274BaselineTransportObservation.admitted(errno), errno)
		XCTAssertEqual(HS274BaselineTransportObservation.admitted(HS274BaselineTransportObservation.unsupported), HS274BaselineTransportObservation.unsupported)
		XCTAssertNil(HS274BaselineTransportObservation.admitted(http.replacingOccurrences(of: "\"http_status\":403", with: "\"http_status\":true")))
		XCTAssertNil(HS274BaselineTransportObservation.admitted(http.replacingOccurrences(of: "\"http_status\":403", with: "\"http_status\":403.0")))
		XCTAssertNil(HS274BaselineTransportObservation.admitted(http.replacingOccurrences(of: "\"transport_kind\":\"http_status\"", with: "\"transport_kind\":\"timeout\"")))
		XCTAssertNil(HS274BaselineTransportObservation.admitted(http.replacingOccurrences(of: "\"schema\":1", with: "\"private\":\"SECRET\",\"schema\":1")))
		XCTAssertNil(HS274BaselineTransportObservation.admitted(http.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1,\"schema\":1")))
		XCTAssertNil(HS274BaselineTransportObservation.admitted(http.replacingOccurrences(of: "\"authority\":false", with: "\"authority\":true")))
	}
}
