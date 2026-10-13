// Private prepared-generation Core maintenance owner; wire fields are not authority.
#pragma once
#include "OwnedRuntimeMaintenanceLineage.hpp"
#include "OwnedRuntimeMaintenanceFraming.hpp"
#include "OwnedRuntimeMaintenanceNativeSocket.hpp"
#include "InstalledRuntimeMaintenancePeer.hpp"
#include "InstalledRuntimeMaintenanceAdmission.hpp"
#include "InstalledRuntimeConfirmedUpdatePeer.hpp"
#include "core_service/daemon/device_grabber.hpp"
#include <uuid/uuid.h>
#include <sys/event.h>
#include <vector>

namespace krbn::core_service::daemon { class receiver; }
namespace ergoptiplus::installed_maintenance {
#if defined(ERGOPTIPLUS_OWNED_RUNTIME_TEST_ONLY)
class native_observer_test;
#endif
class core_endpoint final : public std::enable_shared_from_this<core_endpoint> {
  friend class ::krbn::core_service::daemon::receiver;
  friend class ::hs274_stream_protocol::runtime;
#if defined(ERGOPTIPLUS_OWNED_RUNTIME_TEST_ONLY)
  friend class native_observer_test;
#endif
  using runtime=::hs274_stream_protocol::runtime;
  using json=::hs274_stream_protocol::json;
  using participant=runtime::capture_participant;
  using cohort=::krbn::core_service::daemon::device_grabber::active_cohort;
  // Historical closure is minted only after consuming this genuine opaque
  // Core receipt while its original epoch is still current. It supplies no
  // Parent settlement and cannot be constructed from a wire field or Bool.
  class closed_preparation final {
    friend class core_endpoint;
    const cohort::terminal_receipt native_;
    explicit closed_preparation(cohort::terminal_receipt native):native_(std::move(native)) {}
  };
  struct issuer_exit final {
    const std::shared_ptr<const issuer_lineage> lineage;
    const detail::native_birth birth;
    int monitor=-1;
    bool armed=false,observed=false,permit_sent=false,failed=false,close_attempted=false,close_refused=false;
    explicit issuer_exit(std::shared_ptr<const issuer_lineage> original)
      :lineage(std::move(original)),birth(lineage->hs_) {}
#if defined(ERGOPTIPLUS_OWNED_RUNTIME_TEST_ONLY)
    // Mechanics-only fixture, never a captured installed actor or a record.
    explicit issuer_exit(detail::native_birth original):lineage(nullptr),birth(original) {}
#endif
  };
  class closed_issuer_endpoint final {
    friend class core_endpoint;
    const std::shared_ptr<const native_socket> issuer_;
    const std::shared_ptr<const issuer_lineage> lineage_;
    const wire_frame::nonce_type nonce_;
    explicit closed_issuer_endpoint(std::shared_ptr<const native_socket> issuer,
      std::shared_ptr<const issuer_lineage> lineage,wire_frame::nonce_type nonce)
      :issuer_(std::move(issuer)),lineage_(std::move(lineage)),nonce_(nonce) {}
  };
  // A distinct kernel closure: live-HS EOF never mints this receipt.
  class closed_parent final {
    friend class core_endpoint;
    const std::shared_ptr<const closed_issuer_endpoint> endpoint_;
    const std::shared_ptr<const issuer_exit> kernel_;
    explicit closed_parent(std::shared_ptr<const closed_issuer_endpoint> endpoint,
      std::shared_ptr<const issuer_exit> kernel):endpoint_(std::move(endpoint)),kernel_(std::move(kernel)) {}
  };
  // Historical resource closure admits a fresh actor only. It is not an
  // image-maintenance grant for the ordinary quit tuple.
  class closed_for_enrollment final {
    friend class core_endpoint;
    const std::shared_ptr<const closed_preparation> core_;
    const std::shared_ptr<const closed_issuer_endpoint> endpoint_;
    const std::shared_ptr<const issuer_exit> kernel_;
    explicit closed_for_enrollment(std::shared_ptr<const closed_preparation> core,
      std::shared_ptr<const closed_issuer_endpoint> endpoint,std::shared_ptr<const issuer_exit> kernel)
      :core_(std::move(core)),endpoint_(std::move(endpoint)),kernel_(std::move(kernel)) {}
  };
  class image_request final {
    friend class core_endpoint;
    const std::shared_ptr<native_socket> socket_;
    const std::shared_ptr<staged_admission> staged_;
    const std::shared_ptr<confirmed_update_admission> update_;
    const wire_frame original_;
    image_request(std::shared_ptr<native_socket> socket,std::shared_ptr<staged_admission> staged,
      std::shared_ptr<confirmed_update_admission> update,wire_frame original)
      :socket_(std::move(socket)),staged_(std::move(staged)),update_(std::move(update)),original_(original) {}
  };
  struct record final {
    const std::shared_ptr<participant> capture;
    const std::shared_ptr<cohort> aggregate;
    const std::shared_ptr<const issuer_lineage> lineage;
    const wire_frame::incarnation_type incarnation;
    const std::uint64_t preparation,epoch;
    std::shared_ptr<const closed_preparation> core_closed;
    std::optional<wire_frame::nonce_type> nonce;
    std::shared_ptr<native_socket> issuer;
    std::shared_ptr<const closed_parent> parent_closed;
    std::shared_ptr<const closed_issuer_endpoint> endpoint_closed;
    std::shared_ptr<issuer_exit> exit;
    std::shared_ptr<const image_request> maintenance;
    std::shared_ptr<const closed_for_enrollment> enrollment_closed;
    bool settlement_acknowledged=false; // Provisional, never full terminal.
    record(std::shared_ptr<participant> value,std::shared_ptr<cohort> original,
           std::shared_ptr<const issuer_lineage> actor,wire_frame::incarnation_type uuid,
           std::uint64_t prepared,std::uint64_t generation)
      :capture(std::move(value)),aggregate(std::move(original)),lineage(std::move(actor)),
       incarnation(uuid),preparation(prepared),epoch(generation) {}
  };
  struct stream final {
    std::shared_ptr<native_socket> socket;
    wire_frame::bytes_type input{},output{};
    std::size_t read=0,written=0;
    bool responding=false,close_after=false,issuer_eof=false;
    std::shared_ptr<record> acquired;
    std::shared_ptr<staged_admission> staged;
    std::shared_ptr<confirmed_update_admission> update;
    std::shared_ptr<issuer_exit> permission_response;
    std::shared_ptr<record> intent_response; // Scheduling observation only.
    std::chrono::steady_clock::time_point deadline{};
  };
  core_endpoint(::krbn::core_service::daemon::receiver& receiver,uid_t uid);
  static std::shared_ptr<core_endpoint> acquire(::krbn::core_service::daemon::receiver& receiver,
                                               std::optional<uid_t> uid) noexcept;
  bool bind_fixed();
  bool named_current() const;
  bool arm();
  void tick() noexcept;
  bool enroll(runtime& owner,const std::shared_ptr<participant>& capture,const json& prepared);
  bool capture_terminals();
  bool capture_terminal(const std::shared_ptr<record>& original);
  wire_frame process(stream& client,const wire_frame& request);
  bool issuer_current(const record& original,const detail::native_peer_observation& observed) const;
  static bool same_binding(const issuer_lineage& first,const issuer_lineage& second);
  bool full_terminal(const std::shared_ptr<record>& original) const;
  bool latest(const std::shared_ptr<record>& original) const;
  void accept_one();
  bool advance(stream& client);
  bool close_stream(stream& client);
  bool release_admission(stream& client);
  bool arm_issuer_exit(record& original,const std::shared_ptr<native_socket>& socket);
  static bool arm_issuer_monitor(issuer_exit& original);
  static bool poll_issuer_exit(issuer_exit& original);
  static bool close_issuer_exit(issuer_exit& original);
  bool issuer_retirement_intent(const std::shared_ptr<record>& original) const;
  bool issuer_permission(const std::shared_ptr<record>& original) const;
  bool capture_parent_terminals();
  bool stop() noexcept;
  static std::optional<std::uint64_t> decimal(const json& value);
  static std::optional<wire_frame::incarnation_type> incarnation(const json& value);
  ::krbn::core_service::daemon::receiver* const receiver_;
  const uid_t uid_;
  std::shared_ptr<native_socket> anchor_;
  int listener_=-1;
  struct stat listener_identity_{},named_identity_{};
  bool bound_=false,stopping_=false,close_attempted_=false,close_refused_=false,failed_=false;
  std::vector<std::shared_ptr<record>> records_;
  std::vector<std::shared_ptr<issuer_exit>> exits_;
  std::array<stream,8> streams_{};
  std::shared_ptr<core_endpoint> custody_;
};
} // namespace ergoptiplus::installed_maintenance
