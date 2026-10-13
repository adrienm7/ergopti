<!-- tools/diagnostics/fixtures/installed_sdk/README.md -->

# Installed SDK software controls

The four snapshots preserve the exact retained sources used by the original
CLI, HID stop and HID startup inverse controls. `provenance.json` records their
hashes, sizes and origin. The `.txt` suffix keeps formatters from rewriting those
preimages. Never regenerate them from the corrected implementation.

The receiver authenticates the existing source factory and all SDK dependencies,
admits the pristine upstream Git inventory and revalidates that source epoch
before and after each actor. It also compares the CLI snapshot with the genuine
legacy factory output. These tests compile actual generated dispatch or actual
manager/monitor source ranges with genuine vendor headers. Capture and IOKit
ports are finite models; passing them does not qualify native capture, hardware,
installation, packaged binaries or signing.

Run from the repository root, with the genuine pinned upstream source checkout
and a compiler/runtime supporting Clang Blocks:

```bash
python3 -B tools/diagnostics/run_installed_sdk_software_controls.py \
    --repository "$PWD" \
    --pristine "$ERGOPTI_PRISTINE_SOURCE" \
    --compiler "$ERGOPTI_BLOCKS_COMPILER" \
    --blocks-library "$ERGOPTI_BLOCKS_LIBRARY"
```

The original factory admits upstream `9312593e1a3bf72b94c63c524ebabe2637442e8a`
and its exact CPM/VirtualHIDDevice submodule inventories. A source directory or
vendor header path alone cannot grant admission. The compiler and Blocks library
must remain unchanged throughout receiving. The actors retain their original
60-second compilation and 10-second executable limits; the receiver retains an
absolute 300-second source-operation deadline. Its expected counts are CLI 8,
HID stop 6 and HID startup 8, with no skipped controls. `--suite cli`,
`--suite hid-stop` and `--suite hid-startup` select the corresponding original
actor without changing its assertions.

On macOS, run the same software worker through the original process guardian:

```bash
python3 -B tools/diagnostics/macos_owned_process.py run \
    "$ERGOPTI_PRIVATE_RECEIPT_DIR/installed-sdk-software.json" 330 -- \
    python3 -B tools/diagnostics/run_installed_sdk_software_controls.py \
        --repository "$PWD" \
        --pristine "$ERGOPTI_PRISTINE_SOURCE" \
        --compiler "$ERGOPTI_BLOCKS_COMPILER" \
        --blocks-library "$ERGOPTI_BLOCKS_LIBRARY"
```

The receipt directory must already have mode `0700`; the destination must be
absent. The guardian preserves its original process-group retirement and
refusal contract. Direct execution on Linux receives only the finite software
controls and makes no macOS native process-group qualification claim.

This software receiver is separate from `tools/build/core_sdk/run_core_sdk.py`,
which requires actual Darwin ARM or Intel build and native acceptance. Neither
runner enables boot, installs a driver, updates an existing profile or resolves
the stock Karabiner lease incident.
