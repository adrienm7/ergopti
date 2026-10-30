"""Only a complete native locale enumeration may establish language availability."""

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


PROBE = r"""
local root, catalog, mode = arg[1], arg[2], arg[3]
package.path = root .. '/?.lua;' .. root .. '/?/init.lua;'
  .. root .. '/../_shared/lua/?.lua;' .. root .. '/../_shared/lua/?/init.lua;' .. package.path
require('compat.utf8').install()
local paths = require('infra.paths')
local original = paths.shared
paths.shared = function(name)
  if name == 'data/locales' then return catalog end
  return original(name)
end
local i18n = require('infra.i18n')
local ok, codes = pcall(i18n.list_locales)
local retained = false
local unavailable_refused = not ok and i18n.persist_locale('en') == false
local recovered = {}
if not ok and (mode == 'unreadable' or mode == 'empty') then
  -- One explicit call after repairing the known filesystem refusal proves
  -- failed initialization did not publish or permanently poison its cache.
  assert(require('luv').fs_chmod(catalog, 448))
  if mode == 'empty' then
    for _, code in ipairs({'en','fr','de'}) do
      local file = assert(io.open(catalog .. '/' .. code .. '.json', 'w'))
      assert(file:write('{}\n')); assert(file:close())
    end
  end
  recovered = i18n.list_locales()
end
if ok and mode == 'cached' then
  assert(require('luv').fs_chmod(catalog, 0))
  local again = i18n.list_locales()
  retained = rawequal(again, codes)
  assert(require('luv').fs_chmod(catalog, 448))
end
local selected, stored = false, nil
if ok and (mode == 'directory-entry' or mode == 'regular-link') then
  selected = i18n.persist_locale(mode == 'directory-entry' and 'zz' or 'ja')
  stored = require('adapters.storage').get('locale')
end
print('CATALOG_RESULT ' .. require('json').encode({
  ok=ok,codes=ok and codes or {},reason=ok and '' or tostring(codes),retained=retained,
  unavailable_refused=unavailable_refused,
  recovered=recovered,
  selected=selected,stored=stored,active=i18n.get_locale(),
}))
"""


class NativeLocaleCatalogTests(unittest.TestCase):
    def test_native_locale_catalog_authority(self):
        driver = Path(DRIVER).resolve()
        order = json.loads((driver.parent / "_shared/data/locale_order.json").read_text())["order"]
        expected = sorted(["en", "fr", "de"], key=lambda code: order.index(code))
        self.assertNotEqual(os.geteuid(), 0, "native permission refusal requires an ordinary user")
        for mode in (
            "healthy",
            "failed-ls",
            "literal-name",
            "directory-entry",
            "regular-link",
            "unreadable",
            "empty",
            "cached",
        ):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                catalog = root / "locales"
                catalog.mkdir()
                if mode != "empty":
                    for code in expected:
                        (catalog / (code + ".json")).write_text("{}\n", encoding="utf-8")
                    (catalog / "flags.json").write_text("{}\n", encoding="utf-8")
                    (catalog / "_internal.json").write_text("{}\n", encoding="utf-8")
                    if mode == "literal-name":
                        (catalog / "opaque\nzz.json").write_text("{}\n", encoding="utf-8")
                    elif mode == "directory-entry":
                        (catalog / "zz.json").mkdir()
                    elif mode == "regular-link":
                        target = root / "regular-ja.json"
                        target.write_text("{}\n", encoding="utf-8")
                        (catalog / "ja.json").symlink_to(target)
                binary = root / "bin"
                binary.mkdir()
                marker = root / "ls-launched"
                if mode == "failed-ls":
                    executable = binary / "ls"
                    executable.write_text(
                        "#!/bin/sh\nprintf called > "
                        + shlex.quote(str(marker))
                        + "\nprintf 'en.json\\n'\nexit 73\n",
                        encoding="utf-8",
                    )
                    executable.chmod(0o700)
                    witness = subprocess.run(
                        [str(executable)], capture_output=True, text=True, timeout=5
                    )
                    self.assertEqual(witness.returncode, 73)
                    self.assertEqual(witness.stdout, "en.json\n")
                    marker.unlink()
                environment = dict(
                    os.environ,
                    PATH=str(binary) + os.pathsep + os.defpath,
                    HOME=str(root),
                    XDG_CONFIG_HOME=str(root),
                    XDG_STATE_HOME=str(root),
                    XDG_DATA_HOME=str(root),
                    XDG_CACHE_HOME=str(root),
                    XDG_RUNTIME_DIR=str(root),
                )
                script = root / "probe.lua"
                script.write_text(PROBE, encoding="utf-8")
                if mode == "unreadable":
                    catalog.chmod(0)
                try:
                    result = subprocess.run(
                        [RUNTIME, str(script), str(driver), str(catalog), mode],
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                finally:
                    catalog.chmod(0o700)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                lines = [
                    line.removeprefix("CATALOG_RESULT ")
                    for line in result.stdout.splitlines()
                    if line.startswith("CATALOG_RESULT ")
                ]
                self.assertEqual(len(lines), 1, result.stdout)
                receipt = json.loads(lines[0])
                print(
                    "Native locale catalog receipt: " + json.dumps(dict(mode=mode, **receipt)),
                    flush=True,
                )
                if mode in ("unreadable", "empty"):
                    self.assertFalse(
                        receipt["ok"], "unobserved language availability must never be invented"
                    )
                    self.assertTrue(receipt["reason"])
                    self.assertTrue(
                        receipt["unavailable_refused"],
                        "refused discovery cannot leave a phantom accepted locale",
                    )
                    self.assertEqual(
                        receipt["recovered"],
                        expected,
                        "one explicit admission after repair must remain possible",
                    )
                    if mode == "unreadable":
                        self.assertIn("EACCES", receipt["reason"])
                else:
                    self.assertTrue(receipt["ok"], receipt["reason"])
                    available = sorted(
                        expected + (["ja"] if mode == "regular-link" else []),
                        key=lambda code: order.index(code),
                    )
                    self.assertEqual(
                        receipt["codes"],
                        available,
                        "complete native availability must preserve canonical order",
                    )
                    if mode == "failed-ls":
                        self.assertFalse(
                            marker.exists(), "locale enumeration must not launch a shell listing"
                        )
                    if mode == "cached":
                        self.assertTrue(
                            receipt["retained"], "a prior admitted catalog remains authoritative"
                        )
                    elif mode == "directory-entry":
                        self.assertFalse(
                            receipt["selected"],
                            "a directory cannot grant locale selection authority",
                        )
                        self.assertIsNone(
                            receipt.get("stored"), "an unavailable locale must never be persisted"
                        )
                    elif mode == "regular-link":
                        self.assertTrue(
                            receipt["selected"],
                            "a regular-file symlink remains a legitimate locale",
                        )
                        self.assertEqual(receipt["stored"], "ja")
                        self.assertEqual(receipt["active"], "ja")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--driver", required=True)
    options, remaining = parser.parse_known_args()
    RUNTIME, DRIVER = options.runtime, options.driver
    unittest.main(argv=[__file__, *remaining])
