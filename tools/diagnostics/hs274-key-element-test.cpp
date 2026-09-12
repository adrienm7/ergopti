// tools/diagnostics/hs274-key-element-test.cpp
// Execute the emitted native inspection with controlled HID API results.
#include "hs274-key-element.hpp"
#include <cassert>
#include <memory>
#include <vector>

struct Element {
  unsigned page = 7, usage = 44, bits = 1, count = 1;
  int type = 2, minimum = 0, maximum = 1;
  bool relative = false;
};
struct Value { Element element; int integer = 1; };
constexpr int kIOHIDElementTypeInput_Misc = 1, kIOHIDElementTypeInput_ScanCodes = 4;
const Element* IOHIDValueGetElement(const Value& value) { return &value.element; }
int IOHIDValueGetIntegerValue(const Value& value) { return value.integer; }
unsigned IOHIDElementGetUsagePage(const Element* e) { return e->page; }
unsigned IOHIDElementGetUsage(const Element* e) { return e->usage; }
int IOHIDElementGetType(const Element* e) { return e->type; }
bool IOHIDElementIsRelative(const Element* e) { return e->relative; }
unsigned IOHIDElementGetReportSize(const Element* e) { return e->bits; }
unsigned IOHIDElementGetReportCount(const Element* e) { return e->count; }
int IOHIDElementGetLogicalMin(const Element* e) { return e->minimum; }
int IOHIDElementGetLogicalMax(const Element* e) { return e->maximum; }

struct Monitor {
  bool ready = true;
  void stopped() { ready = false; }
};

bool inspect(Value input, bool selected = true) {
  const bool hs274_stream_selected_ = selected;
  Monitor hs274_monitor_;
  auto hid_values = std::make_shared<std::vector<Value>>();
  const auto value = std::make_shared<Value>(input);
        hid_values->emplace_back(*value);
  // Revocation must preserve every native value for the existing remapper.
  assert(hid_values->size() == 1);
  assert(hid_values->front().integer == input.integer);
  return hs274_monitor_.ready;
}

int main() {
  Value key;
  assert(inspect(key));
  key.integer = 0;
  assert(inspect(key));
  key.integer = 1;
  for (int type = 1; type <= 4; ++type) {
    key.element.type = type;
    assert(inspect(key));
  }
  key = {};
  for (int variant = 0; variant < 11; ++variant) {
    Value invalid = key;
    switch (variant) {
      case 0: invalid.element.relative = true; break;
      case 1: invalid.element.bits = 8; break;
      case 2: invalid.element.count = 6; break;
      case 3: invalid.element.minimum = -1; break;
      case 4: invalid.element.maximum = 255; break;
      case 5: invalid.element.type = 129; break;
      case 6: invalid.element.type = 0; break;
      case 7: invalid.element.usage = 1; break;
      case 8: invalid.element.usage = 256; break;
      case 9: invalid.integer = 2; break;
      case 10: invalid.integer = -1; break;
    }
    assert(!inspect(invalid));
    assert(inspect(invalid, false));
  }
  key.element.page = 12;
  key.integer = 42;
  assert(inspect(key));
  key.element.page = 7;
  key.element.usage = 0;
  assert(inspect(key));
}
