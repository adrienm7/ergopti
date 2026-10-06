# tools/diagnostics/hs274_promoted_source_witness_test.py
"""Independent closed source-witness controls; native compilation remains separate."""

from pathlib import Path
import base64
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE_DIAGNOSTICS = Path(__file__).resolve().parent
SOURCE_REPOSITORY = SOURCE_DIAGNOSTICS.parents[1]
ROOT = SOURCE_DIAGNOSTICS


def fixed_fixture(encoded, expected_sha256):
    """Decode only immutable independently frozen fixture data."""
    data = base64.b64decode(encoded, validate=True)
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise RuntimeError("Independent witness fixture identity changed")
    return data


EXPECTED_BYTES = fixed_fixture(
    (
        "ewogICJoczI3NC1iYXNlbGluZS12Mi10ZXN0LmNwcCI6ICI4YTg1YjNmNGRhYWNiZTFkNTc3OWVi"
        "NzA0YmEwNDhiYTRlNjUzNGRlMDY3OTAwMzZjOGYzODUwMzdkMDk5MjU1IiwKICAiaHMyNzQta2V5"
        "LWVsZW1lbnQtdGVzdC5jcHAiOiAiZTE3MTdkYWFmZTY0NzIxNTBhN2Y4OTFiODM3OGE5YjMxNjAy"
        "OTJiOGRmOTY1MWRhNWMwMzU0MTE2YmU4ZTFjZiIsCiAgImhzMjc0LWtleS1zdGF0ZS10ZXN0LmNw"
        "cCI6ICJmZDdiMTUwNTY3NTk0YjQzNWRkNWYyMzBlNmQ5M2MyM2MxYmU2NWQ3MzFjOGY1Y2YwODQ2"
        "OWE3ZjMzODc3MTc1IiwKICAiaHMyNzQta2V5LXN0YXRlLmhwcCI6ICI5MTMzMzk1YjhkNTNhZDc1"
        "ZjJiYjhkM2FmMjhiODQ4ZDk1NTQxYzU5ODg1NzEyNzNhNzcyMTY4YjllZmQ1MTk2IiwKICAiaHMy"
        "NzQtbmF0aXZlLWFjcXVpc2l0aW9uLXRlc3QuY3BwIjogIjJiNDY1Y2YwNzVkOWNiNDA2NmJmODkz"
        "ZDBhNTQ0ZjJhMWY0MTc1YTAwODVkNjJmYTRmODBkZGM4ODg0MzE1MTciLAogICJoczI3NC1uYXRp"
        "dmUtYnV0dG9uLXF1YWxpZmljYXRpb24tdGVzdC5jcHAiOiAiYmFiNjVhZjhkMmVmMmExZTJlZWM2"
        "MmRkMWQ3M2VmNDIyODAxZTU5OTUxN2NmYmVjZjliODNiNDVlOWE4MDUwOSIsCiAgImhzMjc0LW5h"
        "dGl2ZS1jYXBhY2l0eS10ZXN0LmNwcCI6ICI1OTVjMzliYTY1ODViNzg1ZGVkMzgwZjYxZTk3MzBi"
        "MGU0OWQ0NWZiMTcxZTU3Y2VlZjJmOGRkMDJiOTYxNzllIiwKICAiaHMyNzQtbmF0aXZlLWZlbmNl"
        "LXRlc3QuY3BwIjogImU2MDE4OTIyNjYzYzFkODFiM2M2Zjg3YjZlNTZkYTFhYmRmNzhkOGE0YTlm"
        "NTU1MDIzNTg4NTZjNDAzNWI1NWUiLAogICJoczI3NC1uYXRpdmUtbGl2ZW5lc3MtdGVzdC5jcHAi"
        "OiAiOTZkOTFhMjM0YTNjMDg2Njc0Y2I3MmNmMjFkYWI1MDFjZjJhNTlkMDZjNGY1NWQwMDgwMzEw"
        "NjdhZmQxZGI5NSIsCiAgImhzMjc0LW5hdGl2ZS1yZWZ1c2FsLXRlc3QuY3BwIjogIjgxOGY2NjFi"
        "NWRjODlhOTk5ZTdjMjU4NjJiZjQ0OTI1MjBiMzIzYjQ0ZTY5YTAxNGNjNDM1ZDhmYmZiZWZjMmIi"
        "LAogICJoczI3NC1uYXRpdmUtc3RhdHVzLXRlc3QuY3BwIjogIjQ4MjlmNThhZmMzMGRmODc2MjEz"
        "YTI2N2VjNWU3YzA3ODcxNzc5MTdjYmFlODMyOWI2MjgyZWQzZmRkMmJiM2IiLAogICJoczI3NC1z"
        "dHJlYW0tYmFzZWxpbmUtY2xpZW50LmhwcCI6ICJmOWExMTNkMWU1MTE5OGFmNTViZTU4ZTI3ZDc3"
        "MWU4NzA5MTMwYWU3ZjU5NDkxZTRmODNjNzlhMTFlMGI4NTFmIiwKICAiaHMyNzQtc3RyZWFtLWJh"
        "c2VsaW5lLXBhZ2VzLmhwcCI6ICI1ZGEyMTg4NzI3NjlkZTdiMWEzNDBlMDkxYzRjMjk5N2NkMDZm"
        "MDg1ZDQ5OWU0M2NmNmYxNDY5ZjVhOGM2ZTYwIiwKICAiaHMyNzQtc3RyZWFtLWJhc2VsaW5lLXBy"
        "b2JlLmhwcCI6ICI5NzFhZmU3Y2VjOTRhY2JmN2FlYzk1MWE2Y2JlMGNjMTJmZWIwY2RjZWQ0YjQ4"
        "NDM1NTM3MDJjMjIyZDM4ZTRmIiwKICAiaHMyNzQtc3RyZWFtLWludmVudG9yeS10ZXN0LmNwcCI6"
        "ICIxNTQ0MDE4MzZlNjFlNTI0ZTIxYWMyZWRjNWU1MDJkMDkxZGE5M2NlNzVmZDAxMTM3ZTcwN2I2"
        "YzgzMTgxNDVkIiwKICAiaHMyNzQtc3RyZWFtLWludmVudG9yeS5ocHAiOiAiMzY3ZTYxYTBkZGYz"
        "MDk5YWYwNmU4NmRkNDI2NDQ2ZDc4MTJkMzk3YjU2NWViNGE2ZGE5ZDdlMDY1OTJlMWUxOCIsCiAg"
        "ImhzMjc0LXN0cmVhbS1uYXRpdmUtYm91bmRhcnkuaHBwIjogImEzZjRlMzE4OGM0NTRhZWIzMTY2"
        "NjljMGJmNjY1YjE2ODY5ZTkzYTE1Y2I5NzBhMjc4ODQ3Y2UyOGUxZjVkMjEiLAogICJoczI3NC1z"
        "dHJlYW0tbmF0aXZlLWZhdWx0LmhwcCI6ICIwMDg1NGJkNjdmYTE2NjU3MGIzMjc1MmU3NWU1ZmU0"
        "YjFkMjA5OWJiOWE3ZjZlZTk4YzcwZjdmMmRhMzEzZTllIiwKICAiaHMyNzQtc3RyZWFtLXJlYWRp"
        "bmVzcy5ocHAiOiAiNmM2Y2FjMjFiNTQ1MzhlNDIxYzZhMjVkZmJlOWYzMWMzYTU1MjQzMmVlZDZh"
        "OThhMjhhYjAyZjE3Mjc2MDRkOCIsCiAgImhzMjc0LXN0cmVhbS1yZXRyeS10ZXN0LmNwcCI6ICJh"
        "NmIwZTUzODlhNjliODk0N2RiZjlmOTdiNThiN2VlYmY1M2MzMTRmZmFjNWY1OTU2YzFiN2Q2NTQ1"
        "MTI5MjA0IiwKICAiaHMyNzQtc3RyZWFtLXJ1bnRpbWUuaHBwIjogImM4MGQyODBkZjA0ZGFjZDEx"
        "NDM1NTZjZWQ3ZDBiMmFiMTQ5OGEzYzYxZGYzYWFmOTA3MzZiNmM1MjNlNzhjMmIiLAogICJoczI3"
        "NC1zdHJlYW0tc291cmNlLXRlc3QuY3BwIjogImE3NzAxNzQxMzhkZDU2NmRiYzY2ZDA3MzU3N2Fl"
        "YmZlMTNhN2JmYTMzMmNlMjRhMGM2Mjg1OTRkOGFiMWU1NDMiLAogICJoczI3NC1zdHJlYW0tc291"
        "cmNlLmhwcCI6ICI2N2IxNDRmMTYwNGZlNTM2NDkxNjIyMTA4MDVkMTk2NDE2NjM5NzRmNzRlNjQz"
        "ODEyYTc0ZTBmYzUxZmI3MWExIiwKICAiaHMyNzRfcmF3X3BhdGNoLnB5IjogIjUyMjAyZTk5MWFk"
        "MTJlMGFhZTU4MDZlY2IwOTNjNDAxODMxODUxN2M4ZjA3ZDc3NGVmM2Q0ZTczMGYyMTg0MjMiLAog"
        "ICJoczI3NF9zdHJlYW1fcGF0Y2gucHkiOiAiN2RmNDg1ZmMwY2JjYjZiYjE2YjNlOGQzZDY3ZWJh"
        "Y2ViYzBkYTliMDg0MGFiZTdiMzA4YmI0NWZiODA5MDExYiIKfQo="
    ),
    "51c60efb88d71a0175ad60f8c38326e166203f04612d1cc5a014611cadb9ced7",
)

PRIOR_RAW_BYTES = fixed_fixture(
    (
        "IyB0b29scy9kaWFnbm9zdGljcy9oczI3NF9yYXdfcGF0Y2gucHkKIiIiSW5zdHJ1bWVudCBvbmx5"
        "IHRoZSBwaW5uZWQgZGlzcG9zYWJsZSBLYXJhYmluZXIgY2hlY2tvdXQgZm9yIGEgZmluaXRlIGNh"
        "cHR1cmUuIiIiCgpmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKaW1wb3J0IGFyZ3BhcnNlCmltcG9y"
        "dCBzdWJwcm9jZXNzCgpSRVZJU0lPTiA9ICI5MzEyNTkzZTFhM2JmNzJiOTRjNjNjNTI0ZWJhYmUy"
        "NjM3NDQyZThhIgoKCmRlZiByZXBsYWNlX29uY2Uoc291cmNlLCBiZWZvcmUsIGFmdGVyKToKICAg"
        "ICIiIlJlZnVzZSB1cHN0cmVhbSBkcmlmdCBvciBkdXBsaWNhdGUgYW5jaG9ycyBiZWZvcmUgcHJv"
        "ZHVjaW5nIGEgcGF0Y2guIiIiCiAgICBpZiBzb3VyY2UuY291bnQoYmVmb3JlKSAhPSAxOgogICAg"
        "ICAgIHJhaXNlIFJ1bnRpbWVFcnJvcihmIkV4cGVjdGVkIG9uZSB1cHN0cmVhbSBhbmNob3I6IHti"
        "ZWZvcmUhcn0iKQogICAgcmV0dXJuIHNvdXJjZS5yZXBsYWNlKGJlZm9yZSwgYWZ0ZXIsIDEpCgoK"
        "ZGVmIGluc3RydW1lbnRfbW9uaXRvcihzb3VyY2UpOgogICAgIiIiQ2FwdHVyZSBvbmx5IHRoZSBy"
        "ZW5hbWVkIG93bmVkIGRldmljZSBiZWZvcmUgdGltZXN0YW1wIG5vcm1hbGl6YXRpb24uIiIiCiAg"
        "ICBzb3VyY2UgPSByZXBsYWNlX29uY2UoCiAgICAgICAgc291cmNlLCAiI3ByYWdtYSBvbmNlXG4i"
        "LCAnI3ByYWdtYSBvbmNlXG5cbiNpbmNsdWRlICJoczI3NC1yYXctY2FwdHVyZS5ocHAiXG4nCiAg"
        "ICApCiAgICBzb3VyY2UgPSByZXBsYWNlX29uY2UoCiAgICAgICAgc291cmNlLAogICAgICAgICIg"
        "ICAgICAgIGxhc3RfdGltZV9zdGFtcF8oMCkgeyIsCiAgICAgICAgIiIiICAgICAgICBoczI3NF9w"
        "cm9iZV9kZXZpY2VfaWRfKHR5cGVfc2FmZTo6Z2V0KGRldmljZV9wcm9wZXJ0aWVzLmdldF9kZXZp"
        "Y2VfaWQoKSkpLAogICAgICAgIGhzMjc0X3Byb2JlX293bmVkXyh0eXBlX3NhZmU6OmdldChkZXZp"
        "Y2VfcHJvcGVydGllcy5nZXRfcHJvZHVjdCgpKSA9PSAiSFMyNzQgQ0kgS2V5Ym9hcmQiKSwKICAg"
        "ICAgICBsYXN0X3RpbWVfc3RhbXBfKDApIHsiIiIsCiAgICApCiAgICBzb3VyY2UgPSByZXBsYWNl"
        "X29uY2UoCiAgICAgICAgc291cmNlLAogICAgICAgICIgICAgICBpbnB1dF92YWx1ZXNfYXJyaXZl"
        "ZChoaWRfdmFsdWVzKTtcbiAgICB9KTsiLAogICAgICAgICIiIiAgICAgIGlmIChoczI3NF9wcm9i"
        "ZV9vd25lZF8pIHsKICAgICAgICBmb3IgKHN0ZDo6c2l6ZV90IGluZGV4ID0gMDsgaW5kZXggPCBo"
        "aWRfdmFsdWVzLT5zaXplKCk7ICsraW5kZXgpIHsKICAgICAgICAgIGNvbnN0IGF1dG8mIHZhbHVl"
        "ID0gaGlkX3ZhbHVlcy0+YXQoaW5kZXgpOwogICAgICAgICAgLy8gVGhlIHdyYXBwZXIgZHJvcHMg"
        "ZWxlbWVudCBpZGVudGl0eTsgdXNlIHRoZSBjb3JyZXNwb25kaW5nIG5hdGl2ZSB2YWx1ZS4KICAg"
        "ICAgICAgIGNvbnN0IGF1dG8gY29va2llID0gSU9ISURFbGVtZW50R2V0Q29va2llKElPSElEVmFs"
        "dWVHZXRFbGVtZW50KCp2YWx1ZXMtPmF0KGluZGV4KSkpOwogICAgICAgICAgY29uc3QgYXV0byBw"
        "YWdlID0gdmFsdWUuZ2V0X3VzYWdlX3BhZ2UoKTsKICAgICAgICAgIGNvbnN0IGF1dG8gdXNhZ2Ug"
        "PSB2YWx1ZS5nZXRfdXNhZ2UoKTsKICAgICAgICAgIGhzMjc0X3Jhd19jYXB0dXJlOjpmaXh0dXJl"
        "LmFwcGVuZCh7CiAgICAgICAgICAgICAgaHMyNzRfcHJvYmVfZGV2aWNlX2lkXywgdHlwZV9zYWZl"
        "OjpnZXQodmFsdWUuZ2V0X3RpbWVfc3RhbXAoKSksCiAgICAgICAgICAgICAgdmFsdWUuZ2V0X2lu"
        "dGVnZXJfdmFsdWUoKSwgcGFnZS5oYXNfdmFsdWUoKSwgdXNhZ2UuaGFzX3ZhbHVlKCksCiAgICAg"
        "ICAgICAgICAgcGFnZSA/IHN0YXRpY19jYXN0PHN0ZDo6aW50MzJfdD4odHlwZV9zYWZlOjpnZXQo"
        "KnBhZ2UpKSA6IDAsCiAgICAgICAgICAgICAgdXNhZ2UgPyBzdGF0aWNfY2FzdDxzdGQ6OmludDMy"
        "X3Q+KHR5cGVfc2FmZTo6Z2V0KCp1c2FnZSkpIDogMCwKICAgICAgICAgICAgICAwLCB0cnVlLCBz"
        "dGF0aWNfY2FzdDxzdGQ6OnVpbnQzMl90Pihjb29raWUpfSk7CiAgICAgICAgfQogICAgICB9CiAg"
        "ICAgIGlucHV0X3ZhbHVlc19hcnJpdmVkKGhpZF92YWx1ZXMpOwogICAgfSk7IiIiLAogICAgKQog"
        "ICAgcmV0dXJuIHJlcGxhY2Vfb25jZSgKICAgICAgICBzb3VyY2UsCiAgICAgICAgIiAgcHFyczo6"
        "b3N4OjpjaHJvbm86OmFic29sdXRlX3RpbWVfcG9pbnQgbGFzdF90aW1lX3N0YW1wXzsiLAogICAg"
        "ICAgICIiIiAgc3RkOjp1aW50NjRfdCBoczI3NF9wcm9iZV9kZXZpY2VfaWRfOwogIGJvb2wgaHMy"
        "NzRfcHJvYmVfb3duZWRfOwogIHBxcnM6Om9zeDo6Y2hyb25vOjphYnNvbHV0ZV90aW1lX3BvaW50"
        "IGxhc3RfdGltZV9zdGFtcF87IiIiLAogICAgKQoKCmRlZiBpbnN0cnVtZW50X3NodXRkb3duKHNv"
        "dXJjZSk6CiAgICAiIiJQdWJsaXNoIGEgZmluaXRlIGNvbW1pdHRlZC1wcmVmaXggc25hcHNob3Qg"
        "b3V0c2lkZSBpbnB1dCBjYWxsYmFja3MuIiIiCiAgICBzb3VyY2UgPSByZXBsYWNlX29uY2UoCiAg"
        "ICAgICAgc291cmNlLCAiI3ByYWdtYSBvbmNlXG4iLCAnI3ByYWdtYSBvbmNlXG5cbiNpbmNsdWRl"
        "ICJoczI3NC1yYXctY2FwdHVyZS5ocHAiXG4nCiAgICApCiAgICByZXR1cm4gcmVwbGFjZV9vbmNl"
        "KAogICAgICAgIHNvdXJjZSwgIiAgcmV0dXJuIDA7IiwgIiAgcmV0dXJuIGhzMjc0X3Jhd19jYXB0"
        "dXJlOjpmaW5pc2goKSA/IDAgOiAxOyIKICAgICkKCgpkZWYgbWFpbihyb290LCBzdHJlYW09RmFs"
        "c2UpOgogICAgIiIiUHJlZmxpZ2h0IGV2ZXJ5IG93bmVkIHRhcmdldCBiZWZvcmUgd3JpdGluZyBh"
        "bnkgaW5zdHJ1bWVudGF0aW9uLiIiIgogICAgcm9vdCA9IHJvb3QucmVzb2x2ZSgpCiAgICByZXZp"
        "c2lvbiA9IHN1YnByb2Nlc3MuY2hlY2tfb3V0cHV0KAogICAgICAgIFsiZ2l0IiwgIi1DIiwgc3Ry"
        "KHJvb3QpLCAicmV2LXBhcnNlIiwgIkhFQUQiXSwgdGV4dD1UcnVlCiAgICApLnN0cmlwKCkKICAg"
        "IGlmIHJldmlzaW9uICE9IFJFVklTSU9OOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigiUmF3"
        "IGNhcHR1cmUgcmVxdWlyZXMgdGhlIGluc3BlY3RlZCB1cHN0cmVhbSByZXZpc2lvbiIpCiAgICBo"
        "ZWFkZXJzID0gWyJoczI3NC1yYXctY2FwdHVyZS5ocHAiXQogICAgdHJhbnNmb3JtcyA9IFsKICAg"
        "ICAgICAoInNyYy9zaGFyZS9oaWRfZGV2aWNlX2V2ZW50c19tb25pdG9yLmhwcCIsIGluc3RydW1l"
        "bnRfbW9uaXRvciksCiAgICAgICAgKAogICAgICAgICAgICAic3JjL2FwcHMvQ29yZVNlcnZpY2Uv"
        "aW5jbHVkZS9jb3JlX3NlcnZpY2UvbWFpbi9kYWVtb24uaHBwIiwKICAgICAgICAgICAgaW5zdHJ1"
        "bWVudF9zaHV0ZG93biwKICAgICAgICApLAogICAgXQogICAgaWYgc3RyZWFtOgogICAgICAgIGZy"
        "b20gaHMyNzRfc3RyZWFtX3BhdGNoIGltcG9ydCAoCiAgICAgICAgICAgIHN0cmVhbV9tb25pdG9y"
        "LAogICAgICAgICAgICBzdHJlYW1fb3BlcmF0aW9ucywKICAgICAgICAgICAgc3RyZWFtX3JlY2Vp"
        "dmVyLAogICAgICAgICAgICBzdHJlYW1fY2xpZW50LAogICAgICAgICAgICBzdHJlYW1fY2xpLAog"
        "ICAgICAgICAgICBzdHJlYW1fc2VydmVyLAogICAgICAgICAgICBzdHJlYW1fZW50cnksCiAgICAg"
        "ICAgICAgIHN0cmVhbV9zb2NrZXRfb3BzLAogICAgICAgICkKCiAgICAgICAgaGVhZGVycyArPSBb"
        "CiAgICAgICAgICAgICJoczI3NC1zdHJlYW0tY2xvY2suaHBwIiwKICAgICAgICAgICAgImhzMjc0"
        "LXN0cmVhbS1zZXNzaW9uLmhwcCIsCiAgICAgICAgICAgICJoczI3NC1zdHJlYW0tcHJvdG9jb2wu"
        "aHBwIiwKICAgICAgICAgICAgImhzMjc0LXN0cmVhbS1hY2suaHBwIiwKICAgICAgICAgICAgImhz"
        "Mjc0LXN0cmVhbS1iYXNlbGluZS1wcm9iZS5ocHAiLAogICAgICAgICAgICAiaHMyNzQta2V5LWVs"
        "ZW1lbnQuaHBwIiwKICAgICAgICAgICAgImhzMjc0LXN0cmVhbS1rZXktcG9saWN5LmhwcCIsCiAg"
        "ICAgICAgICAgICJoczI3NC1zdHJlYW0tbmF0aXZlLWNvbnRyb2wuaHBwIiwKICAgICAgICAgICAg"
        "ImhzMjc0LXN0cmVhbS1uYXRpdmUtZmF1bHQuaHBwIiwKICAgICAgICAgICAgImhzMjc0LXN0cmVh"
        "bS1uYXRpdmUtYm91bmRhcnkuaHBwIiwKICAgICAgICAgICAgImhzMjc0LXN0cmVhbS1uYXRpdmUt"
        "YmluZGluZy5ocHAiLAogICAgICAgICAgICAiaHMyNzQta2V5Ym9hcmQtdHlwZS1vYnNlcnZhdGlv"
        "bi5ocHAiLAogICAgICAgICAgICAiaHMyNzQtb2JzZXJ2YXRpb24tY29udHJvbC5ocHAiLAogICAg"
        "ICAgICAgICAiaHMyNzQtc3RyZWFtLWludmVudG9yeS5ocHAiLAogICAgICAgICAgICAiaHMyNzQt"
        "a2V5LXN0YXRlLmhwcCIsCiAgICAgICAgICAgICJoczI3NC1zdHJlYW0tYmFzZWxpbmUtcGFnZXMu"
        "aHBwIiwKICAgICAgICAgICAgImhzMjc0LXN0cmVhbS1iYXNlbGluZS1jbGllbnQuaHBwIiwKICAg"
        "ICAgICAgICAgImhzMjc0LXN0cmVhbS1zb3VyY2UuaHBwIiwKICAgICAgICAgICAgImhzMjc0LXN0"
        "cmVhbS1pbnB1dC5ocHAiLAogICAgICAgICAgICAiaHMyNzQtc3RyZWFtLXJlYWRpbmVzcy5ocHAi"
        "LAogICAgICAgICAgICAiaHMyNzQtc3RyZWFtLXJ1bnRpbWUuaHBwIiwKICAgICAgICAgICAgImhz"
        "Mjc0LXN0cmVhbS1jbGkuaHBwIiwKICAgICAgICBdCiAgICAgICAgdHJhbnNmb3Jtc1swXSA9ICgi"
        "c3JjL3NoYXJlL2hpZF9kZXZpY2VfZXZlbnRzX21vbml0b3IuaHBwIiwgc3RyZWFtX21vbml0b3Ip"
        "CiAgICAgICAgdHJhbnNmb3JtcyArPSBbCiAgICAgICAgICAgICgKICAgICAgICAgICAgICAgICJ2"
        "ZW5kb3IvdmVuZG9yL2luY2x1ZGUvYXNpby9kZXRhaWwvaW1wbC9zb2NrZXRfb3BzLmlwcCIsCiAg"
        "ICAgICAgICAgICAgICBzdHJlYW1fc29ja2V0X29wcywKICAgICAgICAgICAgKSwKICAgICAgICAg"
        "ICAgKCJ2ZW5kb3IvdmVuZG9yL2luY2x1ZGUvcHFycy91bml4X2RvbWFpbl9zdHJlYW0vc2VydmVy"
        "LmhwcCIsIHN0cmVhbV9zZXJ2ZXIpLAogICAgICAgICAgICAoInNyYy9zaGFyZS90eXBlcy9vcGVy"
        "YXRpb25fdHlwZS5ocHAiLCBzdHJlYW1fb3BlcmF0aW9ucyksCiAgICAgICAgICAgICgKICAgICAg"
        "ICAgICAgICAgICJzcmMvYXBwcy9Db3JlU2VydmljZS9pbmNsdWRlL2NvcmVfc2VydmljZS9kYWVt"
        "b24vcmVjZWl2ZXIuaHBwIiwKICAgICAgICAgICAgICAgIHN0cmVhbV9yZWNlaXZlciwKICAgICAg"
        "ICAgICAgKSwKICAgICAgICAgICAgKAogICAgICAgICAgICAgICAgInNyYy9hcHBzL0NvcmVTZXJ2"
        "aWNlL2luY2x1ZGUvY29yZV9zZXJ2aWNlL2RhZW1vbi9kZXZpY2VfZ3JhYmJlcl9kZXRhaWxzL2Vu"
        "dHJ5LmhwcCIsCiAgICAgICAgICAgICAgICBzdHJlYW1fZW50cnksCiAgICAgICAgICAgICksCiAg"
        "ICAgICAgICAgICgic3JjL3NoYXJlL2NvcmVfc2VydmljZV9kYWVtb25fY2xpZW50LmhwcCIsIHN0"
        "cmVhbV9jbGllbnQpLAogICAgICAgICAgICAoInNyYy9iaW4vY2xpL3NyYy9tYWluLmNwcCIsIHN0"
        "cmVhbV9jbGkpLAogICAgICAgIF0KICAgIHByZXBhcmVkX2hlYWRlcnMgPSBbXQogICAgZm9yIG5h"
        "bWUgaW4gaGVhZGVyczoKICAgICAgICBoZWFkZXIgPSByb290IC8gInNyYy9zaGFyZSIgLyBuYW1l"
        "CiAgICAgICAgaWYgaGVhZGVyLmV4aXN0cygpIG9yIGhlYWRlci5pc19zeW1saW5rKCkgb3IgaGVh"
        "ZGVyLnJlc29sdmUoKSAhPSBoZWFkZXI6CiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcigi"
        "UmVmdXNpbmcgdG8gcmVwbGFjZSBvciByZWRpcmVjdCBhIGNhcHR1cmUgaGVhZGVyIikKICAgICAg"
        "ICBwcmVwYXJlZF9oZWFkZXJzLmFwcGVuZCgoaGVhZGVyLCBQYXRoKF9fZmlsZV9fKS53aXRoX25h"
        "bWUobmFtZSkucmVhZF9ieXRlcygpKSkKICAgIHByZXBhcmVkID0gW10KICAgIGZvciByZWxhdGl2"
        "ZSwgdHJhbnNmb3JtIGluIHRyYW5zZm9ybXM6CiAgICAgICAgdGFyZ2V0ID0gcm9vdCAvIHJlbGF0"
        "aXZlCiAgICAgICAgaWYgdGFyZ2V0LnJlc29sdmUoKSAhPSB0YXJnZXQ6CiAgICAgICAgICAgIHJh"
        "aXNlIFJ1bnRpbWVFcnJvcigiUmVmdXNpbmcgYSByZWRpcmVjdGVkIHVwc3RyZWFtIHNvdXJjZSIp"
        "CiAgICAgICAgYmFzZWxpbmUgPSBzdWJwcm9jZXNzLmNoZWNrX291dHB1dCgKICAgICAgICAgICAg"
        "WyJnaXQiLCAiLUMiLCBzdHIocm9vdCksICJzaG93IiwgIkhFQUQ6IiArIHJlbGF0aXZlXQogICAg"
        "ICAgICkKICAgICAgICBpZiB0YXJnZXQucmVhZF9ieXRlcygpICE9IGJhc2VsaW5lOgogICAgICAg"
        "ICAgICByYWlzZSBSdW50aW1lRXJyb3IoIlJlZnVzaW5nIHRvIG92ZXJ3cml0ZSBtb2RpZmllZCB1"
        "cHN0cmVhbSBzb3VyY2UiKQogICAgICAgIHByZXBhcmVkLmFwcGVuZCgodGFyZ2V0LCB0cmFuc2Zv"
        "cm0oYmFzZWxpbmUuZGVjb2RlKCJ1dGYtOCIpKS5lbmNvZGUoInV0Zi04IikpKQogICAgZm9yIGhl"
        "YWRlciwgY29udGVudHMgaW4gcHJlcGFyZWRfaGVhZGVyczoKICAgICAgICB3aXRoIGhlYWRlci5v"
        "cGVuKCJ4YiIpIGFzIGhhbmRsZToKICAgICAgICAgICAgaGFuZGxlLndyaXRlKGNvbnRlbnRzKQog"
        "ICAgZm9yIHRhcmdldCwgY29udGVudHMgaW4gcHJlcGFyZWQ6CiAgICAgICAgdGFyZ2V0LndyaXRl"
        "X2J5dGVzKGNvbnRlbnRzKQogICAgcHJpbnQoIkFwcGxpZWQgZml4dHVyZS1vbmx5IGNhcHR1cmUg"
        "YmVmb3JlIG5vcm1hbGl6YXRpb247IHN0cmVhbT0iICsgc3RyKHN0cmVhbSkpCgoKaWYgX19uYW1l"
        "X18gPT0gIl9fbWFpbl9fIjoKICAgIHBhcnNlciA9IGFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKGRl"
        "c2NyaXB0aW9uPV9fZG9jX18pCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCJyb290IiwgdHlwZT1Q"
        "YXRoKQogICAgcGFyc2VyLmFkZF9hcmd1bWVudCgiLS1zdHJlYW0iLCBhY3Rpb249InN0b3JlX3Ry"
        "dWUiKQogICAgYXJndW1lbnRzID0gcGFyc2VyLnBhcnNlX2FyZ3MoKQogICAgbWFpbihhcmd1bWVu"
        "dHMucm9vdCwgYXJndW1lbnRzLnN0cmVhbSkK"
    ),
    "d56b98f4be16c1401ebc1d7ac4fd920294a8086aae93122c64adf9d3c508a12f",
)

CHECKER_BYTES = fixed_fixture(
    (
        "IiIiVmVyaWZ5IHJldmlld2VkIHByb21vdGVkIHNvdXJjZXMgYW5kIGFjdHVhbCBzdGFnZWQgaW5w"
        "dXRzIHdpdGhvdXQgYXBwbHlpbmcgYW4gb3ZlcmxheS4iIiIKCmltcG9ydCBpbXBvcnRsaWIudXRp"
        "bAppbXBvcnQganNvbgpmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKaW1wb3J0IHN5cwoKCmRlZiBs"
        "b2FkKG5hbWUsIHBhdGgpOgogICAgc3BlYyA9IGltcG9ydGxpYi51dGlsLnNwZWNfZnJvbV9maWxl"
        "X2xvY2F0aW9uKG5hbWUsIHBhdGgpCiAgICBtb2R1bGUgPSBpbXBvcnRsaWIudXRpbC5tb2R1bGVf"
        "ZnJvbV9zcGVjKHNwZWMpCiAgICBzcGVjLmxvYWRlci5leGVjX21vZHVsZShtb2R1bGUpCiAgICBy"
        "ZXR1cm4gbW9kdWxlCgoKZGVmIG1haW4oYXJndW1lbnRzKToKICAgIGRpYWdub3N0aWNzLCBzZWFs"
        "X3BhdGggPSBtYXAoUGF0aCwgYXJndW1lbnRzWzoyXSkKICAgIHN1YmplY3QgPSBsb2FkKCJwcm9t"
        "b3RlZF9uYXRpdmVfY29udHJvbGxlciIsIGRpYWdub3N0aWNzIC8gImhzMjc0X25hdGl2ZV9idWls"
        "ZC5weSIpCiAgICB0cnk6CiAgICAgICAgc2VhbCA9IHN1YmplY3QubG9hZF9jYW5kaWRhdGVfc2Vh"
        "bChzZWFsX3BhdGgpCiAgICAgICAgc3ViamVjdC5yZXF1aXJlKAogICAgICAgICAgICBsZW4oc2Vh"
        "bFsiZmlsZXMiXSkgPT0gMjUsICJzb3VyY2VfaWRlbnRpdHkiLCAiUmV2aWV3ZWQgcHJvZHVjZXIg"
        "aW52ZW50b3J5IGNoYW5nZWQiCiAgICAgICAgKQogICAgICAgIGZvciByb3cgaW4gc2VhbFsiZmls"
        "ZXMiXToKICAgICAgICAgICAgc3ViamVjdC5yZXF1aXJlKAogICAgICAgICAgICAgICAgc3ViamVj"
        "dC5kaWdlc3Qoc3ViamVjdC5yZWFkX3JlZ3VsYXIoZGlhZ25vc3RpY3MgLyByb3dbInBhdGgiXSkp"
        "CiAgICAgICAgICAgICAgICA9PSByb3dbImNhbmRpZGF0ZV9zaGEyNTYiXSwKICAgICAgICAgICAg"
        "ICAgICJzb3VyY2VfaWRlbnRpdHkiLAogICAgICAgICAgICAgICAgIkFjdHVhbCBwcm9tb3RlZCBz"
        "b3VyY2UgZGlmZmVycyBmcm9tIGl0cyByZXZpZXdlZCBwb3N0aW1hZ2UiLAogICAgICAgICAgICAp"
        "CiAgICAgICAgY29udHJhY3QgPSBsb2FkKCJwcm9tb3RlZF9iYXNlbGluZV9jb250cmFjdCIsIGRp"
        "YWdub3N0aWNzIC8gImhzMjc0X2Jhc2VsaW5lX2NvbnRyYWN0LnB5IikKICAgICAgICBzdWJqZWN0"
        "LnJlcXVpcmUoCiAgICAgICAgICAgIGNvbnRyYWN0LnZlcnNpb25zKGRpYWdub3N0aWNzLnBhcmVu"
        "dHNbMV0pCiAgICAgICAgICAgID09IHsiY29uc3VtZXIiOiAyLCAicHJvZHVjZXIiOiAyLCAiY2xp"
        "IjogMiwgInJlYWRlciI6ICgyLCAyKX0sCiAgICAgICAgICAgICJzb3VyY2VfaWRlbnRpdHkiLAog"
        "ICAgICAgICAgICAiUHJvbW90ZWQgYmFzZWxpbmUgYm91bmRhcmllcyBkaXNhZ3JlZSIsCiAgICAg"
        "ICAgKQogICAgICAgIHN0YWdlID0gInNvdXJjZSIKICAgICAgICBpZiBsZW4oYXJndW1lbnRzKSA9"
        "PSAzOgogICAgICAgICAgICBvd25lciA9IHN1YmplY3QudmFsaWRhdGVfb3duZXJfcm9vdChQYXRo"
        "KGFyZ3VtZW50c1syXSkpCgogICAgICAgICAgICBkZWYgdW5pcXVlKHBhaXJzKToKICAgICAgICAg"
        "ICAgICAgIHZhbHVlID0ge30KICAgICAgICAgICAgICAgIGZvciBrZXksIGl0ZW0gaW4gcGFpcnM6"
        "CiAgICAgICAgICAgICAgICAgICAgc3ViamVjdC5yZXF1aXJlKAogICAgICAgICAgICAgICAgICAg"
        "ICAgICBrZXkgbm90IGluIHZhbHVlLCAiZHVwbGljYXRlX2tleSIsICJTdGFnZWQgc291cmNlIHJl"
        "Y2VpcHQgcmVwZWF0cyBhIGtleSIKICAgICAgICAgICAgICAgICAgICApCiAgICAgICAgICAgICAg"
        "ICAgICAgdmFsdWVba2V5XSA9IGl0ZW0KICAgICAgICAgICAgICAgIHJldHVybiB2YWx1ZQoKICAg"
        "ICAgICAgICAgcmVjZWlwdCA9IGpzb24ubG9hZHMoCiAgICAgICAgICAgICAgICBzdWJqZWN0LnJl"
        "YWRfcmVndWxhcihvd25lciAvICJpbnB1dHMuanNvbiIsIDY1XzUzNiksIG9iamVjdF9wYWlyc19o"
        "b29rPXVuaXF1ZQogICAgICAgICAgICApCiAgICAgICAgICAgIHN1YmplY3QucmVxdWlyZSgKICAg"
        "ICAgICAgICAgICAgIGlzaW5zdGFuY2UocmVjZWlwdCwgZGljdCkKICAgICAgICAgICAgICAgIGFu"
        "ZCBzZXQocmVjZWlwdCkgPT0geyJzY2hlbWEiLCAiaW5wdXRzIiwgImNhbmRpZGF0ZSIsICJhcmNo"
        "aXRlY3R1cmUiLCAidG9vbHMifQogICAgICAgICAgICAgICAgYW5kIHR5cGUocmVjZWlwdFsic2No"
        "ZW1hIl0pIGlzIGludAogICAgICAgICAgICAgICAgYW5kIHJlY2VpcHRbInNjaGVtYSJdID09IDEK"
        "ICAgICAgICAgICAgICAgIGFuZCByZWNlaXB0WyJjYW5kaWRhdGUiXSBpcyBOb25lLAogICAgICAg"
        "ICAgICAgICAgInNvdXJjZV9pZGVudGl0eSIsCiAgICAgICAgICAgICAgICAiUHJvbW90ZWQgY29t"
        "cGlsYXRpb24gbWF5IG5vdCByZWFwcGx5IGFuIGluYWN0aXZlIGNhbmRpZGF0ZSBvdmVybGF5IiwK"
        "ICAgICAgICAgICAgKQogICAgICAgICAgICBpbnB1dHMgPSByZWNlaXB0WyJpbnB1dHMiXQogICAg"
        "ICAgICAgICBzdWJqZWN0LnJlcXVpcmUoCiAgICAgICAgICAgICAgICBpc2luc3RhbmNlKGlucHV0"
        "cywgZGljdCkgYW5kIHNldChpbnB1dHMpID09IHsiZmlsZXMifSwKICAgICAgICAgICAgICAgICJz"
        "b3VyY2VfaWRlbnRpdHkiLAogICAgICAgICAgICAgICAgIlN0YWdlZCBzb3VyY2UgaW52ZW50b3J5"
        "IGlzIG1hbGZvcm1lZCIsCiAgICAgICAgICAgICkKICAgICAgICAgICAgcm93cyA9IGlucHV0c1si"
        "ZmlsZXMiXQogICAgICAgICAgICBzdWJqZWN0LnJlcXVpcmUoCiAgICAgICAgICAgICAgICBpc2lu"
        "c3RhbmNlKHJvd3MsIGxpc3QpIGFuZCAyNSA8PSBsZW4ocm93cykgPD0gMTI4LAogICAgICAgICAg"
        "ICAgICAgInNvdXJjZV9pZGVudGl0eSIsCiAgICAgICAgICAgICAgICAiU3RhZ2VkIHNvdXJjZSBp"
        "bnZlbnRvcnkgaXMgaW5jb21wbGV0ZSBvciB1bmJvdW5kZWQiLAogICAgICAgICAgICApCiAgICAg"
        "ICAgICAgIG9ic2VydmVkID0ge30KICAgICAgICAgICAgZm9yIHJvdyBpbiByb3dzOgogICAgICAg"
        "ICAgICAgICAgc3ViamVjdC5yZXF1aXJlKAogICAgICAgICAgICAgICAgICAgIGlzaW5zdGFuY2Uo"
        "cm93LCBkaWN0KQogICAgICAgICAgICAgICAgICAgIGFuZCBzZXQocm93KSA9PSB7InBhdGgiLCAi"
        "c2hhMjU2In0KICAgICAgICAgICAgICAgICAgICBhbmQgc3ViamVjdC5jYW5kaWRhdGVfcGF0aChy"
        "b3dbInBhdGgiXSkKICAgICAgICAgICAgICAgICAgICBhbmQgc3ViamVjdC52YWxpZF9kaWdlc3Qo"
        "cm93WyJzaGEyNTYiXSksCiAgICAgICAgICAgICAgICAgICAgInNvdXJjZV9pZGVudGl0eSIsCiAg"
        "ICAgICAgICAgICAgICAgICAgIlN0YWdlZCBzb3VyY2Ugcm93IGlzIG1hbGZvcm1lZCIsCiAgICAg"
        "ICAgICAgICAgICApCiAgICAgICAgICAgICAgICBzdWJqZWN0LnJlcXVpcmUoCiAgICAgICAgICAg"
        "ICAgICAgICAgcm93WyJwYXRoIl0gbm90IGluIG9ic2VydmVkLCAiZHVwbGljYXRlX2tleSIsICJT"
        "dGFnZWQgc291cmNlIHJlcGVhdHMgYSBwYXRoIgogICAgICAgICAgICAgICAgKQogICAgICAgICAg"
        "ICAgICAgb2JzZXJ2ZWRbcm93WyJwYXRoIl1dID0gcm93WyJzaGEyNTYiXQogICAgICAgICAgICBz"
        "dWJqZWN0LnJlcXVpcmUoCiAgICAgICAgICAgICAgICBhbGwob2JzZXJ2ZWQuZ2V0KHJvd1sicGF0"
        "aCJdKSA9PSByb3dbImNhbmRpZGF0ZV9zaGEyNTYiXSBmb3Igcm93IGluIHNlYWxbImZpbGVzIl0p"
        "LAogICAgICAgICAgICAgICAgInNvdXJjZV9pZGVudGl0eSIsCiAgICAgICAgICAgICAgICAiQWN0"
        "dWFsIHN0YWdlZCBpbnB1dHMgZGlmZmVyIGZyb20gcmV2aWV3ZWQgcHJvbW90ZWQgc291cmNlcyIs"
        "CiAgICAgICAgICAgICkKICAgICAgICAgICAgc3RhZ2VkID0gc3ViamVjdC52YWxpZGF0ZV9vd25l"
        "cl9yb290KG93bmVyIC8gImRpYWdub3N0aWNzIikKICAgICAgICAgICAgZm9yIHJvdyBpbiBzZWFs"
        "WyJmaWxlcyJdOgogICAgICAgICAgICAgICAgc3ViamVjdC5yZXF1aXJlKAogICAgICAgICAgICAg"
        "ICAgICAgIHN1YmplY3QuZGlnZXN0KHN1YmplY3QucmVhZF9yZWd1bGFyKHN0YWdlZCAvIHJvd1si"
        "cGF0aCJdKSkKICAgICAgICAgICAgICAgICAgICA9PSByb3dbImNhbmRpZGF0ZV9zaGEyNTYiXSwK"
        "ICAgICAgICAgICAgICAgICAgICAic291cmNlX2lkZW50aXR5IiwKICAgICAgICAgICAgICAgICAg"
        "ICAiQWN0dWFsIHN0YWdlZCBzb3VyY2UgZGlmZmVycyBmcm9tIGl0cyByZXZpZXdlZCBwb3N0aW1h"
        "Z2UiLAogICAgICAgICAgICAgICAgKQogICAgICAgICAgICBzdGFnZSA9ICJzdGFnZWQiCiAgICAg"
        "ICAgcHJpbnQoIlBBU1MgcHJvbW90ZWQgbmF0aXZlIHByb2R1Y2VyIGlucHV0cyBmaWxlcz0yNSBi"
        "YXNlbGluZT0yIHN0YWdlPSIgKyBzdGFnZSkKICAgICAgICByZXR1cm4gMAogICAgZXhjZXB0IHN1"
        "YmplY3QuTmF0aXZlQnVpbGRFcnJvciBhcyBmYWlsdXJlOgogICAgICAgIHByaW50KCJQcm9tb3Rl"
        "ZCBzb3VyY2UgcXVhbGlmaWNhdGlvbiByZWZ1c2VkOiAiICsgZmFpbHVyZS5jb2RlLCBmaWxlPXN5"
        "cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKICAgIGV4Y2VwdCAoT1NFcnJvciwgVmFsdWVFcnJv"
        "ciwgUnVudGltZUVycm9yLCBLZXlFcnJvciwgVHlwZUVycm9yKToKICAgICAgICBwcmludCgiUHJv"
        "bW90ZWQgc291cmNlIHF1YWxpZmljYXRpb24gcmVmdXNlZDogc291cmNlX2lkZW50aXR5IiwgZmls"
        "ZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9f"
        "IjoKICAgIHJhaXNlIFN5c3RlbUV4aXQobWFpbihzeXMuYXJndlsxOl0pKQo="
    ),
    "5eb93737f6ec81c77e2cc9fab2ba895b90789b98da0b0ebcf68979387c5ab7cd",
)

EXPECTED = json.loads(EXPECTED_BYTES)


class WitnessControls(unittest.TestCase):
    def setUp(self):
        """Select actual repo source providers into this test's canonical owned temp."""
        global ROOT
        self.tmp = tempfile.TemporaryDirectory(prefix="promoted-witness-")
        self.owner = Path(self.tmp.name).resolve()
        ROOT = self.owner
        self.repo = self.owner / "packet/candidate"
        self.diagnostics = self.repo / "tools/diagnostics"
        self.diagnostics.mkdir(parents=True)
        for source in SOURCE_DIAGNOSTICS.iterdir():
            if source.is_file() and source.suffix in {".py", ".hpp", ".cpp"}:
                shutil.copyfile(source, self.diagnostics / source.name)
        archive = "tools/diagnostics/fixtures/hs274-native-build-candidate"
        archived = self.repo / archive
        archived.mkdir(parents=True)
        for name in ("manifest.json", "candidate.patch", "README.md"):
            shutil.copyfile(SOURCE_REPOSITORY / archive / name, archived / name)
        baseline = "static/ergopti_plus/macos/modules/keylogger/physical_baseline.lua"
        target = self.repo / baseline
        target.parent.mkdir(parents=True)
        shutil.copyfile(SOURCE_REPOSITORY / baseline, target)
        old_raw = ROOT / "packet/baseline/tools/diagnostics/hs274_raw_patch.py"
        old_raw.parent.mkdir(parents=True)
        old_raw.write_bytes(PRIOR_RAW_BYTES)
        (ROOT / "original-checker.py").write_bytes(CHECKER_BYTES)
        path = self.diagnostics / "hs274_promoted_source_witness.py"
        spec = importlib.util.spec_from_file_location("independent_witness", path)
        self.subject = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.subject)

    def tearDown(self):
        global ROOT
        self.tmp.cleanup()
        ROOT = SOURCE_DIAGNOSTICS

    def pair(self):
        pair = self.subject.generate(self.repo)
        self.assertEqual(set(pair), {"manifest.json", "candidate.patch"})
        self.assertTrue(all(type(value) is bytes and value for value in pair.values()))
        return pair

    def refused(self):
        with self.assertRaises(Exception) as captured:
            self.subject.generate(self.repo)
        self.assertEqual(type(captured.exception).__name__, "NativeBuildError")
        self.assertIsInstance(captured.exception.code, str)
        self.assertTrue(captured.exception.code)

    def test_deterministic_exact_inventory_and_declared_digest(self):
        pair = self.pair()
        self.assertEqual(pair, self.pair())
        manifest = json.loads(pair["manifest.json"])
        self.assertEqual(manifest["schema"], 1)
        self.assertEqual(manifest["patch_file"], "candidate.patch")
        self.assertEqual(
            manifest["patch_sha256"], hashlib.sha256(pair["candidate.patch"]).hexdigest()
        )
        self.assertEqual(len(manifest["files"]), 25)
        self.assertEqual(
            {row["path"]: row["candidate_sha256"] for row in manifest["files"]}, EXPECTED
        )
        self.assertTrue(all(row["preimage_sha256"] is None for row in manifest["files"]))

    def test_actual_patch_materializes_only_reviewed_sources_in_empty_directory(self):
        pair = self.pair()
        empty = self.owner / "empty"
        empty.mkdir(mode=0o700)
        subprocess.run(["/usr/bin/git", "init", "-q", str(empty)], check=True, capture_output=True)
        patch = self.owner / "candidate.patch"
        patch.write_bytes(pair["candidate.patch"])
        result = subprocess.run(
            ["/usr/bin/git", "apply", "--whitespace=error", str(patch)],
            cwd=empty,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = {
            str(path.relative_to(empty)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in empty.iterdir()
            if path.name != ".git"
        }
        self.assertEqual(actual, EXPECTED)
        for name in EXPECTED:
            self.assertEqual((empty / name).read_bytes(), (self.diagnostics / name).read_bytes())

    def test_arbitrary_source_change_refused_without_output_rewrite(self):
        path = self.diagnostics / "hs274-stream-source.hpp"
        path.write_bytes(path.read_bytes() + b"\n// foreign change\n")
        self.refused()
        self.assertTrue(path.read_bytes().endswith(b"// foreign change\n"))

    def test_previous_unformatted_source_refused(self):
        path = self.diagnostics / "hs274_raw_patch.py"
        path.write_bytes(
            (ROOT / "packet/baseline/tools/diagnostics/hs274_raw_patch.py").read_bytes()
        )
        self.refused()

    def test_missing_source_refused(self):
        (self.diagnostics / "hs274-stream-source.hpp").unlink()
        self.refused()

    def test_mutated_archive_cannot_redefine_source_contract(self):
        path = self.diagnostics / "fixtures/hs274-native-build-candidate/manifest.json"
        path.write_bytes(path.read_bytes() + b" ")
        self.refused()

    def test_identical_source_bytes_through_alias_refused(self):
        path = self.diagnostics / "hs274-stream-source.hpp"
        target = self.owner / "header.hpp"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.refused()

    def test_original_checker_accepts_actual_formatted_and_staged_bytes(self):
        pair = self.pair()
        seal_dir = self.owner / "seal"
        seal_dir.mkdir(mode=0o700)
        for name, data in pair.items():
            (seal_dir / name).write_bytes(data)
        path = self.diagnostics / "hs274_native_build.py"
        spec = importlib.util.spec_from_file_location("independent_controller", path)
        controller = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(controller)
        seal = controller.load_candidate_seal(seal_dir / "manifest.json")
        self.assertEqual(len(seal["files"]), 25)
        build_owner = self.owner / "build"
        build_owner.mkdir(mode=0o700)
        inputs = controller.stage_diagnostics(self.diagnostics, build_owner / "diagnostics")
        (build_owner / "inputs.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "inputs": inputs,
                    "candidate": None,
                    "architecture": "portable-policy",
                    "tools": {},
                }
            )
        )
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "original-checker.py"),
                str(self.diagnostics),
                str(seal_dir / "manifest.json"),
                str(build_owner),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "PASS promoted native producer inputs files=25 baseline=2 stage=staged",
        )


class WitnessCLIControls(unittest.TestCase):
    def setUp(self):
        WitnessControls.setUp(self)
        directory = "tools/diagnostics/fixtures/hs274-promoted-source-witness"
        target = self.repo / directory
        target.mkdir(parents=True)
        for name in ("manifest.json", "candidate.patch"):
            shutil.copyfile(SOURCE_REPOSITORY / directory / name, target / name)

    def tearDown(self):
        WitnessControls.tearDown(self)

    def run_case(self, case):
        with tempfile.TemporaryDirectory(prefix="cli-" + case + "-") as tmp:
            owner = Path(tmp)
            repo = owner / "repo"
            shutil.copytree(
                ROOT / "packet/candidate",
                repo,
                ignore=shutil.ignore_patterns("__pycache__", ".git"),
            )
            diag = repo / "tools/diagnostics"
            directory = diag / "fixtures/hs274-promoted-source-witness"
            manifest = directory / "manifest.json"
            patch = directory / "candidate.patch"
            oldpatch = patch.read_bytes()
            external = owner / "external"
            external.write_bytes(b"unchanged-external")
            args = [sys.executable, "-B", str(diag / "hs274_promoted_source_witness.py"), str(repo)]
            if case == "stale":
                manifest.write_bytes(manifest.read_bytes() + b" ")
            if case == "source-and-pair":
                source = diag / "hs274-stream-source.hpp"
                source.write_bytes(source.read_bytes() + b"\n// foreign change\n")
                body = json.loads(manifest.read_text())
                for row in body["files"]:
                    if row["path"] == "hs274-stream-source.hpp":
                        row["candidate_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
                manifest.write_text(json.dumps(body) + "\n")
            if case == "symlink-write":
                manifest.unlink()
                manifest.symlink_to(external)
                args.append("--write")
            if case == "fifo-write":
                manifest.unlink()
                os.mkfifo(manifest)
                args.append("--write")
            r = subprocess.run(args, capture_output=True, text=True, timeout=3)
            (ROOT / ("cli-" + case + ".stdout")).write_text(r.stdout)
            (ROOT / ("cli-" + case + ".stderr")).write_text(r.stderr)
            if case == "healthy":
                self.assertTrue(
                    r.returncode == 0
                    and r.stdout
                    == "PASS generated promoted source witness files=25; compilation and installation unexecuted\n"
                    and not r.stderr
                )
            else:
                self.assertTrue(r.returncode != 0 and "PASS" not in r.stdout)
                self.assertTrue(external.read_bytes() == b"unchanged-external")
                self.assertTrue(patch.read_bytes() == oldpatch)

    def test_cli_healthy(self):
        self.run_case("healthy")

    def test_cli_stale(self):
        self.run_case("stale")

    def test_cli_source_and_pair(self):
        self.run_case("source-and-pair")

    def test_cli_symlink_write(self):
        self.run_case("symlink-write")

    def test_cli_fifo_write(self):
        self.run_case("fifo-write")


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.TestSuite(
            [
                unittest.defaultTestLoader.loadTestsFromTestCase(WitnessControls),
                unittest.defaultTestLoader.loadTestsFromTestCase(WitnessCLIControls),
            ]
        )
    )
    healthy = result.wasSuccessful() and result.testsRun == 13 and not result.skipped
    print(
        ("PASS" if healthy else "FAIL")
        + " independent promoted witness controls tests="
        + str(result.testsRun)
        + " failures="
        + str(len(result.failures))
        + " errors="
        + str(len(result.errors))
        + " skipped="
        + str(len(result.skipped))
    )
    raise SystemExit(not healthy)
