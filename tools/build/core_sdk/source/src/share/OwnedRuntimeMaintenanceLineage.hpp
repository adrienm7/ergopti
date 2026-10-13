// Captured only from the original authenticated installed CLI request.
#pragma once
#include "OwnedRuntimeMaintenanceNativeSocket.hpp"
#include "remap_runtime_installed_capture.hpp"
#include <CoreFoundation/CoreFoundation.h>
#include <libproc.h>
#include <array>
#include <filesystem>
#include <memory>

namespace ergoptiplus::installed_capture { class core_peer_owner; }
namespace ergoptiplus::installed_maintenance {
class core_endpoint;
class issuer_lineage final {
  friend class ::ergoptiplus::installed_capture::core_peer_owner;
  friend class core_endpoint;
  using capture = ergoptiplus::remap::auth::detail::peer_observation;
  issuer_lineage() = default;
  issuer_lineage(const issuer_lineage&) = delete;
  issuer_lineage& operator=(const issuer_lineage&) = delete;

  static std::optional<std::string> executable(pid_t pid) {
    std::array<char, PROC_PIDPATHINFO_MAXSIZE> bytes{};
    const int count = ::proc_pidpath(pid, bytes.data(), bytes.size());
    const auto end = static_cast<const char*>(std::memchr(bytes.data(), 0, bytes.size()));
    if (count <= 0 || !end || end == bytes.data() || bytes.front() != '/') return std::nullopt;
    const auto size = static_cast<std::size_t>(end - bytes.data());
    if (static_cast<std::size_t>(count) != size && static_cast<std::size_t>(count) != size + 1) return std::nullopt;
    return std::string(bytes.data(), size);
  }
  static std::optional<std::string> bundle_executable(const std::string& path, const char* expected) {
    namespace publisher = ergoptiplus::installed_publisher;
    publisher::detail::cf<CFURLRef> url;
    publisher::detail::cf<CFBundleRef> bundle;
    publisher::detail::cf<CFURLRef> main;
    url.value = CFURLCreateFromFileSystemRepresentation(nullptr,
        reinterpret_cast<const UInt8*>(path.data()), path.size(), true);
    if (!url.value) return std::nullopt;
    bundle.value = CFBundleCreate(nullptr, url.value);
    if (!bundle.value) return std::nullopt;
    const auto identifier = detail::exact_native_string(CFBundleGetIdentifier(bundle.value));
    main.value = CFBundleCopyExecutableURL(bundle.value);
    std::array<UInt8, PROC_PIDPATHINFO_MAXSIZE> bytes{};
    if (!identifier || *identifier != expected || !main.value ||
        !CFURLGetFileSystemRepresentation(main.value, true, bytes.data(), bytes.size())) return std::nullopt;
    return std::string(reinterpret_cast<const char*>(bytes.data()));
  }

  // The native observation comes from the original held CLI socket, never a
  // deserialized PID. Cleanup never calls this constructor after CLI loss.
  static std::shared_ptr<const issuer_lineage> capture_original(const capture& original) {
    namespace native = ergoptiplus::installed_capture::detail;
    namespace publisher = ergoptiplus::installed_publisher;
    if (!ergoptiplus::installed_capture::remote_installed_peer_matches(original)) return nullptr;
    proc_bsdinfo cli{}, headless{}, hs{}, final_cli{}, final_headless{}, final_hs{};
    if (!native::process(original.pid, cli) ||
        !native::process(static_cast<pid_t>(cli.pbi_ppid), headless) ||
        !native::process(static_cast<pid_t>(headless.pbi_ppid), hs) ||
        cli.pbi_uid != original.euid || headless.pbi_uid != original.euid || hs.pbi_uid != original.euid ||
        cli.pbi_start_tvsec == 0 || headless.pbi_start_tvsec == 0 || hs.pbi_start_tvsec == 0 ||
        !native::headless_parent(static_cast<pid_t>(headless.pbi_pid))) return nullptr;
    const auto cli_path = executable(original.pid);
    const auto headless_path = executable(static_cast<pid_t>(headless.pbi_pid));
    const auto hs_path = executable(static_cast<pid_t>(hs.pbi_pid));
    if (!cli_path || !headless_path || !hs_path) return nullptr;
    const auto main = std::filesystem::path(*headless_path);
    if (main.parent_path().filename() != "MacOS" || main.parent_path().parent_path().filename() != "Contents") return nullptr;
    const auto app = main.parent_path().parent_path().parent_path().string();
    const auto normal_main = bundle_executable(app, "com.ergoptiplus.app");
    const auto embedded = app + "/Contents/Frameworks/Hammerspoon.app";
    const auto embedded_main = bundle_executable(embedded, "com.ergoptiplus.app.hammerspoon");
    const auto module = app + "/Contents/Resources/static/ergopti_plus/macos/adapters/native/installed_physical_source.so";
    if (!normal_main || *normal_main != *headless_path || !embedded_main || *embedded_main != *hs_path) return nullptr;
    // The unchanged original peer predicate owns the closed CLI route.
    // Join its actual native executable; do not invent a second bundle route.
    const auto cli_leaf = native::live_leaf(original.pid, "com.ergoptiplus.remap.cli", cli_path->c_str());
    const auto headless_leaf = native::live_leaf(static_cast<pid_t>(headless.pbi_pid), "com.ergoptiplus.app", headless_path->c_str());
    const auto hs_leaf = native::live_leaf(static_cast<pid_t>(hs.pbi_pid), "com.ergoptiplus.app.hammerspoon", hs_path->c_str());
    const auto module_leaf = publisher::detail::path_leaf(module.c_str(), publisher::role::module);
    if (!cli_leaf || !headless_leaf || !hs_leaf || !module_leaf || *cli_leaf != *headless_leaf ||
        *cli_leaf != *hs_leaf || *cli_leaf != *module_leaf ||
        !native::process(original.pid, final_cli) || !native::same_birth(cli, final_cli) ||
        !native::process(static_cast<pid_t>(headless.pbi_pid), final_headless) || !native::same_birth(headless, final_headless) ||
        !native::process(static_cast<pid_t>(hs.pbi_pid), final_hs) || !native::same_birth(hs, final_hs) ||
        final_cli.pbi_ppid != headless.pbi_pid || final_headless.pbi_ppid != hs.pbi_pid ||
        executable(original.pid) != cli_path ||
        executable(static_cast<pid_t>(headless.pbi_pid)) != headless_path ||
        executable(static_cast<pid_t>(hs.pbi_pid)) != hs_path ||
        !ergoptiplus::installed_capture::remote_installed_peer_matches(original)) return nullptr;
    auto result = std::shared_ptr<issuer_lineage>(new issuer_lineage);
    result->hs_ = detail::native_birth{static_cast<pid_t>(hs.pbi_pid), hs.pbi_start_tvsec, hs.pbi_start_tvusec};
    result->uid_ = original.euid;
    result->gid_ = hs.pbi_gid;
    result->hs_path_ = *hs_path;
    result->leaf_ = *hs_leaf;
    return result;
  }

  // These original identities survive CLI exit, but an issuer must still be
  // the exact live Hammerspoon kernel/socket actor before each operation.
  bool matches(const detail::native_peer_observation& observed) const {
    namespace native = ergoptiplus::installed_capture::detail;
    if (observed.pid != hs_.pid || observed.euid != uid_ || observed.egid != gid_ ||
        observed.peer.identifier != "com.ergoptiplus.app.hammerspoon" || observed.peer.leaf != leaf_) return false;
    const auto before = detail::native_birth::observe(hs_.pid);
    const auto leaf = native::live_leaf(hs_.pid, "com.ergoptiplus.app.hammerspoon", hs_path_.c_str());
    const auto after = detail::native_birth::observe(hs_.pid);
    return before && after && *before == hs_ && *after == hs_ && leaf && *leaf == leaf_ &&
        executable(hs_.pid) == std::optional<std::string>(hs_path_);
  }
  detail::native_birth hs_;
  uid_t uid_ = static_cast<uid_t>(-1);
  gid_t gid_ = static_cast<gid_t>(-1);
  std::string hs_path_;
  std::vector<std::uint8_t> leaf_;
};
} // namespace ergoptiplus::installed_maintenance
