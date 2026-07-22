# hammerspoon/data/test_generate_models_calc.py
"""
==============================================================================
MODULE: Model Hardware-Requirement Calculation — Regression Tests
DESCRIPTION:
Pure, network-free tests for the disk/RAM estimators in generate_models.py.

ROOT CAUSE ENCODED:
The old estimator computed RAM straight from the parameter count
(params * 0.55 + 0.5) independently of the looked-up download size. For MoE
models that produced RAM < download (e.g. Qwen3-Coder-30B: 19 GB download but
17.3 GB RAM), and a failed download lookup left download_gb = null so the menu
showed a blank. RAM is now derived from the (real or estimated) download size,
and a missing download falls back to a parameter-based estimate. These tests
pin both invariants: RAM >= download, and no blank download when params known.
==============================================================================
"""

import generate_models as gm


def _run() -> None:
    # ── Download estimate from parameters (Q4 fallback) ──────────────────────
    assert gm.estimate_download_gb("7B") == round(7 * 0.55, 2), "7B download estimate"
    assert gm.estimate_download_gb("N/A") is None, "unknown params → no estimate"
    assert gm.estimate_download_gb(None) is None, "None params → no estimate"
    # MoE shorthand: 8x7B ≈ 8 * 7 * 0.85 billions.
    moe = gm.estimate_download_gb("8x7B")
    assert moe is not None and abs(moe - round(8 * 7 * 0.85 * 0.55, 2)) < 0.01, "MoE download estimate"

    # ── RAM is derived from the download and is always >= it ─────────────────
    assert gm.estimate_ram_gb(None) is None, "no download → no RAM"
    assert gm.estimate_ram_gb(0) is None, "zero download → no RAM"
    ram_19 = gm.estimate_ram_gb(19.0)
    assert ram_19 is not None and ram_19 >= 19.0, "RAM must be >= download (regression: was < for MoE)"

    # ── Unified requirements: real download preferred, RAM consistent ────────
    real = gm.calculate_hardware_requirements(19.0, "30.53B")
    assert real["download_gb"] == 19.0, "real download is preserved"
    assert real["ram_gb"] >= real["download_gb"], "RAM >= download for a real MoE download"

    # ── A failed lookup (download None) no longer leaves a blank ─────────────
    filled = gm.calculate_hardware_requirements(None, "7B")
    assert filled["download_gb"] is not None, "missing download is estimated, not blank"
    assert filled["ram_gb"] is not None and filled["ram_gb"] >= filled["download_gb"], "estimated RAM >= estimated download"

    # ── Genuinely unknown params: both stay None (nothing to invent) ─────────
    unknown = gm.calculate_hardware_requirements(None, "N/A")
    assert unknown["download_gb"] is None and unknown["ram_gb"] is None, "unknown params → both None"

    print("OK — model hardware-requirement calculation invariants hold.")


if __name__ == "__main__":
    _run()
