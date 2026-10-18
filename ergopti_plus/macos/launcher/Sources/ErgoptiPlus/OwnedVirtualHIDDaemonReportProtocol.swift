// Sources/ErgoptiPlus/OwnedVirtualHIDDaemonReportProtocol.swift
import Foundation

/// Data from one official daemon request; no numeric ABI, currentness or startup capability.
enum OwnedVirtualHIDDaemonReportProtocol {
	struct Values: Equatable {
		let driverActivated: Bool
		let driverConnected: Bool
		let driverVersionMismatched: Bool
		let virtualHIDKeyboardReady: Bool
		let virtualHIDPointingReady: Bool
	}
	struct Request {
		let values: Values
		fileprivate let identifier: Data
	}
	/// Accepts only the exact vendor type4 request with five ordered Boolean tags.
	static func decode(_ bytes: Data) -> Request? {
		guard bytes.count == 23, Array(bytes.prefix(5)) == [0, 0, 0, 19, 4] else { return nil }
		let fields = Array(bytes.suffix(10))
		for index in 0..<5 {
			guard fields[index * 2] == UInt8(index + 1), fields[index * 2 + 1] <= 1 else { return nil }
		}
		return Request(values: Values(driverActivated: fields[1] == 1, driverConnected: fields[3] == 1,
			driverVersionMismatched: fields[5] == 1, virtualHIDKeyboardReady: fields[7] == 1,
			virtualHIDPointingReady: fields[9] == 1), identifier: bytes.subdata(in: 5..<13))
	}
	/// A delivery acknowledgment only. It neither requests HID effects nor acknowledges remote cleanup.
	static func acknowledgment(for request: Request) -> Data {
		var bytes = Data([0, 0, 0, 9, 5])
		bytes.append(request.identifier)
		return bytes
	}
	static func isHeartbeat(_ bytes: Data) -> Bool { bytes == Data([0, 0, 0, 1, 0]) }
}
