# tools/build/remap_runtime_auth_transport_test.py
"""Fixed vendor source composition tests over the owner's actual pinned input.

Run with --source-root pointing to the pristine source already acquired by the
baseline/factory owner. These controls grant no native/signing/runtime authority.
"""

import argparse
import hashlib
import importlib.util
import math
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

EXPECTED_PREIMAGES = {
    "vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp": "bfe02a077e4804c99b8fabb5364da1cce9faadb1613b571ff8a81375f40f475a",
    "vendor/vendor/include/pqrs/unix_domain_stream/client.hpp": "d6120091e024aa29228fb83378ba94cbbf2778218d8d429a9311ea4150080a4d",
    "vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp": "84d5c5606e5eb87e0da0d9e427ddc4720bb79b53e5f5bd8b35b04409770eb4ba",
    "vendor/vendor/include/pqrs/unix_domain_stream/server.hpp": "048b635d6e3563ebf643ec77acd1eadd90b0005b824b24e74768a71b19e6f568",
    "vendor/vendor/include/pqrs/unix_domain_stream/types.hpp": "061ec3512ec605f4d7d2ecf5113d1e47ba6ef3109754f3a2276842b5be679242",
    "src/apps/CoreService/include/core_service/daemon/receiver.hpp": "575c7122a9a2448b81637bbfb50925cd3ff07f0613fcc09abbf1143d19de766d",
    "src/apps/ConsoleUserServer/include/console_user_server/receiver.hpp": "07f57a8a1073551344cb555bf342e1b51fc861d6cce7e9f26b87eba01597f28a",
    "src/share/core_service_daemon_client.hpp": "a56443dd59876bfc05be9b221db1313abd0682d64acd4b1d523910f3da551f33",
    "src/share/console_user_server_client.hpp": "13ce02c4f966bf647b62b020834326a903064b25469d52a8e9a9ef79472cefc6",
    "src/apps/CoreService/include/core_service/daemon/console_user_id_changed_receiver.hpp": "9bdd743310a881c948fc0f57e1d1b55e68654b55f64f7a2e085586520529a75e",
    "src/apps/ConsoleUserServer/include/console_user_server/console_user_id_changed_client.hpp": "e58eac3f9f8a39c6e56ef22c8ac5f83c066bdfb96e6325d2ba71586b90ee4b74",
}
SOURCE_ROOT = None


NATIVE_LEAF_PREFIX = '// Portable private projection: native Security/token/watch/serial-main leaves\n// are explicitly modeled. Actual private authority/close/source bodies follow.\n#pragma once\n#include "remap_runtime_auth_policy.hpp"\n#include <asio.hpp>\n#include <atomic>\n#include <cstdint>\n#include <cstring>\n#include <limits>\n#include <memory>\n#include <mutex>\n#include <optional>\n#include <string>\n#include <vector>\n#include <functional>\n#include <utility>\n#include <algorithm>\n#include <exception>\n#include <fcntl.h>\n#include <unistd.h>\n#include <iostream>\n#include <deque>\nusing SecCodeRef = void*;\ninline constexpr int kSecCSDefaultFlags = 0;\ninline constexpr int errSecSuccess = 0;\ninline std::atomic<unsigned> fixture_self_identity_reads{0};\ninline int SecCodeCopySelf(int, SecCodeRef* result) { ++fixture_self_identity_reads; *result = reinterpret_cast<void*>(1); return 0; }\ninline void CFRelease(void*) {}\nstruct audit_token_t { std::uint32_t val[8]{}; };\nnamespace fixture {\ninline std::atomic<unsigned> samples{0};\ninline std::atomic<unsigned> self_uid{0};\ninline std::atomic<unsigned> token_generation{1};\ninline std::atomic<bool> native_known{true};\ninline std::atomic<bool> watch_current{true};\ninline ergoptiplus::remap::identity::role self_role=ergoptiplus::remap::identity::role::core;\ninline ergoptiplus::remap::identity::role peer_role=ergoptiplus::remap::identity::role::cli;\ninline unsigned peer_uid=501;\ninline std::mutex main_mutex;\ninline std::deque<std::function<void()>> main_tasks;\ninline void run_main() {\n for (;;) { std::function<void()> task; {std::lock_guard<std::mutex> lock(main_mutex);if(main_tasks.empty())return;task=std::move(main_tasks.front());main_tasks.pop_front();}task(); }\n}\ninline uid_t geteuid() { return self_uid.load(); }\n}\ninline void* dispatch_get_main_queue() {return nullptr;}\ninline void dispatch_async_f(void*,void* arg,void(*function)(void*)) {\n std::lock_guard<std::mutex> lock(fixture::main_mutex);\n fixture::main_tasks.push_back([arg,function]{function(arg);});\n}\nnamespace ergoptiplus::remap {\nclass owned_console_parent_watch final {\npublic: bool current() { return fixture::watch_current.load(); }\n};\n}\n'
NATIVE_LEAF_MODEL = '\ntemplate<typename T> class cf_owned final {\npublic: cf_owned()=default; ~cf_owned(){if(value_)CFRelease(value_);} T get()const{return value_;} T* out(){return &value_;}\nprivate:T value_=nullptr;\n};\nstruct code_identity final { identity::role role=identity::role::unavailable; std::string team; std::vector<std::uint8_t> leaf; };\ninline std::optional<code_identity> signing_identity(SecCodeRef) {\n if(!fixture::native_known.load())return std::nullopt;\n return code_identity{fixture::self_role,"MODELED_ONLY",{4,5}};\n}\nstruct peer_observation final {\n audit_token_t token{};pid_t pid=-1;uid_t euid=-1;gid_t egid=-1;\n code_identity self;code_identity peer;uid_t self_euid=-1;gid_t self_egid=-1;\n};\nclass native_sampler final {\n friend class ::ergoptiplus::remap::auth::socket_lifetime;\nprivate:\n static std::optional<peer_observation> sample(int descriptor,const std::optional<audit_token_t>& initial) {\n  ++fixture::samples;\n  if(!fixture::native_known.load() || ::fcntl(descriptor,F_GETFD)<0)return std::nullopt;\n  peer_observation result;\n  result.token.val[0]=fixture::token_generation.load();\n  if(initial && std::memcmp(&*initial,&result.token,sizeof(result.token))!=0)return std::nullopt;\n  result.pid=111; result.euid=fixture::peer_uid;result.egid=20;\n  result.self_euid=fixture::geteuid();result.self_egid=0;\n  result.self={fixture::self_role,"MODELED_ONLY",{4,5}};\n  result.peer={fixture::peer_role,"MODELED_ONLY",{4,5}};\n  return result;\n }\n};\n'
CPP_CONTROLS = {
    "held_request": '// Exact actual peer/control pipeline; only native authentication leaves are\n// modeled in the explicitly projected header. Private fixture visibility is\n// disclosed and is never emitted into production candidate sources.\n#include <pqrs/unix_domain_stream/impl/peer.hpp>\n#include <pqrs/dispatcher/time_source.hpp>\n#include <nlohmann/json.hpp>\n#include <sys/socket.h>\n#include <condition_variable>\n#include <chrono>\n#include <thread>\n#include <iostream>\n#include <fcntl.h>\n#include <unistd.h>\nint main() {\n using namespace std::chrono_literals;\n namespace auth=ergoptiplus::remap::auth;\n int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 10;\n asio::io_context io;auto work=asio::make_work_guard(io);\n auto time=std::make_shared<pqrs::dispatcher::hardware_time_source>();\n auto dispatcher=std::make_shared<pqrs::dispatcher::dispatcher>(time);\n asio::local::stream_protocol::socket socket(io);socket.assign(asio::local::stream_protocol(),pair[0]);\n auto channel=auth::channel_owner::daemon_server(501);\n auto lifetime=auth::socket_lifetime::bind(channel,socket.native_handle());\n if(!lifetime)return 11;\n auto peer=std::make_shared<pqrs::unix_domain_stream::impl::peer>(dispatcher,std::move(socket),pqrs::unix_domain_stream::common_options{},std::optional{lifetime});\n std::mutex mutex;std::condition_variable changed;\n bool entered=false,released=false,exited=false,allowed=false,second_handoff=true;\n std::atomic<unsigned> raw=0,closed=0;\n std::shared_ptr<auth::delivery_ticket> successor;\n peer->owned_ready_=[](auth::frame_scope&) {};\n peer->owned_request_received_=[&](auth::frame_scope& scope) {\n  auto permit=scope.permit("set_variables");\n  auto next=scope.handoff();auto repeated=scope.handoff();\n  std::unique_lock<std::mutex> lock(mutex);\n  allowed=permit && scope.view().peer_uid()==501 && scope.view().request_id()==7;\n  successor=next;second_handoff=bool(repeated);entered=true;changed.notify_all();\n  changed.wait(lock,[&]{return released;});exited=true;changed.notify_all();\n };\n peer->request_received.connect([&](auto,auto){++raw;});\n std::thread worker([&]{io.run();});peer->async_start();\n const auto payload=nlohmann::json::to_msgpack(nlohmann::json{{"operation_type","set_variables"}});\n const auto wire=pqrs::unix_domain_stream::impl::protocol::make_request_frame(7,payload);\n bool wrote=::write(pair[1],wire.data(),wire.size())==static_cast<ssize_t>(wire.size());\n bool observed=false;\n {std::unique_lock<std::mutex> lock(mutex);observed=changed.wait_for(lock,2s,[&]{return entered;});}\n peer->async_close([&]{++closed;changed.notify_all();});\n bool after_stop_effect=false;\n if(successor) after_stop_effect=successor->consume([](auth::frame_scope&){});\n successor.reset();\n std::this_thread::sleep_for(50ms);\n bool held_debt=::fcntl(pair[0],F_GETFD)>=0 && closed==0;\n {std::lock_guard<std::mutex> lock(mutex);released=true;changed.notify_all();}\n {std::unique_lock<std::mutex> lock(mutex);changed.wait_for(lock,2s,[&]{return exited && closed==1;});}\n std::this_thread::sleep_for(20ms);\n bool actual_closed=::fcntl(pair[0],F_GETFD)<0 && errno==EBADF;\n bool result=wrote && observed && allowed && !second_handoff && raw==0 &&\n             held_debt && !after_stop_effect && exited && closed==1 && actual_closed;\n channel->revoke();channel->schedule_closures();\n ::close(pair[1]);work.reset();worker.join();peer.reset();lifetime.reset();\n dispatcher->terminate();dispatcher.reset();\n std::cout<<"{\\"wrote\\":"<<wrote<<",\\"entered\\":"<<observed<<",\\"allowed\\":"<<allowed\n  <<",\\"raw\\":"<<raw<<",\\"held_debt\\":"<<held_debt<<",\\"after_stop_effect\\":"<<after_stop_effect\n  <<",\\"actual_closed\\":"<<actual_closed<<",\\"close_callbacks\\":"<<closed\n  <<",\\"native_darwin_auth_executed\\":0}\\n";\n return result?0:1;\n}\n',
    "held_response": '// Real pinned peer, request_manager, Asio dispatcher and socketpair; only\n// Security/audit token/watch leaves are modeled in the disclosed projection.\n#include <pqrs/unix_domain_stream/impl/peer.hpp>\n#include <pqrs/unix_domain_stream/impl/request_manager.hpp>\n#include <pqrs/dispatcher/time_source.hpp>\n#include <nlohmann/json.hpp>\n#include <sys/socket.h>\n#include <condition_variable>\n#include <future>\n#include <chrono>\n#include <thread>\n#include <iostream>\n#include <fcntl.h>\n#include <unistd.h>\nclass callback_owner final : public pqrs::dispatcher::extra::dispatcher_client {\npublic:\n explicit callback_owner(std::weak_ptr<pqrs::dispatcher::dispatcher> dispatcher):dispatcher_client(dispatcher){}\n ~callback_owner(){detach_from_dispatcher();}\n};\nint main() {\n using namespace std::chrono_literals;\n namespace auth=ergoptiplus::remap::auth;\n fixture::self_uid=501; fixture::self_role=ergoptiplus::remap::identity::role::cli;\n fixture::peer_uid=0; fixture::peer_role=ergoptiplus::remap::identity::role::core;\n int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 10;\n asio::io_context io;auto work=asio::make_work_guard(io);\n auto time=std::make_shared<pqrs::dispatcher::hardware_time_source>();\n auto dispatcher=std::make_shared<pqrs::dispatcher::dispatcher>(time);\n auto callback=std::make_unique<callback_owner>(dispatcher);\n auto channel=auth::channel_owner::daemon_client();\n asio::local::stream_protocol::socket socket(io);socket.assign(asio::local::stream_protocol(),pair[0]);\n auto lifetime=auth::socket_lifetime::bind(channel,socket.native_handle());\n if(!lifetime)return 11;\n auto peer=std::make_shared<pqrs::unix_domain_stream::impl::peer>(dispatcher,std::move(socket),pqrs::unix_domain_stream::common_options{},std::optional{lifetime});\n pqrs::unix_domain_stream::impl::request_manager manager(io,*callback,channel);\n std::mutex mutex;std::condition_variable changed;\n bool entered=false,released=false,exited=false,allowed=false;\n std::atomic<unsigned> calls=0,raw=0,closed=0;\n std::shared_ptr<auth::delivery_ticket> successor;\n std::promise<pqrs::unix_domain_stream::request_id> pending;\n asio::post(io,[&]{ pending.set_value(manager.add(std::nullopt,5s,nullptr,nullptr,\n   [&](const std::error_code& error,auth::frame_scope* scope){\n     ++calls;\n     const bool permit=!error && scope && scope->permit("none") && scope->view().kind()==auth::frame_kind::response && scope->view().request_id()==1;\n     auto next=scope ? scope->handoff() : nullptr;\n     std::unique_lock lock(mutex);allowed=permit;successor=next;entered=true;changed.notify_all();\n     changed.wait(lock,[&]{return released;});exited=true;changed.notify_all();\n   })); });\n peer->owned_ready_=[](auth::frame_scope&){};\n peer->owned_response_received_=[&](auth::frame_scope& scope){\n   auto ticket=scope.handoff();auto id=scope.view().request_id();\n   asio::post(io,[&,ticket,id]{manager.complete_owned(id,ticket);});\n };\n peer->response_received.connect([&](auto,auto){++raw;});\n std::thread worker([&]{io.run();});auto id=pending.get_future().get();peer->async_start();\n const auto payload=nlohmann::json::to_msgpack(nlohmann::json{{"operation_type","none"}});\n const auto wire=pqrs::unix_domain_stream::impl::protocol::make_response_frame(id,payload);\n const bool wrote=::write(pair[1],wire.data(),wire.size())==static_cast<ssize_t>(wire.size());\n bool observed=false;{std::unique_lock lock(mutex);observed=changed.wait_for(lock,2s,[&]{return entered;});}\n peer->async_close([&]{++closed;changed.notify_all();});\n const bool after_stop=successor && successor->consume([](auth::frame_scope&){}); successor.reset();\n std::this_thread::sleep_for(30ms);const bool debt=::fcntl(pair[0],F_GETFD)>=0 && closed==0;\n {std::lock_guard lock(mutex);released=true;changed.notify_all();}\n {std::unique_lock lock(mutex);changed.wait_for(lock,2s,[&]{return exited && closed==1;});}\n std::this_thread::sleep_for(20ms);const bool actual_closed=::fcntl(pair[0],F_GETFD)<0 && errno==EBADF;\n const bool ok=wrote && observed && allowed && id==1 && calls==1 && raw==0 && debt && !after_stop && exited && closed==1 && actual_closed;\n channel->revoke();channel->schedule_closures();::close(pair[1]);work.reset();worker.join();\n peer.reset();lifetime.reset();callback.reset();dispatcher->terminate();dispatcher.reset();\n std::cout<<"{\\"allowed\\":"<<allowed<<",\\"raw\\":"<<raw<<",\\"held_debt\\":"<<debt<<",\\"after_stop\\":"<<after_stop<<",\\"actual_closed\\":"<<actual_closed<<",\\"calls\\":"<<calls<<",\\"close_callbacks\\":"<<closed<<",\\"native_darwin_auth_executed\\":0}\\n";\n return ok?0:1;\n}\n',
    "session_empty_ack": '// Real pinned peer, request_manager, Asio dispatcher and socketpair; only\n// Security/audit token/watch leaves are modeled in the disclosed projection.\n#include <pqrs/unix_domain_stream/impl/peer.hpp>\n#include <pqrs/unix_domain_stream/impl/request_manager.hpp>\n#include <pqrs/dispatcher/time_source.hpp>\n#include <nlohmann/json.hpp>\n#include <sys/socket.h>\n#include <condition_variable>\n#include <future>\n#include <chrono>\n#include <thread>\n#include <iostream>\n#include <fcntl.h>\n#include <unistd.h>\nclass callback_owner final : public pqrs::dispatcher::extra::dispatcher_client {\npublic:\n explicit callback_owner(std::weak_ptr<pqrs::dispatcher::dispatcher> dispatcher):dispatcher_client(dispatcher){}\n ~callback_owner(){detach_from_dispatcher();}\n};\nint main() {\n using namespace std::chrono_literals;\n namespace auth=ergoptiplus::remap::auth;\n fixture::self_uid=501; fixture::self_role=ergoptiplus::remap::identity::role::console;\n fixture::peer_uid=0; fixture::peer_role=ergoptiplus::remap::identity::role::core;\n int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 10;\n asio::io_context io;auto work=asio::make_work_guard(io);\n auto time=std::make_shared<pqrs::dispatcher::hardware_time_source>();\n auto dispatcher=std::make_shared<pqrs::dispatcher::dispatcher>(time);\n auto callback=std::make_unique<callback_owner>(dispatcher);\n auto entry=auth::detail::console_registry::prepare(std::make_shared<ergoptiplus::remap::owned_console_parent_watch>(),9);\n if(!entry || !auth::detail::console_registry::publish(entry))return 12;\n auto channel=auth::channel_owner::session_client();\n asio::local::stream_protocol::socket socket(io);socket.assign(asio::local::stream_protocol(),pair[0]);\n auto lifetime=auth::socket_lifetime::bind(channel,socket.native_handle());\n if(!lifetime)return 11;\n auto peer=std::make_shared<pqrs::unix_domain_stream::impl::peer>(dispatcher,std::move(socket),pqrs::unix_domain_stream::common_options{},std::optional{lifetime});\n pqrs::unix_domain_stream::impl::request_manager manager(io,*callback,channel);\n std::mutex mutex;std::condition_variable changed;\n bool entered=false,released=false,exited=false,allowed=false;\n std::atomic<unsigned> calls=0,raw=0,closed=0;\n std::shared_ptr<auth::delivery_ticket> successor;\n std::promise<pqrs::unix_domain_stream::request_id> pending;\n asio::post(io,[&]{ pending.set_value(manager.add(std::nullopt,5s,nullptr,nullptr,\n   [&](const std::error_code& error,auth::frame_scope* scope){\n     ++calls;\n     const bool permit=!error && scope && scope->view().kind()==auth::frame_kind::response && scope->view().request_id()==1;\n     auto next=scope ? scope->handoff() : nullptr;\n     std::unique_lock lock(mutex);allowed=permit;successor=next;entered=true;changed.notify_all();\n     changed.wait(lock,[&]{return released;});exited=true;changed.notify_all();\n   }, "console_user_id_changed")); });\n peer->owned_ready_=[](auth::frame_scope&){};\n peer->owned_response_received_=[&](auth::frame_scope& scope){\n   auto ticket=scope.handoff();auto id=scope.view().request_id();\n   asio::post(io,[&,ticket,id]{manager.complete_owned(id,ticket);});\n };\n peer->response_received.connect([&](auto,auto){++raw;});\n std::thread worker([&]{io.run();});auto id=pending.get_future().get();peer->async_start();\n const std::vector<uint8_t> payload{};\n const auto wire=pqrs::unix_domain_stream::impl::protocol::make_response_frame(id,payload);\n const bool wrote=::write(pair[1],wire.data(),wire.size())==static_cast<ssize_t>(wire.size());\n bool observed=false;{std::unique_lock lock(mutex);observed=changed.wait_for(lock,2s,[&]{return entered;});}\n peer->async_close([&]{++closed;changed.notify_all();});\n const bool after_stop=successor && successor->consume([](auth::frame_scope&){}); successor.reset();\n std::this_thread::sleep_for(30ms);const bool debt=::fcntl(pair[0],F_GETFD)>=0 && closed==0;\n {std::lock_guard lock(mutex);released=true;changed.notify_all();}\n {std::unique_lock lock(mutex);changed.wait_for(lock,2s,[&]{return exited && closed==1;});}\n std::this_thread::sleep_for(20ms);const bool actual_closed=::fcntl(pair[0],F_GETFD)<0 && errno==EBADF;\n const bool ok=wrote && observed && allowed && id==1 && calls==1 && raw==0 && debt && !after_stop && exited && closed==1 && actual_closed;\n channel->revoke();channel->schedule_closures();\n auth::detail::console_registry::revoke(entry);auth::detail::console_registry::schedule_closures(entry);\n ::close(pair[1]);work.reset();worker.join();\n peer.reset();lifetime.reset();callback.reset();dispatcher->terminate();dispatcher.reset();\n std::cout<<"{\\"allowed\\":"<<allowed<<",\\"raw\\":"<<raw<<",\\"held_debt\\":"<<debt<<",\\"after_stop\\":"<<after_stop<<",\\"actual_closed\\":"<<actual_closed<<",\\"calls\\":"<<calls<<",\\"close_callbacks\\":"<<closed<<",\\"native_darwin_auth_executed\\":0}\\n";\n return ok?0:1;\n}\n',
}

CPP_CONTROLS["pending_negatives"] = (
    '// Real pinned peer, request_manager, Asio dispatcher and socketpair; only\n// Security/audit token/watch leaves are modeled in the disclosed projection.\n#include <pqrs/unix_domain_stream/impl/peer.hpp>\n#include <pqrs/unix_domain_stream/impl/request_manager.hpp>\n#include <pqrs/dispatcher/time_source.hpp>\n#include <nlohmann/json.hpp>\n#include <sys/socket.h>\n#include <condition_variable>\n#include <future>\n#include <chrono>\n#include <thread>\n#include <iostream>\n#include <fcntl.h>\n#include <unistd.h>\nclass callback_owner final : public pqrs::dispatcher::extra::dispatcher_client {\npublic:\n explicit callback_owner(std::weak_ptr<pqrs::dispatcher::dispatcher> dispatcher):dispatcher_client(dispatcher){}\n ~callback_owner(){detach_from_dispatcher();}\n};\nint exercise(unsigned scenario) {\n using namespace std::chrono_literals;\n namespace auth=ergoptiplus::remap::auth;\n fixture::self_uid=501; fixture::self_role=ergoptiplus::remap::identity::role::console;\n fixture::peer_uid=0; fixture::peer_role=ergoptiplus::remap::identity::role::core;\n int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 10;\n asio::io_context io;auto work=asio::make_work_guard(io);\n auto time=std::make_shared<pqrs::dispatcher::hardware_time_source>();\n auto dispatcher=std::make_shared<pqrs::dispatcher::dispatcher>(time);\n auto callback=std::make_unique<callback_owner>(dispatcher);\n auto entry=auth::detail::console_registry::prepare(std::make_shared<ergoptiplus::remap::owned_console_parent_watch>(),9+scenario);\n if(!entry || !auth::detail::console_registry::publish(entry))return 12;\n auto channel=auth::channel_owner::session_client();\n asio::local::stream_protocol::socket socket(io);socket.assign(asio::local::stream_protocol(),pair[0]);\n auto lifetime=auth::socket_lifetime::bind(channel,socket.native_handle());\n if(!lifetime)return 11;\n auto peer=std::make_shared<pqrs::unix_domain_stream::impl::peer>(dispatcher,std::move(socket),pqrs::unix_domain_stream::common_options{},std::optional{lifetime});\n pqrs::unix_domain_stream::impl::request_manager manager(io,*callback,channel);\n std::atomic<unsigned> successes=0,errors=0,raw=0,closed=0,delivered=0;\n std::promise<pqrs::unix_domain_stream::request_id> pending;\n asio::post(io,[&]{\n   auto id=manager.add(std::nullopt,5s,nullptr,nullptr,\n     [&](const std::error_code& error,auth::frame_scope* scope){\n       if(!error || scope)++successes;\n       if(error==asio::error::operation_aborted && !scope)++errors;\n     }, scenario==0 ? "wrong_operation" : "console_user_id_changed");\n   if(scenario==1)manager.complete_all(asio::error::operation_aborted);\n   pending.set_value(id);\n });\n peer->owned_ready_=[](auth::frame_scope&){};\n peer->owned_response_received_=[&](auth::frame_scope& scope){\n   auto ticket=scope.handoff();auto id=scope.view().request_id();\n   asio::post(io,[&,ticket,id]{manager.complete_owned(id,ticket);\n     callback->enqueue_to_dispatcher([&]{++delivered;});});\n };\n peer->response_received.connect([&](auto,auto){++raw;});\n std::thread worker([&]{io.run();});auto id=pending.get_future().get();peer->async_start();\n const auto wire=pqrs::unix_domain_stream::impl::protocol::make_response_frame(scenario==2 ? id+1 : id,{});\n const bool wrote=::write(pair[1],wire.data(),wire.size())==static_cast<ssize_t>(wire.size());\n for(unsigned i=0;i<200 && delivered==0;++i)std::this_thread::sleep_for(5ms);\n const bool no_success=wrote && id==1 && delivered==1 && successes==0 && raw==0 && errors==(scenario==1 ? 1u : 0u);\n std::promise<void> cleaned;\n asio::post(io,[&]{manager.complete_all(asio::error::operation_aborted);callback->enqueue_to_dispatcher([&]{cleaned.set_value();});});\n cleaned.get_future().get();\n peer->async_close([&]{++closed;});\n for(unsigned i=0;i<200 && closed==0;++i)std::this_thread::sleep_for(5ms);\n const bool actual_closed=::fcntl(pair[0],F_GETFD)<0 && errno==EBADF;\n channel->revoke();channel->schedule_closures();\n auth::detail::console_registry::revoke(entry);auth::detail::console_registry::schedule_closures(entry);\n fixture::run_main();\n // This fixture has no installed runtime hint: remove an actually retired entry\n // solely to give the next independent scenario its own empty process registry.\n const bool actual_retired=auth::detail::console_registry::retired(entry);\n if(actual_retired){auto exact=entry;auth::detail::console_registry::current_.compare_exchange_strong(exact,nullptr);}\n ::close(pair[1]);work.reset();worker.join();\n peer.reset();lifetime.reset();callback.reset();dispatcher->terminate();dispatcher.reset();\n std::cout<<"{\\"scenario\\":"<<scenario<<",\\"no_success\\":"<<no_success<<",\\"actual_closed\\":"<<actual_closed<<",\\"actual_retired\\":"<<actual_retired<<",\\"successes\\":"<<successes<<",\\"errors\\":"<<errors<<",\\"native_darwin_auth_executed\\":0}\\n";\n return no_success && closed==1 && actual_closed && actual_retired ? 0:1;\n}\nint main(){for(unsigned scenario=0;scenario<3;++scenario)if(exercise(scenario))return 1;return 0;}\n'
)

CPP_CONTROLS["console_gate"] = (
    '// Actual header gates and genuine socketpair; modeled Security/watch/UID leaves.\n#include "remap_runtime_auth.hpp"\n#include <sys/socket.h>\n#include <future>\n#include <chrono>\n#include <iostream>\nint main(){\n namespace auth=ergoptiplus::remap::auth;using namespace std::chrono_literals;\n fixture::self_uid=501;fixture::self_role=ergoptiplus::remap::identity::role::console;\n fixture::peer_uid=0;fixture::peer_role=ergoptiplus::remap::identity::role::core;\n auto entry=auth::detail::console_registry::prepare(std::make_shared<ergoptiplus::remap::owned_console_parent_watch>(),11);\n if(!entry || !auth::detail::console_registry::publish(entry))return 10;\n auto channel=auth::channel_owner::session_client();\n int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 11;\n auto life=auth::socket_lifetime::bind(channel,pair[0]);if(!life)return 12;\n auto ticket=life->ticket(auth::frame_kind::response,1,{});if(!ticket)return 13;\n bool held=false,handoff_denied=false,one=false;\n const bool consumed=ticket->consume([&](auth::frame_scope& scope){\n   // This is the real intermediate stop state under the SAME Console gate,\n   // before registry.revoke iterates its child gates. No native leaf changes.\n   std::unique_lock lock(entry->gate->mutex_);entry->gate->stopped_=true;\n   held=channel->current_gate();\n   lock.unlock();\n   handoff_denied=!scope.handoff();\n   one=life->gate_->debt_.load()==1;\n });\n const auto minted=life->ticket(auth::frame_kind::response,2,{});\n const bool no_later= !minted && channel->current_gate();\n ticket.reset();\n auth::detail::console_registry::revoke(entry);\n const bool stopped=!life->current() && !channel->current_gate();\n ::close(pair[0]);::close(pair[1]);\n std::cout<<"{\\"consumed\\":"<<consumed<<",\\"intermediate_child_open\\":"<<held<<",\\"handoff_denied\\":"<<handoff_denied<<",\\"held_scope\\":"<<one<<",\\"mint_denied\\":"<<no_later<<",\\"stopped\\":"<<stopped<<",\\"native_darwin_auth_executed\\":0}\\n";\n // Raw fixture descriptors are externally released here; no native close ACK\n // or owner retirement is claimed for this gate-only probe.\n return consumed && held && handoff_denied && one && no_later && stopped ? 0:1;\n}\n'
)


CPP_CONTROLS["stock_default"] = (
    '// Real original pinned vendor peer, actual Linux socket/Asio/dispatcher closure.\n// This is a positive STOCK-contract baseline, not an AUTH/native identity proof.\n#include <pqrs/unix_domain_stream/impl/peer.hpp>\n#include <pqrs/dispatcher/time_source.hpp>\n#include <asio.hpp>\n#include <chrono>\n#include <condition_variable>\n#include <fcntl.h>\n#include <iostream>\n#include <mutex>\n#include <sys/socket.h>\n#include <thread>\n#include <unistd.h>\n\nint main() {\n  using namespace std::chrono_literals;\n  int pair[2] = {-1, -1};\n  if (::socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return 10;\n  asio::io_context io;\n  auto work = asio::make_work_guard(io);\n  auto time = std::make_shared<pqrs::dispatcher::hardware_time_source>();\n  auto dispatcher = std::make_shared<pqrs::dispatcher::dispatcher>(time);\n  asio::local::stream_protocol::socket socket(io);\n  socket.assign(asio::local::stream_protocol(), pair[0]);\n  auto peer = std::make_shared<pqrs::unix_domain_stream::impl::peer>(\n      dispatcher, std::move(socket), pqrs::unix_domain_stream::common_options{});\n  std::mutex mutex;\n  std::condition_variable changed;\n  bool held = false, released = false, finished = false, completed = false;\n  bool closed_inside_held_callback = false, actual_fd_closed = false;\n  std::vector<std::uint8_t> received;\n  peer->received.connect([&](auto buffer) {\n    std::unique_lock<std::mutex> lock(mutex);\n    received = *buffer;\n    held = true;\n    changed.notify_all();\n    changed.wait(lock, [&] { return released; });\n    finished = true;\n    changed.notify_all();\n  });\n  std::thread worker([&] { io.run(); });\n  peer->async_start();\n  const std::vector<std::uint8_t> expected{4, 5, 6, 7};\n  auto wire = pqrs::unix_domain_stream::impl::protocol::make_user_data_frame(expected);\n  if (::write(pair[1], wire.data(), wire.size()) != static_cast<ssize_t>(wire.size())) return 11;\n  {\n    std::unique_lock<std::mutex> lock(mutex);\n    if (!changed.wait_for(lock, 3s, [&] { return held; })) return 12;\n  }\n  peer->async_close([&] {\n    std::lock_guard<std::mutex> lock(mutex);\n    completed = true;\n    closed_inside_held_callback = held && !finished;\n    errno = 0;\n    actual_fd_closed = ::fcntl(pair[0], F_GETFD) == -1 && errno == EBADF;\n    changed.notify_all();\n  });\n  bool healthy = false;\n  {\n    std::unique_lock<std::mutex> lock(mutex);\n    healthy = changed.wait_for(lock, 3s, [&] { return completed; }) &&\n              received == expected && actual_fd_closed && closed_inside_held_callback;\n    released = true;\n    changed.notify_all();\n    if (!changed.wait_for(lock, 3s, [&] { return finished; })) healthy = false;\n  }\n  ::close(pair[1]);\n  work.reset();\n  worker.join();\n  peer.reset();\n  dispatcher->terminate();\n  dispatcher.reset();\n  if (!healthy) return 13;\n  std::cout << "{\\"stock_actual_payload\\":true,\\"stock_actual_fd_closed\\":true,"\n               "\\"stock_completion_inside_held_callback\\":true,"\n               "\\"selected_auth_interface\\":\\"ABSENT\\",\\"native_darwin_auth_executed\\":0}\\n";\n  if (fixture::samples.load() != 0 || fixture_self_identity_reads.load() != 0) return 14;\n  return 0;\n}\n'
)


CPP_CONTROLS["callback_retirement"] = (
    '// Exact selected request_manager and genuine pqrs dispatcher/Asio execution.\n// Native signing/UID/watch and serial MAIN are the existing disclosed leaf models.\n#include <pqrs/unix_domain_stream/impl/request_manager.hpp>\n#include <pqrs/dispatcher/time_source.hpp>\n#include <condition_variable>\n#include <future>\n#include <iostream>\n#include <thread>\nusing namespace std::chrono_literals;\nnamespace auth=ergoptiplus::remap::auth;\nclass callback_owner final : public pqrs::dispatcher::extra::dispatcher_client {\npublic:\n explicit callback_owner(std::weak_ptr<pqrs::dispatcher::dispatcher> dispatcher):dispatcher_client(dispatcher){}\n ~callback_owner(){detach_from_dispatcher();}\n};\nstruct destructor_latch {\n std::mutex mutex; std::condition_variable condition; bool entered=false, released=false;\n std::atomic<bool> body_returned=false;\n};\nstruct actual_capture {\n std::shared_ptr<destructor_latch> latch;\n ~actual_capture(){\n  std::unique_lock<std::mutex> lock(latch->mutex);\n  latch->entered=true; latch->condition.notify_all();\n  latch->condition.wait(lock,[&]{return latch->released;});\n }\n};\nint main(){\n fixture::self_uid=501;fixture::self_role=ergoptiplus::remap::identity::role::console;\n asio::io_context io; auto work=asio::make_work_guard(io);\n auto dispatcher=std::make_shared<pqrs::dispatcher::dispatcher>(std::make_shared<pqrs::dispatcher::hardware_time_source>());\n auto callback=std::make_unique<callback_owner>(dispatcher);\n auto entry=auth::detail::console_registry::prepare(std::make_shared<ergoptiplus::remap::owned_console_parent_watch>(),51);\n if(!entry || !auth::detail::console_registry::publish(entry))return 2;\n std::atomic<unsigned> hints=0;\n if(!auth::detail::console_registry::set_retirement_hint(entry,[&]{++hints;}))return 3;\n auto channel=auth::channel_owner::session_client();\n pqrs::unix_domain_stream::impl::request_manager manager(io,*callback,channel);\n auto latch=std::make_shared<destructor_latch>();\n std::promise<void> submitted;\n asio::post(io,[&]{\n  auto capture=std::make_shared<actual_capture>();capture->latch=latch;\n  const auto id=manager.add(std::nullopt,5s,nullptr,nullptr,\n    [capture,latch](const std::error_code& error,auth::frame_scope* scope){\n      if(error==asio::error::operation_aborted && !scope)latch->body_returned=true;\n    },"console_user_id_changed");\n  if(id!=1)std::terminate();\n  channel->revoke();\n  auth::detail::console_registry::revoke(entry);\n  manager.complete_all(asio::error::operation_aborted);\n  submitted.set_value();\n });\n std::thread io_worker([&]{io.run();}); submitted.get_future().get();\n bool entered=false;\n {std::unique_lock<std::mutex> lock(latch->mutex);entered=latch->condition.wait_for(lock,2s,[&]{return latch->entered;});}\n // Genuine IO cancellation handler has finished before this posted barrier.\n std::promise<void> io_drained;asio::post(io,[&]{io_drained.set_value();});io_drained.get_future().get();\n fixture::run_main();\n const bool prematurely_retired=auth::detail::console_registry::retired(entry);\n const unsigned premature_hints=hints.load();\n {std::lock_guard<std::mutex> lock(latch->mutex);latch->released=true;}latch->condition.notify_all();\n std::promise<void> dispatcher_drained;callback->enqueue_to_dispatcher([&]{dispatcher_drained.set_value();});dispatcher_drained.get_future().get();\n fixture::run_main();\n const bool finally_retired=auth::detail::console_registry::retired(entry);\n work.reset();io_worker.join();callback.reset();dispatcher->terminate();\n std::cout<<"{\\"capture_destructor_entered\\":"<<entered<<",\\"callback_body_returned\\":"<<latch->body_returned<<",\\"retired_while_capture_destructor_active\\":"<<prematurely_retired<<",\\"hints_while_capture_destructor_active\\":"<<premature_hints<<",\\"finally_retired\\":"<<finally_retired<<",\\"final_hints\\":"<<hints<<",\\"native_darwin_executed\\":0}\\n";\n return entered && latch->body_returned && !prematurely_retired && premature_hints==0 && finally_retired && hints==1 ? 0:1;\n}\n'
)


CPP_CONTROLS["callback_error_retirement"] = (
    '// Exact selected request_manager and genuine pqrs dispatcher/Asio execution.\n// Native signing/UID/watch and serial MAIN are the existing disclosed leaf models.\n#include <pqrs/unix_domain_stream/impl/request_manager.hpp>\n#include <pqrs/dispatcher/time_source.hpp>\n#include <condition_variable>\n#include <future>\n#include <iostream>\n#include <thread>\nusing namespace std::chrono_literals;\nnamespace auth=ergoptiplus::remap::auth;\nclass callback_owner final : public pqrs::dispatcher::extra::dispatcher_client {\npublic:\n explicit callback_owner(std::weak_ptr<pqrs::dispatcher::dispatcher> dispatcher):dispatcher_client(dispatcher){}\n ~callback_owner(){detach_from_dispatcher();}\n};\nstruct destructor_latch {\n std::mutex mutex; std::condition_variable condition; bool entered=false, released=false;\n std::atomic<bool> body_returned=false;\n};\nstruct actual_capture {\n std::shared_ptr<destructor_latch> latch;\n ~actual_capture(){\n  std::unique_lock<std::mutex> lock(latch->mutex);\n  latch->entered=true; latch->condition.notify_all();\n  latch->condition.wait(lock,[&]{return latch->released;});\n }\n};\nint main(){\n fixture::self_uid=501;fixture::self_role=ergoptiplus::remap::identity::role::console;\n asio::io_context io; auto work=asio::make_work_guard(io);\n auto dispatcher=std::make_shared<pqrs::dispatcher::dispatcher>(std::make_shared<pqrs::dispatcher::hardware_time_source>());\n auto callback=std::make_unique<callback_owner>(dispatcher);\n auto entry=auth::detail::console_registry::prepare(std::make_shared<ergoptiplus::remap::owned_console_parent_watch>(),51);\n if(!entry || !auth::detail::console_registry::publish(entry))return 2;\n std::atomic<unsigned> hints=0;\n if(!auth::detail::console_registry::set_retirement_hint(entry,[&]{++hints;}))return 3;\n auto channel=auth::channel_owner::session_client();\n pqrs::unix_domain_stream::impl::request_manager manager(io,*callback,channel);\n auto latch=std::make_shared<destructor_latch>();\n std::promise<void> submitted;\n asio::post(io,[&]{\n  auto capture=std::make_shared<actual_capture>();capture->latch=latch;\n  auto held_debt=channel->retain_construction();\n  channel->revoke();\n  auth::detail::console_registry::revoke(entry);\n  const auto id=manager.add(std::nullopt,5s,nullptr,nullptr,\n    [capture,latch](const std::error_code& error,auth::frame_scope* scope){\n      if(error==asio::error::operation_aborted && !scope)latch->body_returned=true;\n    },"console_user_id_changed",held_debt);\n  if(id!=0)std::terminate();\n  held_debt.reset();\n  submitted.set_value();\n });\n std::thread io_worker([&]{io.run();}); submitted.get_future().get();\n bool entered=false;\n {std::unique_lock<std::mutex> lock(latch->mutex);entered=latch->condition.wait_for(lock,2s,[&]{return latch->entered;});}\n // Genuine IO cancellation handler has finished before this posted barrier.\n std::promise<void> io_drained;asio::post(io,[&]{io_drained.set_value();});io_drained.get_future().get();\n fixture::run_main();\n const bool prematurely_retired=auth::detail::console_registry::retired(entry);\n const unsigned premature_hints=hints.load();\n {std::lock_guard<std::mutex> lock(latch->mutex);latch->released=true;}latch->condition.notify_all();\n std::promise<void> dispatcher_drained;callback->enqueue_to_dispatcher([&]{dispatcher_drained.set_value();});dispatcher_drained.get_future().get();\n fixture::run_main();\n const bool finally_retired=auth::detail::console_registry::retired(entry);\n work.reset();io_worker.join();callback.reset();dispatcher->terminate();\n std::cout<<"{\\"capture_destructor_entered\\":"<<entered<<",\\"callback_body_returned\\":"<<latch->body_returned<<",\\"retired_while_capture_destructor_active\\":"<<prematurely_retired<<",\\"hints_while_capture_destructor_active\\":"<<premature_hints<<",\\"finally_retired\\":"<<finally_retired<<",\\"final_hints\\":"<<hints<<",\\"native_darwin_executed\\":0}\\n";\n return entered && latch->body_returned && !prematurely_retired && premature_hints==0 && finally_retired && hints==1 ? 0:1;\n}\n'
)


def qualified_callback_handoff(source):
    """Leave the final captured object on its genuine dispatcher callable.

    The original control's IO-local alias otherwise races the queued callback's
    destruction. The held destructor still runs after the callback body returns.
    Frozen retirement expectations and all child budgets remain unchanged.
    """
    replacements = (
        (
            "std::atomic<bool> body_returned=false;",
            "std::atomic<bool> body_returned=false; bool io_capture_released=false;",
        ),
        (
            "      if(error==asio::error::operation_aborted && !scope)latch->body_returned=true;",
            "      { std::unique_lock<std::mutex> lock(latch->mutex);\n"
            "        latch->condition.wait(lock,[&]{return latch->io_capture_released;}); }\n"
            "      if(error==asio::error::operation_aborted && !scope)latch->body_returned=true;",
        ),
        (
            "  submitted.set_value();",
            "  capture.reset();\n"
            "  { std::lock_guard<std::mutex> lock(latch->mutex); latch->io_capture_released=true; }\n"
            "  latch->condition.notify_all();\n"
            "  submitted.set_value();",
        ),
    )
    for before, after in replacements:
        if source.count(before) != 1:
            raise RuntimeError("Frozen callback fixture handoff anchor changed")
        source = source.replace(before, after)
    return source


def load_transport():
    path = Path(__file__).with_name("remap_runtime_auth_transport.py")
    spec = importlib.util.spec_from_file_location("auth_transport_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def effect_switch(source):
    start = source.index('switch (json.at("operation_type").get<operation_type>())')
    begin = source.index("{", start)
    depth = 1
    end = begin + 1
    while depth:
        if source[end] == "{":
            depth += 1
        if source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


class AuthTransportCompositionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_transport()
        cls.inputs = {key: (SOURCE_ROOT / key).read_bytes() for key in EXPECTED_PREIMAGES}
        cls.header = Path(__file__).with_name("remap_runtime_auth.hpp").read_bytes()

    def compose(self, inputs=None, header=None, deadline=None):
        return self.module.assemble_owned_auth_transport(
            self.inputs if inputs is None else inputs,
            self.header if header is None else header,
            time.monotonic() + 30 if deadline is None else deadline,
        )

    def test_pinned_inputs(self):
        for path, expected in EXPECTED_PREIMAGES.items():
            with self.subTest(path=path):
                self.assertEqual(hashlib.sha256(self.inputs[path]).hexdigest(), expected)

    def test_fixed_inventory_and_bytes(self):
        output = self.compose()
        self.assertEqual(set(output), set(EXPECTED_PREIMAGES))
        self.assertEqual(len(output), 11)
        for path, value in output.items():
            with self.subTest(path=path):
                self.assertIs(type(value), bytes)
                self.assertNotEqual(value, self.inputs[path])

    def test_input_mapping_is_unchanged(self):
        inputs = dict(self.inputs)
        self.compose(inputs)
        self.assertEqual(inputs, self.inputs)

    def test_output_is_deterministic(self):
        self.assertEqual(self.compose(), self.compose())

    def test_wrong_inventory(self):
        for inputs in ({}, {**self.inputs, "foreign.hpp": b""}):
            with self.subTest(keys=list(inputs)):
                with self.assertRaises(self.module.AuthTransportRefusal):
                    self.compose(inputs)

    def test_wrong_bytes(self):
        key = next(iter(self.inputs))
        with self.assertRaises(self.module.AuthTransportRefusal):
            self.compose({**self.inputs, key: self.inputs[key].decode()})

    def test_wrong_header(self):
        with self.assertRaises(self.module.AuthTransportRefusal):
            self.compose(header=self.header + b"\n")

    def test_expired_deadline(self):
        with self.assertRaises(self.module.AuthTransportRefusal):
            self.compose(deadline=time.monotonic() - 1)

    def test_nonfinite_or_bool_deadline(self):
        for value in (math.nan, math.inf, -math.inf, True):
            with self.subTest(deadline=value):
                with self.assertRaises(self.module.AuthTransportRefusal):
                    self.compose(deadline=value)

    def test_modified_inputs_refuse(self):
        output = self.compose()
        for key in output:
            with self.subTest(path=key):
                with self.assertRaises(self.module.AuthTransportRefusal):
                    self.compose({**self.inputs, key: output[key]})

    def test_receiver_effect_switches_preserved(self):
        output = self.compose()
        for path in (
            "src/apps/CoreService/include/core_service/daemon/receiver.hpp",
            "src/apps/ConsoleUserServer/include/console_user_server/receiver.hpp",
            "src/apps/CoreService/include/core_service/daemon/console_user_id_changed_receiver.hpp",
        ):
            with self.subTest(path=path):
                original = effect_switch(self.inputs[path].decode())
                actual = effect_switch(output[path].decode())
                if path.endswith("console_user_id_changed_receiver.hpp"):
                    original = original.replace(
                        "auto uid = get_peer_uid(peer_id);",
                        "std::optional<uid_t> uid = scope.view().peer_uid();",
                    )
                self.assertEqual(actual, original)

    def test_core_stream_anchors_unique(self):
        output = self.compose()
        source = output["src/apps/CoreService/include/core_service/daemon/receiver.hpp"].decode()
        for anchor in (
            "case operation_type::observe_connected_devices:",
            "connected_devices_observer_peer_ids_.erase(peer_id);",
            "std::optional<uid_t> current_console_user_id_;",
            "void update_temporarily_ignored_device_ids() {",
        ):
            with self.subTest(anchor=anchor):
                self.assertEqual(source.count(anchor), 1)
        client = output["src/share/core_service_daemon_client.hpp"].decode()
        self.assertEqual(client.count("void async_stop() {"), 1)

    def test_source_recipe_has_no_io(self):
        source = Path(self.module.__file__).read_text()
        for forbidden in (
            "read_text(",
            "read_bytes(",
            "write_text(",
            "write_bytes(",
            "subprocess.",
        ):
            with self.subTest(api=forbidden):
                self.assertNotIn(forbidden, source)

    def test_actual_peer_request_frame_retirement(self):
        self.run_cpp("held_request")

    def test_actual_request_manager_response_retirement(self):
        self.run_cpp("held_response")

    def test_actual_session_pending_empty_ack(self):
        self.run_cpp("session_empty_ack")

    def test_actual_pending_metadata_cancel_and_late_id(self):
        self.run_cpp("pending_negatives")

    def test_console_and_channel_final_publication_gates(self):
        self.run_cpp("console_gate")

    def test_actual_stock_default_zero_auth_queries(self):
        self.run_cpp("stock_default")

    def test_actual_pending_callable_capture_retirement(self):
        self.run_cpp("callback_retirement", native_marker='"native_darwin_executed":0')

    def test_actual_refused_request_callable_capture_retirement(self):
        self.run_cpp("callback_error_retirement", native_marker='"native_darwin_executed":0')

    def run_cpp(self, case, *, native_marker='"native_darwin_auth_executed":0'):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler, "The actual C++23 toolchain is required")
        outputs = self.compose()
        with tempfile.TemporaryDirectory(prefix="ergopti-auth-portable-") as tmp:
            root = Path(tmp).resolve()
            headers = root / "include"
            headers.mkdir()
            vendor = root / "vendor"
            vendor.mkdir()
            original_vendor = SOURCE_ROOT / "vendor/vendor/include"
            self.assertTrue(original_vendor.is_dir())
            for original in original_vendor.rglob("*"):
                target = vendor / original.relative_to(original_vendor)
                if original.is_dir():
                    target.mkdir(exist_ok=True)
                else:
                    target.symlink_to(original.resolve())
            for path, value in outputs.items():
                prefix = "vendor/vendor/include/"
                if path.startswith(prefix):
                    target = vendor / path[len(prefix) :]
                    if target.is_symlink():
                        target.unlink()
                    # Only fixture access to the actual peer handler slot changes.
                    if path.endswith("impl/peer.hpp"):
                        value = value.replace(
                            b"private:\n  friend class client_state;",
                            b"public:\n  friend class client_state;",
                        )
                    target.write_bytes(value)
            source = self.header.decode()
            forward = source[
                source.index("namespace pqrs::unix_domain_stream {") : source.index(
                    "template <typename T>"
                )
            ]
            actual = source[source.index("// Internal portable bookkeeping foundation.") :]
            actual = actual.replace("::geteuid()", "fixture::geteuid()")
            projected = NATIVE_LEAF_PREFIX + forward + NATIVE_LEAF_MODEL + actual
            projected = projected.replace(
                "#include <asio.hpp>", "#include <asio.hpp>\n#include <nlohmann/json.hpp>"
            )
            # Disclosed fixture visibility: no authority/retirement/native IO
            # method body is altered. Private production declarations are
            # separately compiled without this fixture visibility change.
            projected = projected.replace("private:", "public:")
            (headers / "remap_runtime_auth.hpp").write_text(projected)
            for name in ("remap_runtime_auth_policy.hpp", "remap_runtime_identity.hpp"):
                (headers / name).write_bytes(Path(__file__).with_name(name).read_bytes())
            cpp = root / "control.cpp"
            control = CPP_CONTROLS[case]
            if case in {"callback_retirement", "callback_error_retirement"}:
                control = qualified_callback_handoff(control)
            cpp.write_text(control)
            binary = root / "control"
            build = subprocess.run(
                [
                    compiler,
                    "-std=c++23",
                    "-O0",
                    "-pthread",
                    "-I",
                    str(headers),
                    "-I",
                    str(vendor),
                    str(cpp),
                    "-o",
                    str(binary),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn(native_marker, run.stdout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    SOURCE_ROOT = args.source_root.resolve(strict=True)
    unittest.main(argv=[str(Path(__file__)), *remaining])
