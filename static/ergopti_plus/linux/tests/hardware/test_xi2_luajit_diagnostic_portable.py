"""Source/receiver tests only; import never runs a compiler, LuaJIT or native server."""

import copy
import importlib.util
from pathlib import Path
import unittest


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("diagnostic", HERE / "run_xi2_luajit_diagnostic.py")
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class PortableControls(unittest.TestCase):
    def fact(self):
        return {
            "qualified": True,
            "stage": 4,
            "abi_comparisons": 29,
            "native_cases": 3,
            "cleanup": True,
            "input_injections": 0,
            "native_epoch_claim": False,
            "runtime_projection": "CONTROLLED",
            "cases": [
                {"phase": 0, "deviceid": 3, "property": 27, "what": 1},
                {"phase": 1, "deviceid": 3, "property": 27, "what": 2},
                {"phase": 2, "deviceid": 3, "property": 27, "what": 0},
            ],
        }

    def refuses(self, field, value):
        fact = self.fact()
        fact[field] = value
        with self.assertRaises(AssertionError):
            diagnostic.validate_native(fact)

    def test_closed_positive(self):
        diagnostic.validate_native(self.fact())

    def test_failed_case_count_does_not_promote(self):
        self.refuses("qualified", False)

    def test_native_cleanup_pending_does_not_promote(self):
        self.refuses("cleanup", False)

    def test_abi_omission_refuses(self):
        self.refuses("abi_comparisons", 28)

    def test_zero_native_cases_refuses(self):
        self.refuses("native_cases", 0)

    def test_native_epoch_grant_refuses(self):
        self.refuses("native_epoch_claim", True)

    def test_input_injection_refuses(self):
        self.refuses("input_injections", 1)

    def test_installed_runtime_claim_refuses(self):
        self.refuses("runtime_projection", "INSTALLED")

    def test_bool_as_integer_refuses(self):
        self.refuses("stage", True)

    def test_foreign_extra_fact_refuses(self):
        fact = self.fact()
        fact["provider_available"] = True
        with self.assertRaises(AssertionError):
            diagnostic.validate_native(fact)

    def test_wrong_property_refuses(self):
        fact = self.fact()
        fact["cases"][1]["property"] = 28
        with self.assertRaises(AssertionError):
            diagnostic.validate_native(fact)

    def test_repeat_phase_refuses(self):
        fact = self.fact()
        fact["cases"][2] = copy.deepcopy(fact["cases"][1])
        with self.assertRaises(AssertionError):
            diagnostic.validate_native(fact)

    def test_runtime_only_adds_private_xi(self):
        text = (HERE / "xi2_luajit_receiver.lua").read_text()
        self.assertIn("for key, value in pairs(original_runtime) do runtime[key] = value end", text)
        self.assertIn("runtime.xi = xi_path", text)
        self.assertNotIn("runtime.x11 =", text)
        self.assertNotIn("runtime.xkbcommon =", text)
        self.assertIn('local ffi = require("ffi")', text)
        self.assertNotIn("ffi = {", text)
        self.assertIn('package.loaded["logger.shim"] = assert(loadfile(logger_source))()', text)
        self.assertIn('driver .. "/?.lua;"', text)
        self.assertIn("output_print(string.format(", text)

    def test_original_c3_and_full_family_preserved(self):
        text = (HERE / "run_xi2_luajit_diagnostic.py").read_text()
        self.assertIn(
            'assert original.main() == 0, "original three C cases remain mandatory"', text
        )
        self.assertEqual(text.count("original.family_run("), 2)
        self.assertIn("module.digest(module.FAMILY) == FAMILY_SHA", text)

    def test_real_emission_original_candidate_and_retirement(self):
        text = (HERE / "xi2_luajit_receiver.lua").read_text()
        for fragment in [
            "local Probe = assert(loadfile(candidate))()",
            "Xi.XIChangeProperty(",
            "Xi.XIDeleteProperty(",
            "Probe.read(identity, groups)",
            "Probe.property_invalidation_view()",
            "ffi.offsetof(",
            "ffi.alignof(",
            "W.ep_xvfb_peers(server_pid, uid) == 2",
            "W.ep_xvfb_peers(server_pid, uid) == 0",
            "status == 0",
            'final_view.reason == "native-property-connection-retired"',
        ]:
            self.assertIn(fragment, text)
        for prohibited in [
            "XTest",
            "uinput",
            "collectgarbage(",
            "json.decode",
            "XGetEventData(control",
        ]:
            self.assertNotIn(prohibited, text)


if __name__ == "__main__":
    unittest.main()
