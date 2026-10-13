// tools/build/remap_runtime_installed_configuration.hpp
#pragma once

#include <nlohmann/json.hpp>
#include <optional>
#include <stdexcept>
#include <string>

namespace ergoptiplus::installed_configuration {
namespace document_detail {
inline void require(bool valid) {
  if (!valid) throw std::invalid_argument("Owned configuration generation is not closed");
}

inline bool canonical_generation(const std::string& value) {
  if (value.size() != 32) return false;
  for (const auto byte : value)
    if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f'))) return false;
  return true;
}

inline bool begins(const std::string& value, const std::string& prefix) {
  return value.compare(0, prefix.size(), prefix) == 0;
}

inline bool logical_name(const std::string& name) {
  if (name == "layer_active" || name == "capsword") return true;
  if (!begins(name, "ke_held_") || name.size() == 8) return false;
  for (const auto byte : name)
    if (!((byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '_')) return false;
  return true;
}

inline void reference(const std::string& name, const std::string& generation, bool writing) {
  require(!logical_name(name));
  bool reserved = false;
  for (const auto* prefix : {"ergopti_mode_", "ergopti_revoked_", "ergopti_lease_", "ergopti_pause_",
                            "ergopti_layer_active_", "ergopti_capsword_", "ergopti_ke_held_"})
    reserved = reserved || begins(name, prefix);
  if (!reserved) return;
  const auto mode = "ergopti_mode_" + generation;
  const auto revoked = "ergopti_revoked_" + generation;
  if (name == mode || name == revoked) {
    require(!writing);
    return;
  }
  require(name.size() > 8 + 33 && name[name.size() - 33] == '_');
  require(name.substr(name.size() - 32) == generation);
  require(logical_name(name.substr(8, name.size() - 8 - 33)));
}

inline void walk_references(const nlohmann::json& value, const std::string& generation) {
  if (value.is_array()) {
    for (const auto& child : value) walk_references(child, generation);
  } else if (value.is_object()) {
    if (value.contains("type") && value["type"].is_string() &&
        (value["type"] == "variable_if" || value["type"] == "variable_unless")) {
      require(value.contains("name") && value["name"].is_string());
      reference(value["name"].get<std::string>(), generation, false);
    }
    for (const auto& item : value.items()) {
      if (item.key() == "set_variable") {
        require(item.value().is_object() && item.value().contains("name") && item.value()["name"].is_string());
        reference(item.value()["name"].get<std::string>(), generation, true);
      }
      walk_references(item.value(), generation);
    }
  }
}

inline void live_gates(const nlohmann::json& event, const std::string& generation, int mode) {
  require(event.is_object() && event.contains("conditions") && event["conditions"].is_array());
  std::size_t modes = 0, revocations = 0;
  for (const auto& condition : event["conditions"]) {
    require(condition.is_object());
    if (!condition.contains("name") || !condition["name"].is_string()) continue;
    const auto name = condition["name"].get<std::string>();
    if (name != "ergopti_mode_" + generation && name != "ergopti_revoked_" + generation) continue;
    require(condition.contains("type") && condition["type"] == "variable_if" &&
            condition.contains("value") && condition["value"].is_number_integer());
    if (name == "ergopti_mode_" + generation) {
      require(condition["value"] == mode);
      ++modes;
    } else {
      require(condition["value"] == 0);
      ++revocations;
    }
  }
  require(modes == 1 && revocations == 1);
}
} // namespace document_detail

// This validates document data only. The private native snapshot constructor
// and original Core participant provide authority; a returned nonce does not.
inline std::string generation_from_document(const nlohmann::json& document) {
  using document_detail::require;
  require(document.is_object() && document.contains("profiles") &&
          document["profiles"].is_array() && !document["profiles"].empty());
  std::optional<std::string> generation;
  std::size_t selected = 0, selected_managed = 0;
  for (const auto& profile : document["profiles"]) {
    require(profile.is_object());
    if (profile.contains("selected")) require(profile["selected"].is_boolean());
    const auto is_selected = profile.contains("selected") && profile["selected"] == true;
    if (is_selected) ++selected;
    if (!profile.contains("complex_modifications")) continue;
    const auto& complex = profile["complex_modifications"];
    require(complex.is_object());
    if (!complex.contains("rules")) continue;
    require(complex["rules"].is_array());
    for (const auto& rule : complex["rules"]) {
      require(rule.is_object());
      if (!rule.contains("description") || !rule["description"].is_string()) continue;
      const auto description = rule["description"].get<std::string>();
      const std::string prefix = "[ErgoptiPlus managed:";
      if (!document_detail::begins(description, "[ErgoptiPlus managed")) continue;
      require(document_detail::begins(description, prefix) && description.size() > prefix.size() + 32);
      const auto token = description.substr(prefix.size(), 32);
      require(document_detail::canonical_generation(token));
      const auto tail = description.substr(prefix.size() + 32);
      const int mode = document_detail::begins(tail, ":normal] ") ? 1 :
                       document_detail::begins(tail, ":pause] ") ? 2 : 0;
      require(mode != 0);
      require(!generation || *generation == token);
      generation = token;
      require(rule.contains("manipulators") && rule["manipulators"].is_array() && !rule["manipulators"].empty());
      if (is_selected) ++selected_managed;
      for (const auto& manipulator : rule["manipulators"]) {
        document_detail::live_gates(manipulator, token, mode);
        if (manipulator.contains("to_if_held_down")) {
          require(manipulator["to_if_held_down"].is_array());
          for (const auto& event : manipulator["to_if_held_down"]) document_detail::live_gates(event, token, mode);
        }
      }
    }
  }
  require(selected == 1 && selected_managed != 0 && generation.has_value());
  document_detail::walk_references(document, *generation);
  return *generation;
}
} // namespace ergoptiplus::installed_configuration
