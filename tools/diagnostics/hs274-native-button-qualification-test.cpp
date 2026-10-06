// tools/diagnostics/hs274-key-element-test.cpp
// Execute the emitted native inspection with controlled HID API results.
#include "hs274-stream-key-policy.hpp"
#include <cassert>
#include <memory>
#include <vector>

struct Element {
  unsigned page = 7, usage = 44, bits = 1, count = 1;
  int type = 2, minimum = 0, maximum = 1;
  bool relative = false;
  bool array = false;
};
struct Value { Element element; int integer = 1; };
constexpr int kIOHIDElementTypeInput_Misc = 1, kIOHIDElementTypeInput_ScanCodes = 4;
const Element* IOHIDValueGetElement(const Value& value) { return &value.element; }
int IOHIDValueGetIntegerValue(const Value& value) { return value.integer; }
unsigned IOHIDElementGetUsagePage(const Element* e) { return e->page; }
unsigned IOHIDElementGetUsage(const Element* e) { return e->usage; }
int IOHIDElementGetType(const Element* e) { return e->type; }
bool IOHIDElementIsRelative(const Element* e) { return e->relative; }
bool IOHIDElementIsArray(const Element* e) { return e->array; }
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
  unsigned assertions = 0;
  for (unsigned page : {7U, 12U, 255U, 65281U}) {
    for (unsigned usage : {4U, 44U}) {
      Value value;
      value.element.page = page;
      value.element.usage = usage;
      assert(inspect(value)); ++assertions;
      value.integer = 0;
      assert(inspect(value)); ++assertions;
      value.integer = 2;
      assert(!inspect(value)); ++assertions;
      assert(inspect(value, false)); ++assertions;
      value.integer = 1;
      value.element.relative = true;
      assert(!inspect(value)); ++assertions;
    }
  }
  for (unsigned page : {12U, 255U, 65281U}) {
    Value fn;
    fn.element.page = page;
    fn.element.usage = 3;
    assert(inspect(fn)); ++assertions;
    fn.element.usage = 65535;
    assert(inspect(fn)); ++assertions;
    fn.element.usage = 65536;
    assert(!inspect(fn)); ++assertions;
  }
  Value auxiliary;
  auxiliary.element.page = 8;
  auxiliary.integer = 42;
  assert(inspect(auxiliary)); ++assertions;
  assert(assertions == 50);
}
