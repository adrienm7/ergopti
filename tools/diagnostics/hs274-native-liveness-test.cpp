// tools/diagnostics/hs274-native-liveness-test.cpp
// Portable owner/token lifetime controls; no native registry or kernel evidence.
#include "hs274-stream-source.hpp"
#include "hs274-stream-native-boundary.hpp"
#include <cassert>
#include <memory>
#include <new>
#include <cstdio>
#include <string>
using namespace hs274_stream_protocol;
using receiver_type = source<64, 8, 4>;
int main(int argc, char** argv) {
  assert(argc == 2);
  const std::string selected = argv[1];
  if (selected == "expired") {
    auto stale = [] {
      receiver_type receiver("expired", [] { return 100ULL; });
      return receiver.native_attach(1, false, hs274_key_policy::keyboard_type::none);
    }();
    unsigned work = 0, faults = 0;
    const bool accepted = diagnostic_acquisition(stale, [&](native_fault) { ++faults; }, [&] { ++work; return true; });
    assert(!stale.active());
    assert(work == 0 && faults == 0 && !accepted);
  } else if (selected == "destroy-during-success" || selected == "destroy-during-failure") {
    auto receiver = std::make_unique<receiver_type>("original", [] { return 100ULL; });
    auto owner = receiver->native_attach(1, false, hs274_key_policy::keyboard_type::none);
    unsigned work = 0, faults = 0;
    const bool accepted = diagnostic_acquisition(owner, [&](native_fault) { ++faults; }, [&]() -> bool {
      ++work;
      receiver.reset();
      if (selected == "destroy-during-failure") throw native_acquisition_error(native_fault::inventory_receipt_write_failed);
      return true;
    });
    assert(work == 1 && faults == 0 && !accepted && !owner.active());
  } else if (selected == "retire-rebind") {
    receiver_type receiver("rebind", [] { return 100ULL; });
    auto owner = receiver.native_attach(1, false, hs274_key_policy::keyboard_type::none);
    unsigned faults = 0;
    const bool accepted = diagnostic_acquisition(owner, [&](native_fault) { ++faults; }, [&] {
      using handle_type = receiver_type::native_registration;
      owner.~handle_type();
      new (&owner) handle_type(receiver.native_attach(1, false, hs274_key_policy::keyboard_type::none));
      return true;
    });
    assert(owner.active());
    assert(!accepted && faults == 0);
    assert(receiver.native_fault_reason() == native_fault::none);
  } else if (selected == "receiver-address-aba") {
    alignas(receiver_type) unsigned char storage[sizeof(receiver_type)];
    auto receiver = new (storage) receiver_type("old-address", [] { return 100ULL; });
    auto owner = receiver->native_attach(1, false, hs274_key_policy::keyboard_type::none);
    unsigned faults = 0;
    const bool accepted = diagnostic_acquisition(owner, [&](native_fault reason) {
      ++faults; receiver->native_failure(reason);
    }, [&]() -> bool {
      receiver->~receiver_type();
      receiver = new (storage) receiver_type("successor-address", [] { return 200ULL; });
      throw native_acquisition_error(native_fault::inventory_receipt_write_failed);
    });
    assert(!accepted && faults == 0 && !owner.active());
    assert(receiver->native_fault_reason() == native_fault::none);
    receiver->~receiver_type();
  } else if (selected == "failure-reentry") {
    auto receiver = std::make_unique<receiver_type>("fault-owner", [] { return 100ULL; });
    auto owner = receiver->native_attach(1, false, hs274_key_policy::keyboard_type::none);
    unsigned faults = 0;
    const bool accepted = diagnostic_acquisition(owner, [&](native_fault) {
      ++faults; receiver.reset();
    }, []() -> bool { throw native_acquisition_error(native_fault::inventory_receipt_write_failed); });
    assert(!accepted && faults == 1 && !owner.active());
  } else if (selected == "valid") {
    receiver_type receiver("valid", [] { return 100ULL; });
    auto owner = receiver.native_attach(1, false, hs274_key_policy::keyboard_type::none);
    unsigned faults = 0, work = 0;
    assert(diagnostic_acquisition(owner, [&](native_fault) { ++faults; }, [&] { ++work; return true; }));
    assert(work == 1 && faults == 0 && owner.active());
  } else return 2;
  std::puts("PASS exact owner lifetime control");
}
