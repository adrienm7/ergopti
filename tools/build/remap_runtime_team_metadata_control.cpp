// Private native control: genuine CoreFoundation and the complete auth header.
// Metadata parsing alone grants no native signing or peer authority.
#include "remap_runtime_auth.hpp"
#include <iostream>
#include <initializer_list>
namespace detail = ergoptiplus::remap::auth::detail;
namespace {
unsigned cases = 0, failures = 0;
void record(const char* id, bool result) {
  ++cases;
  if (!result) ++failures;
  std::cout << "CASE " << id << ' ' << (result ? "PASS" : "FAIL") << '\n';
}
bool dictionary_case(CFTypeRef value, bool present,
                     const std::optional<std::string>& expected) {
  detail::cf_owned<CFDictionaryRef> dictionary;
  const void* key[] = {kSecCodeInfoTeamIdentifier};
  const void* values[] = {value};
  *dictionary.out() = CFDictionaryCreate(kCFAllocatorDefault, key, values,
      present ? 1 : 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  if (!dictionary.get() || CFGetTypeID(dictionary.get()) != CFDictionaryGetTypeID() ||
      CFDictionaryContainsKey(dictionary.get(), kSecCodeInfoTeamIdentifier) != present) return false;
  if (present && !CFEqual(CFDictionaryGetValue(dictionary.get(), kSecCodeInfoTeamIdentifier), value)) return false;
  const auto actual = detail::signing_team(dictionary.get());
  return expected ? actual && *actual == *expected : !actual;
}
bool string_case(std::initializer_list<UniChar> input,
                 const std::optional<std::string>& expected) {
  const UniChar empty = 0;
  detail::cf_owned<CFStringRef> string;
  *string.out() = CFStringCreateWithCharacters(kCFAllocatorDefault,
      input.size() ? input.begin() : &empty, static_cast<CFIndex>(input.size()));
  if (!string.get() || CFStringGetLength(string.get()) != static_cast<CFIndex>(input.size())) return false;
  if (input.size()) {
    std::vector<UniChar> observed(input.size());
    CFStringGetCharacters(string.get(), CFRangeMake(0, static_cast<CFIndex>(input.size())), observed.data());
    if (!std::equal(observed.begin(), observed.end(), input.begin(), input.end())) return false;
  }
  return dictionary_case(string.get(), true, expected);
}
} // namespace
int main() {
  record("null-dictionary", !detail::signing_team(nullptr));
  record("wrong-dictionary-type", !detail::signing_team(reinterpret_cast<CFDictionaryRef>(kCFBooleanTrue)));
  record("absent-team", dictionary_case(nullptr, false, std::string{}));
  record("present-ascii", string_case({'T','E','A','M','1'}, std::string{"TEAM1"}));
  record("present-unicode", string_case({0x00e9}, std::string{"\xc3\xa9"}));
  record("present-empty", string_case({}, std::nullopt));
  record("present-leading-nul", string_case({0,'T'}, std::nullopt));
  record("present-interior-nul", string_case({'T',0,'X'}, std::nullopt));
  record("present-high-surrogate", string_case({0xd800}, std::nullopt));
  record("present-low-surrogate", string_case({0xdc00}, std::nullopt));
  record("present-boolean", dictionary_case(kCFBooleanTrue, true, std::nullopt));
  {
    const UInt8 bytes[] = {'T'};
    detail::cf_owned<CFDataRef> data;
    *data.out() = CFDataCreate(kCFAllocatorDefault, bytes, 1);
    record("present-data", data.get() && CFDataGetLength(data.get()) == 1 && dictionary_case(data.get(), true, std::nullopt));
  }
  record("inventory", cases == 12);
  return failures ? 1 : 0;
}
