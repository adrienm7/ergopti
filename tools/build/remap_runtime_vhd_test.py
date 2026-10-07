# tools/build/remap_runtime_vhd_test.py
"""Fixed source and genuine portable lifetime controls.

Security, official protected files and audit tokens are explicitly modeled only
in private C++ copies. No native broker/installed/capture credit is granted.
"""

import argparse
import hashlib
import importlib.util
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BUILD = Path(__file__).resolve().parent
MODULE = BUILD / "remap_runtime_vhd_transport.py"
HEADER = BUILD / "remap_runtime_vhd.hpp"
ROOT = None
SOURCE_ROOT = None
AUTH_OUTPUTS = None
LOWER = "vendor/vendor/include/pqrs/unix_domain_stream/client.hpp"
PEER = "vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp"
CORE = "src/apps/CoreService/include/core_service/daemon/device_grabber.hpp"
UPPER = "vendor/Karabiner-DriverKit-VirtualHIDDevice/include/pqrs/karabiner/driverkit/virtual_hid_device_service/client.hpp"
REQUESTS = "vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp"
REQUESTS_SHA256 = "23250dd6733fbfe43cdd030ee575bf0b6a271330a340f96c71541ef54cf27dfc"
AUTH_SUPPORT_SHA256 = "958eec8bc543db610956601a39f9074cd9926d18da1339e3c1de069f605d6481"
AUTH_PROVIDER_SHA256 = "1942feef1492cb2e9524964e614561590cb41fd4c664ff2c74fde235238ee6fb"


def fixed_module(name, path, expected=None):
    data = path.read_bytes()
    if expected is not None and hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError("fixed portable support source drift")
    spec = importlib.util.spec_from_loader(name, loader=None)
    module = importlib.util.module_from_spec(spec)
    module.__file__ = str(path)
    sys.modules[name] = module
    exec(compile(data, str(path), "exec"), module.__dict__)
    return module


def provider():
    return fixed_module("frozen_vhd_provider", MODULE)


def inputs():
    requests = (ROOT / "post-auth" / REQUESTS).read_bytes()
    if hashlib.sha256(requests).hexdigest() != REQUESTS_SHA256:
        raise RuntimeError("independently frozen fifth preimage drift")
    return {
        REQUESTS: requests,
        LOWER: (ROOT / "post-auth" / LOWER).read_bytes(),
        PEER: (ROOT / "post-auth" / PEER).read_bytes(),
        CORE: (ROOT / "originals" / CORE).read_bytes(),
        UPPER: (ROOT / "originals" / UPPER).read_bytes(),
    }


def prepare_inputs(root, source):
    global ROOT, SOURCE_ROOT, AUTH_OUTPUTS
    ROOT, SOURCE_ROOT = root, source
    support = fixed_module(
        "whole_old_auth_test_support",
        BUILD / "remap_runtime_auth_transport_test.py",
        AUTH_SUPPORT_SHA256,
    )
    actual = {path: (source / path).read_bytes() for path in support.EXPECTED_PREIMAGES}
    for path, expected in support.EXPECTED_PREIMAGES.items():
        if hashlib.sha256(actual[path]).hexdigest() != expected:
            raise RuntimeError("genuine pristine vendor preimage drift")
    auth = fixed_module(
        "retained_auth_provider", BUILD / "remap_runtime_auth_transport.py", AUTH_PROVIDER_SHA256
    )
    AUTH_OUTPUTS = auth.assemble_owned_auth_transport(
        actual, (BUILD / "remap_runtime_auth.hpp").read_bytes(), time.monotonic() + 30
    )
    for path in (LOWER, PEER, REQUESTS):
        out = root / "post-auth" / path
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(AUTH_OUTPUTS[path])
    for path in (CORE, UPPER):
        out = root / "originals" / path
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes((source / path).read_bytes())
    (root / "pristine-lower.hpp").write_bytes(actual[LOWER])


class FrozenProjectionControls(unittest.TestCase):
    def test_stock_lower_client_cannot_bypass_the_authenticated_preimage(self):
        p = provider()
        rows = inputs()
        rows[LOWER] = (ROOT / "pristine-lower.hpp").read_bytes()
        self.assertNotEqual(rows[LOWER], inputs()[LOWER])
        self.assertEqual(
            hashlib.sha256(rows[LOWER]).hexdigest(),
            "d6120091e024aa29228fb83378ba94cbbf2778218d8d429a9311ea4150080a4d",
        )
        with self.assertRaises(p.VHDTransportRefusal):
            p.assemble_vhd_transport(rows, HEADER.read_bytes(), time.monotonic() + 10)

    def test_actual_held_postauth_peer_comment_mutation_refuses(self):
        p = provider()
        rows = inputs()
        rows[PEER] += b"\n// independent drift\n"
        with self.assertRaises(p.VHDTransportRefusal):
            p.assemble_vhd_transport(rows, HEADER.read_bytes(), time.monotonic() + 10)

    def test_genuine_pristine_upper_client_mutation_refuses(self):
        p = provider()
        rows = inputs()
        rows[UPPER] += b"\n// independent upper drift\n"
        with self.assertRaises(p.VHDTransportRefusal):
            p.assemble_vhd_transport(rows, HEADER.read_bytes(), time.monotonic() + 10)

    def test_core_callsite_preimage_mutation_refuses(self):
        p = provider()
        rows = inputs()
        rows[CORE] += b"\n// independent caller drift\n"
        with self.assertRaises(p.VHDTransportRefusal):
            p.assemble_vhd_transport(rows, HEADER.read_bytes(), time.monotonic() + 10)

    def test_missing_or_extra_source_is_not_partial_projection(self):
        p = provider()
        for key in (LOWER, "unknown.hpp"):
            rows = inputs()
            if key == LOWER:
                rows.pop(key)
            else:
                rows[key] = b"unowned source"
            with self.assertRaises(p.VHDTransportRefusal):
                p.assemble_vhd_transport(rows, HEADER.read_bytes(), time.monotonic() + 10)

    def test_nonbytes_source_is_not_a_caller_override(self):
        p = provider()
        rows = inputs()
        rows[CORE] = rows[CORE].decode()
        with self.assertRaises(p.VHDTransportRefusal):
            p.assemble_vhd_transport(rows, HEADER.read_bytes(), time.monotonic() + 10)

    def test_wrong_header_never_produces_a_trusted_graph(self):
        p = provider()
        for value in (HEADER.read_bytes() + b"\n// altered header\n", b"#pragma once\n", None):
            with self.assertRaises(p.VHDTransportRefusal):
                p.assemble_vhd_transport(inputs(), value, time.monotonic() + 10)

    def test_expired_and_nonfinite_absolute_budget_refuse(self):
        p = provider()
        for value in (time.monotonic() - 1, math.inf, math.nan, True):
            with self.assertRaises(p.VHDTransportRefusal):
                p.assemble_vhd_transport(inputs(), HEADER.read_bytes(), value)

    def test_projection_is_pure_and_keeps_complete_exact_inventory(self):
        p = provider()
        rows = inputs()
        before = dict(rows)
        result = p.assemble_vhd_transport(rows, HEADER.read_bytes(), time.monotonic() + 10)
        self.assertEqual(rows, before)
        self.assertEqual(set(result), set(before))
        self.assertTrue(all(type(value) is bytes for value in result.values()))
        self.assertEqual(
            result, p.assemble_vhd_transport(rows, HEADER.read_bytes(), time.monotonic() + 10)
        )

    def test_preprojected_graph_cannot_be_assembled_twice(self):
        p = provider()
        rows = p.assemble_vhd_transport(inputs(), HEADER.read_bytes(), time.monotonic() + 10)
        with self.assertRaises(p.VHDTransportRefusal):
            p.assemble_vhd_transport(rows, HEADER.read_bytes(), time.monotonic() + 10)


CPP_CONTROLS = {
    "timer": '// Genuine pinned request_manager/Asio/pqrs dispatcher cancellation and capture\n// destruction. Native protected-daemon/Security/audit leaves are TEST-ONLY models.\n#include <pqrs/unix_domain_stream/impl/request_manager.hpp>\n#include "remap_runtime_vhd.hpp"\n#include <pqrs/dispatcher/time_source.hpp>\n#include <condition_variable>\n#include <future>\n#include <iostream>\n#include <thread>\n#include <type_traits>\n#include <sys/socket.h>\nusing namespace std::chrono_literals;\nnamespace vhd = ergoptiplus::remap::vhd;\nclass callback_owner final : public pqrs::dispatcher::extra::dispatcher_client {\npublic:\n explicit callback_owner(std::weak_ptr<pqrs::dispatcher::dispatcher> d): dispatcher_client(d) {}\n ~callback_owner(){detach_from_dispatcher();}\n};\nstruct latch {\n std::mutex mutex; std::condition_variable changed; bool entered=false, released=false;\n};\nstruct captured {\n std::shared_ptr<latch> state;\n ~captured(){std::unique_lock lock(state->mutex);state->entered=true;state->changed.notify_all();state->changed.wait(lock,[&]{return state->released;});}\n};\ntemplate<class Manager> std::unique_ptr<Manager> actual_manager(asio::io_context& io, callback_owner& callbacks, std::shared_ptr<vhd::broker_owner> owner){\n if constexpr(std::is_constructible_v<Manager,asio::io_context&,callback_owner&,std::shared_ptr<ergoptiplus::remap::auth::channel_owner>,std::shared_ptr<vhd::broker_owner>>)\n  return std::make_unique<Manager>(io,callbacks,nullptr,owner);\n else return std::make_unique<Manager>(io,callbacks);\n}\nint main(){\n asio::io_context io;auto work=asio::make_work_guard(io);\n auto dispatcher=std::make_shared<pqrs::dispatcher::dispatcher>(std::make_shared<pqrs::dispatcher::hardware_time_source>());\n auto callbacks=std::make_unique<callback_owner>(dispatcher);\n int pair[2];if(::socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 7;\n auto socket=std::make_shared<asio::local::stream_protocol::socket>(io);socket->assign(asio::local::stream_protocol(),pair[0]);\n auto owner=vhd::broker_owner::acquire();\n auto session=vhd::connection::stage(owner,socket);if(!session || !session->current())return 8;\n auto manager=actual_manager<pqrs::unix_domain_stream::impl::request_manager>(io,*callbacks,owner);\n auto state=std::make_shared<latch>();std::atomic<unsigned> timed_out=0,errors=0;\n auto capture=std::make_shared<captured>();capture->state=state;\n auto id=manager->add(std::nullopt,5s,[&](const auto& error,auto){if(error==asio::error::operation_aborted)++errors;},[capture,&timed_out]{++timed_out;});\n capture.reset();\n owner->retire();\n manager->complete_all(asio::error::operation_aborted);\n std::promise<void> callbacks_drained;callbacks->enqueue_to_dispatcher([&]{callbacks_drained.set_value();});callbacks_drained.get_future().get();\n std::thread worker([&]{io.run();});\n bool entered=false;{std::unique_lock lock(state->mutex);entered=state->changed.wait_for(lock,2s,[&]{return state->entered;});}\n const bool premature=owner->retired();\n {std::lock_guard lock(state->mutex);state->released=true;}state->changed.notify_all();\n std::promise<void> io_drained;asio::post(io,[&]{io_drained.set_value();});io_drained.get_future().get();\n const bool retired=owner->retired();::close(pair[1]);work.reset();worker.join();manager.reset();callbacks.reset();dispatcher->terminate();\n std::cout<<"{\\"actual_timer_capture_destructor_entered\\":"<<entered<<",\\"retired_during_actual_destructor\\":"<<premature<<",\\"finally_retired\\":"<<retired<<",\\"timed_out\\":"<<timed_out<<",\\"error_callbacks\\":"<<errors<<",\\"native_darwin_executed\\":0}\\n";\n return id==1 && entered && !premature && retired && timed_out==0 && errors==1 ? 0:1;\n}\n',
    "callback": '// Genuine request_manager completion, dispatcher capture destruction and FD\n// custody. Native protected-daemon/Security/audit leaves are TEST-ONLY models.\n#include <pqrs/unix_domain_stream/impl/request_manager.hpp>\n#include "remap_runtime_vhd.hpp"\n#include <pqrs/dispatcher/time_source.hpp>\n#include <sys/socket.h>\n#include <condition_variable>\n#include <future>\n#include <iostream>\n#include <thread>\nusing namespace std::chrono_literals;\nnamespace vhd=ergoptiplus::remap::vhd;\nclass callback_owner final : public pqrs::dispatcher::extra::dispatcher_client {\npublic:explicit callback_owner(std::weak_ptr<pqrs::dispatcher::dispatcher> d):dispatcher_client(d){}~callback_owner(){detach_from_dispatcher();}\n};\nstruct latch{std::mutex mutex;std::condition_variable changed;bool entered=false,released=false;std::atomic<bool> returned=false;};\nstruct captured{std::shared_ptr<latch> state;~captured(){std::unique_lock lock(state->mutex);state->entered=true;state->changed.notify_all();state->changed.wait(lock,[&]{return state->released;});}};\nint main(){\n int pair[2];if(::socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 7;\n asio::io_context io;auto work=asio::make_work_guard(io);\n auto dispatcher=std::make_shared<pqrs::dispatcher::dispatcher>(std::make_shared<pqrs::dispatcher::hardware_time_source>());\n auto callbacks=std::make_unique<callback_owner>(dispatcher);\n auto socket=std::make_shared<asio::local::stream_protocol::socket>(io);socket->assign(asio::local::stream_protocol(),pair[0]);\n auto owner=vhd::broker_owner::acquire();auto session=vhd::connection::stage(owner,socket);if(!session || !session->current())return 8;\n auto manager=std::make_unique<pqrs::unix_domain_stream::impl::request_manager>(io,*callbacks,nullptr,owner);\n auto state=std::make_shared<latch>();auto capture=std::make_shared<captured>();capture->state=state;\n std::atomic<unsigned> errors=0;\n auto id=manager->add(std::nullopt,5s,[capture,state,&errors](const auto& error,auto){if(error==asio::error::operation_aborted)++errors;state->returned=true;});\n capture.reset();manager->complete_all(asio::error::operation_aborted);owner->retire();std::thread worker([&]{io.run();});\n bool entered=false;{std::unique_lock lock(state->mutex);entered=state->changed.wait_for(lock,2s,[&]{return state->entered;});}\n std::promise<void> io_barrier;asio::post(io,[&]{io_barrier.set_value();});io_barrier.get_future().get();\n const bool held=::fcntl(pair[0],F_GETFD)>=0;const bool premature=owner->retired();\n {std::lock_guard lock(state->mutex);state->released=true;}state->changed.notify_all();\n std::promise<void> callbacks_drained;callbacks->enqueue_to_dispatcher([&]{callbacks_drained.set_value();});callbacks_drained.get_future().get();\n for(unsigned i=0;i<100 && !owner->retired();++i)std::this_thread::sleep_for(1ms);\n const bool retired=owner->retired();errno=0;const bool closed=::fcntl(pair[0],F_GETFD)<0 && errno==EBADF;\n ::close(pair[1]);work.reset();worker.join();manager.reset();callbacks.reset();dispatcher->terminate();\n std::cout<<"{\\"actual_capture_destructor_entered\\":"<<entered<<",\\"callback_body_returned\\":"<<state->returned<<",\\"descriptor_held_during_destructor\\":"<<held<<",\\"retired_during_destructor\\":"<<premature<<",\\"finally_retired\\":"<<retired<<",\\"descriptor_closed\\":"<<closed<<",\\"error_callbacks\\":"<<errors<<",\\"native_darwin_executed\\":0}\\n";\n return id==1 && entered && state->returned && held && !premature && retired && closed && errors==1 ? 0:1;\n}\n',
    "lower": "// Actual fixed lower/peer/request-manager composition with disclosed native\n// identity leaf models. This does not compile or run Darwin native APIs.\n#include <pqrs/unix_domain_stream/client.hpp>\nint main(){return 0;}\n",
}
VHD_NATIVE_REFERENCE_MODEL = 'namespace detail {\ninline constexpr char endpoint[] = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock";\nclass daemon_reference final { public: bool acquire(){return true;} bool current(){return true;} bool retire(){return true;} };\n} // namespace detail'
VHD_NATIVE_SAMPLE_MODEL = "  bool sample() {\n    if (revoked_ || failed_ || physical_ || completed_ || !owner_->current() || ::fcntl(descriptor_,F_GETFD)<0) return false;\n    audit_token_t token{}; token.val[0]=fixture::token_generation.load();\n    if (token_ && std::memcmp(&*token_,&token,sizeof(token))!=0) return false;\n    token_=token; return true;\n  }\n"


class PortableCustodyControls(unittest.TestCase):
    def run_cpp(self, case):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler, "Actual portable C++ compiler prerequisite missing")
        support = fixed_module(
            "whole_auth_leaf_support",
            BUILD / "remap_runtime_auth_transport_test.py",
            AUTH_SUPPORT_SHA256,
        )
        auth = (BUILD / "remap_runtime_auth.hpp").read_text()
        forward = auth[
            auth.index("namespace pqrs::unix_domain_stream {") : auth.index("template <typename T>")
        ]
        actual = auth[auth.index("// Internal portable bookkeeping foundation.") :].replace(
            "::geteuid()", "fixture::geteuid()"
        )
        auth_projection = (
            (support.NATIVE_LEAF_PREFIX + forward + support.NATIVE_LEAF_MODEL + actual)
            .replace("#include <asio.hpp>", "#include <asio.hpp>\n#include <nlohmann/json.hpp>")
            .replace("private:", "public:")
        )
        original = HEADER.read_text()
        begin = original.index("namespace detail {")
        end = original.index("} // namespace detail", begin) + len("} // namespace detail")
        # Only fixed native reference/Security/token leaf images are modeled.
        # Everything after the namespace, including owner counters, generation,
        # actual Asio cancel/close and callback settlement, remains byte-whole.
        vhd = original[:begin] + VHD_NATIVE_REFERENCE_MODEL + original[end:]
        begin = vhd.index("  static bool peer_token(")
        end = vhd.index("  static std::shared_ptr<connection> stage(", begin)
        vhd = vhd[:begin] + VHD_NATIVE_SAMPLE_MODEL + vhd[end:]
        for line in ("#include <CommonCrypto/CommonDigest.h>", "#include <sys/acl.h>"):
            vhd = vhd.replace(line, "// TEST-ONLY native leaf include removed")
        vhd = vhd.replace("private:", "public:").replace(
            "class connection final : public std::enable_shared_from_this<connection> {",
            "class connection final : public std::enable_shared_from_this<connection> {\npublic:",
        )
        outputs = provider().assemble_vhd_transport(
            inputs(), HEADER.read_bytes(), time.monotonic() + 30
        )
        with tempfile.TemporaryDirectory(prefix="vhd-custody-") as directory:
            root = Path(directory)
            headers, vendor = root / "headers", root / "vendor"
            headers.mkdir()
            vendor.mkdir()
            original_vendor = SOURCE_ROOT / "vendor/vendor/include"
            for original_path in original_vendor.rglob("*"):
                target = vendor / original_path.relative_to(original_vendor)
                if original_path.is_dir():
                    target.mkdir(exist_ok=True)
                else:
                    target.symlink_to(original_path.resolve())
            # Actual old auth type/server outputs accompany the composed VHD
            # lower/peer/request-manager graph. No vendor body is stubbed.
            rows = dict(AUTH_OUTPUTS)
            rows.update(outputs)
            for path, value in rows.items():
                prefix = "vendor/vendor/include/"
                if path.startswith(prefix):
                    target = vendor / path[len(prefix) :]
                    target.unlink()
                    target.write_bytes(value)
            (headers / "remap_runtime_auth.hpp").write_text(auth_projection)
            (headers / "remap_runtime_vhd.hpp").write_text(vhd)
            for name in ("remap_runtime_auth_policy.hpp", "remap_runtime_identity.hpp"):
                (headers / name).write_bytes((BUILD / name).read_bytes())
            cpp, binary = root / "control.cpp", root / "control"
            cpp.write_text(CPP_CONTROLS[case])
            built = subprocess.run(
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
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            if case != "lower":
                self.assertIn('"native_darwin_executed":0', run.stdout)

    def test_genuine_canceled_timer_capture_blocks_reference_retirement(self):
        self.run_cpp("timer")

    def test_genuine_callback_capture_blocks_physical_close_until_destruction(self):
        self.run_cpp("callback")

    def test_actual_composed_lower_peer_request_manager_compile(self):
        self.run_cpp("lower")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    with tempfile.TemporaryDirectory(prefix="fixed-vhd-controls-") as directory:
        prepare_inputs(Path(directory), args.source_root.resolve(strict=True))
        unittest.main(argv=[str(Path(__file__)), *remaining])
