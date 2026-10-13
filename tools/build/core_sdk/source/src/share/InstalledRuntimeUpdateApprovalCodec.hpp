// Closed scalar grammar only. Parsing this record never creates authority.
#pragma once
#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <string_view>

namespace ergoptiplus::installed_maintenance::update_detail {
struct approval_record {
  std::array<std::string, 15> text{};
  std::array<std::uint64_t, 15> number{};
};
inline constexpr std::array<std::string_view, 15> keys{
  "kind", "operation", "helperPID", "helperSeconds", "helperMicroseconds", "helperImage",
  "helperCDHash1", "helperCDHash2", "oldCorePID", "oldCoreSeconds", "oldCoreMicroseconds",
  "oldLeaf", "newLeaf", "oldRuntimeDevice", "oldRuntimeInode"
};
inline bool string_field(std::size_t index) {
  return index == 0 || index == 1 || index == 5 || index == 6 || index == 7 || index == 11 || index == 12;
}
class scalar_parser final {
public:
  explicit scalar_parser(std::string_view bytes) : bytes_(bytes) {}
  std::optional<approval_record> parse() {
    if (bytes_.empty() || bytes_.size() > 8192 || !take('{')) return std::nullopt;
    approval_record result;
    std::array<bool, 15> seen{};
    for (std::size_t count = 0; count < keys.size(); ++count) {
      auto name = string();
      if (!name || !take(':')) return std::nullopt;
      std::size_t index = 0;
      while (index < keys.size() && keys[index] != *name) ++index;
      if (index == keys.size() || seen[index]) return std::nullopt;
      seen[index] = true;
      if (string_field(index)) {
        auto value = string();
        if (!value) return std::nullopt;
        result.text[index] = std::move(*value);
      } else {
        auto value = integer();
        if (!value) return std::nullopt;
        result.number[index] = *value;
      }
      if (!take(count + 1 == keys.size() ? '}' : ',')) return std::nullopt;
    }
    whitespace();
    if (position_ != bytes_.size() || result.text[0] != "approved-update-v1"
        || result.text[1] != "confirmed-runtime-update" || !pid(result.number[2]) || !pid(result.number[8])
        || result.number[2] == result.number[8] || !stage_image(result.text[5])
        || result.number[3] == 0 || result.number[9] == 0 || result.number[4] >= 1000000
        || result.number[10] >= 1000000 || result.number[14] == 0
        || !hash(result.text[6]) || !hash(result.text[7]) || result.text[6] >= result.text[7]
        || !leaf_hash(result.text[11]) || !leaf_hash(result.text[12])) return std::nullopt;
    return result;
  }
private:
  static bool stage_image(std::string_view value) {
    constexpr std::string_view prefix = "/Library/Application Support/ErgoptiPlus/.runtime-installer-";
    constexpr std::string_view suffix = "/Helper.app/Contents/MacOS/ErgoptiPlus-Runtime-Installer";
    if (value.size() != prefix.size() + 36 + suffix.size()
        || value.substr(0, prefix.size()) != prefix
        || value.substr(value.size() - suffix.size()) != suffix) return false;
    const auto uuid = value.substr(prefix.size(), 36);
    for (std::size_t index = 0; index < uuid.size(); ++index) {
      if (index == 8 || index == 13 || index == 18 || index == 23) {
        if (uuid[index] != '-') return false;
      } else if (hex(uuid[index]) < 0) return false;
    }
    return true;
  }
  static bool pid(std::uint64_t value) { return value > 1 && value <= 2147483647; }
  static bool hash(const std::string& value) {
    if (value.size() != 40 && value.size() != 64) return false;
    for (auto byte : value) if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f'))) return false;
    return true;
  }
  static bool leaf_hash(const std::string& value) {
    if (value.size() != 44 || value[43] != '=') return false;
    constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (std::size_t index = 0; index < 43; ++index) if (alphabet.find(value[index]) == std::string_view::npos) return false;
    // 32 decoded bytes leave two padding bits. Refuse noncanonical aliases.
    return (alphabet.find(value[42]) & 3) == 0;
  }
  void whitespace() {
    while (position_ < bytes_.size() && (bytes_[position_] == ' ' || bytes_[position_] == '\t'
        || bytes_[position_] == '\r' || bytes_[position_] == '\n')) ++position_;
  }
  bool take(char value) {
    whitespace();
    if (position_ == bytes_.size() || bytes_[position_] != value) return false;
    ++position_; return true;
  }
  static int hex(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
  }
  std::optional<std::string> string() {
    if (!take('"')) return std::nullopt;
    std::string result;
    while (position_ < bytes_.size()) {
      unsigned char value = bytes_[position_++];
      if (value == '"') return result;
      if (value < 32 || value >= 128) return std::nullopt;
      if (value == '\\') {
        if (position_ == bytes_.size()) return std::nullopt;
        value = bytes_[position_++];
        if (value == 'u') {
          if (bytes_.size() - position_ < 4) return std::nullopt;
          unsigned code = 0;
          for (int index = 0; index < 4; ++index) {
            const auto digit = hex(bytes_[position_++]);
            if (digit < 0) return std::nullopt;
            code = 16 * code + static_cast<unsigned>(digit);
          }
          if (code >= 128) return std::nullopt; // All closed producer strings are ASCII.
          value = static_cast<unsigned char>(code);
        } else if (value == 'b') value = '\b';
        else if (value == 'f') value = '\f';
        else if (value == 'n') value = '\n';
        else if (value == 'r') value = '\r';
        else if (value == 't') value = '\t';
        else if (value != '"' && value != '\\' && value != '/') return std::nullopt;
      }
      result.push_back(static_cast<char>(value));
    }
    return std::nullopt;
  }
  std::optional<std::uint64_t> integer() {
    whitespace();
    if (position_ == bytes_.size() || bytes_[position_] < '0' || bytes_[position_] > '9') return std::nullopt;
    const bool zero = bytes_[position_] == '0';
    std::uint64_t result = 0;
    do {
      const auto digit = static_cast<unsigned>(bytes_[position_++] - '0');
      if (result > (std::numeric_limits<std::uint64_t>::max() - digit) / 10) return std::nullopt;
      result = result * 10 + digit;
      if (zero && position_ < bytes_.size() && bytes_[position_] >= '0' && bytes_[position_] <= '9') return std::nullopt;
    } while (position_ < bytes_.size() && bytes_[position_] >= '0' && bytes_[position_] <= '9');
    return result;
  }
  std::string_view bytes_;
  std::size_t position_ = 0;
};
} // namespace ergoptiplus::installed_maintenance::update_detail
