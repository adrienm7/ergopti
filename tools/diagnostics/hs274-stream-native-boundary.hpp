// tools/diagnostics/hs274-stream-native-boundary.hpp
// Exact weak-state/token fences contain only owned diagnostic acquisition failures.
#pragma once
#include "hs274-stream-native-fault.hpp"
#include <new>
namespace hs274_stream_protocol {
template <typename Owner, typename Failure, typename Work, typename Current>
bool diagnostic_acquisition(Owner& owner, Failure failure, Work work, Current current) {
  if (!owner.active()) return false;
  const auto fence = owner.capture_fence();
  const auto owned = [&] {
    if (!fence.live()) return false;
    const bool selected = current(fence);
    return fence.live() && selected;
  };
  if (!owned()) return false;
  try {
    const bool result = work();
    return owned() && result;
  } catch (const native_acquisition_error& error) {
    if (owned()) {
      fence.stopped();
      fence.fail(error.reason());
      if (owned()) failure(error.reason());
    }
    return false;
  } catch (const std::bad_alloc&) {
    if (owned()) {
      fence.stopped();
      fence.fail(native_fault::acquisition_resource_exhausted);
      if (owned()) failure(native_fault::acquisition_resource_exhausted);
    }
    return false;
  }
}

// Portable callers still require the exact captured owner/token fence.
template <typename Owner, typename Failure, typename Work>
bool diagnostic_acquisition(Owner& owner, Failure failure, Work work) {
  return diagnostic_acquisition(owner, failure, work, [](const auto&) { return true; });
}
} // namespace hs274_stream_protocol
