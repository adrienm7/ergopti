"""Negative source and packaging admission controls; no native or signed grant."""

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import time
import unittest

import owned_runtime_product_build as product
import remap_runtime_source as source


class ResourceSourceRefusalControls(unittest.TestCase):
    def test_detached_image_cannot_select_vendor_resources(self):
        with self.assertRaises(source.SourceRefusal):
            source.capture_virtual_hid_driver_payload(object(), time.monotonic() + 10)

    def test_resource_bytes_alone_cannot_replace_factory_payload(self):
        with self.assertRaises(source.SourceRefusal):
            source.current_virtual_hid_driver_payload(
                SimpleNamespace(image=object(), resources=()), time.monotonic() + 10
            )

    def test_factory_record_with_detached_image_still_refuses(self):
        # The public immutable record does not itself mint source ownership.
        payload = source.StagedVirtualHIDDriverPayload(object(), (), ())
        with self.assertRaises(source.SourceRefusal):
            source.current_virtual_hid_driver_payload(payload, time.monotonic() + 10)

    def test_sdk_metadata_without_original_payload_refuses_before_native_compile(self):
        record = {
            "schema": 3,
            "source_factory_sha256": product.CURRENT_SOURCE_FACTORY_SHA256,
            "source_profile": "owned_installed_sdk_source_v1",
            "sdk_supplier_sha256": product.SDK_SOURCE_SUPPLIER_SHA256,
        }
        with (
            patch.object(product.sys, "platform", "darwin"),
            patch.object(product, "compile_native_parts") as compile_parts,
        ):
            with self.assertRaises(product.ProductBuildRefusal):
                product._package_live(
                    Path("/finite"),
                    Path("/finite"),
                    Path("/finite"),
                    record,
                    {},
                    {},
                    b"not a native certificate",
                    "A" * 40,
                    Path("/finite"),
                    lambda: None,
                    time.monotonic() + 10,
                    source_current=lambda: None,
                )
            compile_parts.assert_not_called()

    def test_legacy_metadata_cannot_import_sdk_resource_authority(self):
        record = {"source_factory_sha256": product.CORE_IDLE_FACTORY_SHA256}
        with (
            patch.object(product.sys, "platform", "darwin"),
            patch.object(product, "compile_native_parts") as compile_parts,
        ):
            with self.assertRaises(product.ProductBuildRefusal):
                product._package_live(
                    Path("/finite"),
                    Path("/finite"),
                    Path("/finite"),
                    record,
                    {},
                    {},
                    b"not a native certificate",
                    "A" * 40,
                    Path("/finite"),
                    lambda: None,
                    time.monotonic() + 10,
                    staged_source=object(),
                )
            compile_parts.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
