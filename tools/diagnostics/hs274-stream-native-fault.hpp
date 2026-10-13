// tools/diagnostics/hs274-stream-native-fault.hpp
// Sticky diagnostic failures, distinct from ordinary native remapping state.
#pragma once
#include <cstdint>
#include <stdexcept>
namespace hs274_stream_protocol {
enum class native_fault : std::uint8_t {
  none, inactive, registration_capacity_exhausted, registration_serial_exhausted,
  invalid_device_identity, duplicate_device_identity, invalid_device_type,
  acquisition_resource_exhausted, inventory_receipt_write_failed, reference_receipt_write_failed
};
inline const char* native_fault_name(native_fault reason) noexcept {
  switch (reason) {
    case native_fault::none: return "none";
    case native_fault::inactive: return "inactive";
    case native_fault::registration_capacity_exhausted: return "registration_capacity_exhausted";
    case native_fault::registration_serial_exhausted: return "registration_serial_exhausted";
    case native_fault::invalid_device_identity: return "invalid_device_identity";
    case native_fault::duplicate_device_identity: return "duplicate_device_identity";
    case native_fault::invalid_device_type: return "invalid_device_type";
    case native_fault::acquisition_resource_exhausted: return "acquisition_resource_exhausted";
    case native_fault::inventory_receipt_write_failed: return "inventory_receipt_write_failed";
    case native_fault::reference_receipt_write_failed: return "reference_receipt_write_failed";
  }
  return "invalid_native_fault";
}
class native_acquisition_error final : public std::runtime_error {
public:
  explicit native_acquisition_error(native_fault reason) : std::runtime_error(native_fault_name(reason)), reason_(reason) {}
  native_fault reason() const noexcept { return reason_; }
private:
  const native_fault reason_;
};
} // namespace hs274_stream_protocol
