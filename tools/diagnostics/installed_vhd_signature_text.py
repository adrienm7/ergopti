# tools/diagnostics/installed_vhd_signature_text.py
"""Recognize three captured pkgutil text forms without granting any authority."""

_VERSION_TIMESTAMPS = (
    ("8.4.0", "2026-09-04 13:32:50 +0000"),
    ("8.5.0", "2026-09-06 05:08:01 +0000"),
    ("8.6.0", "2026-09-26 13:31:58 +0000"),
)
_STATUS = "signed by a developer certificate issued by Apple for distribution"
_NOTARIZATION = "trusted by the Apple notary service"
_CERTIFICATES = (
    (
        "Developer ID Installer: Fumihiko Takayama (G43BCU2T37)",
        "2027-02-01 22:12:15 +0000",
        "6BFAEF82197D9E7722A5EC207CB133A59C7037881D302B04DB1995CA4404FEB8",
    ),
    (
        "Developer ID Certification Authority",
        "2027-02-01 22:12:15 +0000",
        "7AFC9D01A62F03A2DE9637936D4AFE68090D2DE18D03F29C88CFB0B1BA63587F",
    ),
    (
        "Apple Root CA",
        "2035-02-09 21:40:36 +0000",
        "B0B1730ECBC7FF4505142C49F1295E6EDA6BCAED7E2C68C5BE91B5A11001F024",
    ),
)


def observe_signature_text(expected_version, stdout, stderr, exit_status):
    """Return only observed text fields for one exact supported captured form.

    Args:
        expected_version: Exact str value 8.4.0, 8.5.0, or 8.6.0.
        stdout: Exact bytes value containing the complete captured stdout form.
        stderr: Exact bytes value; the supported signature form has no stderr.
        exit_status: Exact int value zero, supplied independently of tool text.

    Returns:
        A fresh observation dictionary with unknown trust and false authorities.
        Recognition does not verify package bytes, native provenance, signing,
        present certificate validity, driver state, or installation permission.

    Raises:
        ValueError: A type, status, channel, version, or complete form is refused.
        TypeError: A required argument is absent or an unexpected argument exists.
    """
    if (
        type(expected_version) is not str
        or type(stdout) is not bytes
        or type(stderr) is not bytes
        or type(exit_status) is not int
        or exit_status != 0
        or stderr != b""
        or len(stdout) != 1128
    ):
        raise ValueError("Signature text input refused")
    timestamp = None
    for version, observed_timestamp in _VERSION_TIMESTAMPS:
        if expected_version == version:
            timestamp = observed_timestamp
            break
    if timestamp is None:
        raise ValueError("Signature text version refused")

    filename = "Karabiner-DriverKit-VirtualHIDDevice-" + expected_version + ".pkg"
    lines = [
        'Package "' + filename + '":',
        "   Status: " + _STATUS,
        "   Notarization: " + _NOTARIZATION,
        "   Signed with a trusted timestamp on: " + timestamp,
        "   Certificate Chain:",
    ]
    for ordinal, (subject, expires, fingerprint) in enumerate(_CERTIFICATES, 1):
        octets = [fingerprint[index : index + 2] for index in range(0, 64, 2)]
        lines.extend(
            (
                f"    {ordinal}. " + subject,
                "       Expires: " + expires,
                "       SHA256 Fingerprint:",
                "           " + " ".join(octets[:22]) + " ",
                "           " + " ".join(octets[22:]),
            )
        )
        if ordinal < 3:
            lines.append("       " + "-" * 72)
    lines.append("")
    if stdout != ("\n".join(lines) + "\n").encode("ascii"):
        raise ValueError("Signature text complete form refused")

    return {
        "kind": "installed_vhd_signature_text_observation",
        "status": "recognized_supported_signature_text",
        "observed_version_text": expected_version,
        "observed_package_filename_text": filename,
        "observed_status_text": _STATUS,
        "observed_notarization_text": _NOTARIZATION,
        "observed_signed_timestamp_text": timestamp,
        "observed_certificate_chain_text": [
            {
                "ordinal": ordinal,
                "subject_text": subject,
                "expires_text": expires,
                "fingerprint_hex_text": fingerprint,
            }
            for ordinal, (subject, expires, fingerprint) in enumerate(_CERTIFICATES, 1)
        ],
        "trust": "unknown",
        "authority": False,
        "reference_qualified": False,
    }
