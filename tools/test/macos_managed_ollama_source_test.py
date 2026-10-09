#!/usr/bin/env python3
# tools/test/macos_managed_ollama_source_test.py
"""Receive the native Ollama hooks against independently pinned upstream files."""

import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
UPSTREAM = None
# These vectors were frozen from the reviewed upstream commit, before applying
# any product hook. They must not be regenerated from patched candidate files.
FROZEN = {
    "server/download.go": "14ffbdd4c503e7c0fb314e221d6f430a90ad745e910fa601e6b543e4c6a00699",
    "server/routes.go": "2621eef9e33b370d97a460eef80466654e4319ffea5ec0b94b3dbd79d5effd5e",
    "server/images.go": "517e83b75fa014fc3a3a9d23c316f71e10228e8d2f0c92323c627eb45e8d3887",
    "server/internal/client/ollama/registry.go": "6063de52240e9857334f8af210f71a3073b0b2bb8fac35c8df8b97494edf91c0",
    "x/transfer/download.go": "4cc3da8d3cbeac187eea3bd89dcc10a191fc3d8de53a7c5c5074ba30243be21a",
    "go.mod": "a6b997b339c1de4fcdaaa2e3266d3494863e391e429496973b7da5f05aa898db",
    "go.sum": "27f221ed12b312246074ac797952d26151b1b10f0e2731e3a42445665b950568",
    "auth/auth.go": "ac4c269cb812edc01e2386fce0a7753871851edf76ec46ad26329016dc6f7841",
}
SPEC = importlib.util.spec_from_file_location(
    "producer", REPOSITORY / "tools/build/build-macos-managed-ollama.py"
)
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)


class Hooks(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="managed-ollama-hooks-")
        self.addCleanup(self.owner.cleanup)
        self.candidate = Path(self.owner.name)
        for relative, frozen in FROZEN.items():
            original = UPSTREAM / relative
            self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), frozen)
            destination = self.candidate / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, destination)

    def test_source_hooks_preserve_origin_auth_and_original_redirect_owner(self):
        PRODUCER.apply_hooks(self.candidate, REPOSITORY)
        images = (self.candidate / "server/images.go").read_text()
        self.assertLess(
            images.index('req.Header.Set("Authorization", "Bearer "+regOpts.Token)'),
            images.index("nativehttp.Wrap(c.Transport)"),
        )
        self.assertLess(
            images.index("CheckRedirect: regOpts.CheckRedirect"),
            images.index("nativehttp.Wrap(c.Transport)"),
        )
        self.assertIn("req.Method == http.MethodGet || req.Method == http.MethodHead", images)
        registry = (self.candidate / "server/internal/client/ollama/registry.go").read_text()
        self.assertIn("cc := *c\n\t\tcc.Transport = nativehttp.Wrap(c.Transport)", registry)
        transfer = (self.candidate / "x/transfer/download.go").read_text()
        self.assertIn("client := *cmp.Or(opts.Client, defaultClient)", transfer)
        self.assertIn("client:       &client", transfer)
        for relative in ("auth/auth.go", "go.mod", "go.sum"):
            self.assertEqual(
                (self.candidate / relative).read_bytes(), (UPSTREAM / relative).read_bytes()
            )
        routes = (self.candidate / "server/routes.go").read_text()
        self.assertEqual(
            routes.count(
                'r.GET("/api/ergopti-native-http-admission", gin.WrapH(nativehttp.AdmissionHandler()))'
            ),
            1,
        )
        self.assertIn('r.GET("/api/status", s.StatusHandler)', routes)
        self.assertIn("defer finishNativePull()", routes)
        self.assertIn("case <-ctx.Done():", routes)
        download = (self.candidate / "server/download.go").read_text()
        self.assertIn("retireNativeDownload := nativehttp.TrackBackgroundDownload()", download)
        self.assertIn("defer retireNativeDownload()", download)

    def test_changed_preimages_refuse_before_any_source_edit(self):
        path = self.candidate / "x/transfer/download.go"
        path.write_bytes(path.read_bytes() + b"\n// Independent unexpected upstream edit.\n")
        before = {relative: (self.candidate / relative).read_bytes() for relative in FROZEN}
        with self.assertRaisesRegex(ValueError, "preimage changed"):
            PRODUCER.apply_hooks(self.candidate, REPOSITORY)
        self.assertEqual(
            before, {relative: (self.candidate / relative).read_bytes() for relative in FROZEN}
        )
        self.assertFalse((self.candidate / "internal/ergoptinativehttp").exists())

    def test_duplicate_seam_and_second_publication_refuse(self):
        with self.assertRaises(ValueError):
            PRODUCER.replace_once("request\nrequest\n", "request\n", "changed\n")
        PRODUCER.apply_hooks(self.candidate, REPOSITORY)
        with self.assertRaisesRegex(ValueError, "preimage changed"):
            PRODUCER.apply_hooks(self.candidate, REPOSITORY)

    def test_all_owned_bridge_sources_join_actual_upstream_module(self):
        PRODUCER.apply_hooks(self.candidate, REPOSITORY)
        package = self.candidate / "internal/ergoptinativehttp"
        self.assertEqual(
            sorted(path.name for path in package.iterdir()),
            ["admission.go", "transport.go", "worker_darwin.go", "worker_other.go"],
        )
        for path in package.iterdir():
            self.assertEqual(
                path.read_bytes(),
                (
                    REPOSITORY / "static/ergopti_plus/_shared/go/native_http" / path.name
                ).read_bytes(),
            )
        probe = (self.candidate / "ergopti_native_http_capability.go").read_text()
        self.assertIn(
            'len(os.Args) == 2 && os.Args[1] == "--ergopti-native-http-capability"', probe
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    options, remaining = parser.parse_known_args()
    UPSTREAM = options.source.resolve(strict=True)
    unittest.main(argv=[__file__, *remaining])
