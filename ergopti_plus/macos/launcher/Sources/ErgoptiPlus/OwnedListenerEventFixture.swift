// SDK-only genuine Unix/owned-image peer controls. No release dispatch.
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
import CPOSIXCompatibility
import Darwin
import Foundation

enum OwnedListenerEventFixture {
 static let flag = "--owned-listener-event-native-fixture"
 static let peerFlag = "--owned-listener-event-peer-fixture"
 static func handles(arguments: [String]) -> Bool {
  arguments.count > 1 && [flag, peerFlag].contains(arguments[1])
 }
 static func run(arguments: [String]) -> Int32 {
  prepareLeaseChildReaping()
  if arguments.count == 5 && arguments[1] == peerFlag {
   return ergopti_listener_event_peer_fixture(arguments[2], arguments[3], arguments[4])
  }
  guard arguments.count == 3, arguments[1] == flag,
   ["positive", "descendant", "missing-eof", "cancel-acquisition", "namespace-replacement", "uncertain-close"].contains(arguments[2]) else { return 64 }
  let status = ergopti_listener_event_native_fixture(arguments[0], arguments[2])
  print("ERGOPTI_LISTENER_EVENT_CONTROL pass=\(status == 0 ? 1 : 0)")
  return status
 }
}
#endif
