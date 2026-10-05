# tools/diagnostics/macos_tooltip_canvas_observer.py
#!/usr/bin/env python3
"""Read native PNG pixels and attributed text without rewriting captured images."""

import hashlib
import math
from pathlib import Path

from PIL import Image


PREFIXES = {
    0: ("✨ ", "\u2009"),
    2: ("  ✨ ", "\u2009"),
    -1: ("✨ ", " \u2009"),
    -3: ("✨ ", "✨ "),
}
COLORS = {"gray": (0.5, 0.5, 0.5), "green": (0.25, 0.90, 0.40), "orange": (1.0, 0.62, 0.10)}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def rgb(attributes):
    color = attributes["color"]
    if "white" in color:
        value = color["white"]
        return value, value, value
    return tuple(color[channel] for channel in ("red", "green", "blue"))


def attribute_at(styled, byte):
    # Hammerspoon's asTable offsets use Lua UTF-8 byte positions, not code points.
    matches = [item["attributes"] for item in styled[1:] if item["starts"] <= byte <= item["ends"]]
    require(len(matches) == 1, "native attributed-text range missing or overlapping")
    return matches[0]


def validate_attributes(case):
    styled = case["styled"]
    expected_rows = []
    offset = 1
    for row in range(1, 4):
        chosen = row == case["selected"]
        prefix = PREFIXES[case["indent"]][0 if chosen else 1]
        expected_rows.append(prefix + "MMMMMMMM MMMM")
        prefix_end = offset + len(prefix.encode("utf-8")) - 1
        prefix_style = attribute_at(styled, prefix_end)
        if chosen:
            require(
                all(abs(a - b) < 0.015 for a, b in zip(rgb(prefix_style), (0.98, 0.88, 0.22))),
                "selected native prefix color differs",
            )
            require(
                abs(prefix_style["color"].get("alpha", 1) - 1) < 0.01,
                "selected native prefix is invisible",
            )
        else:
            require(
                prefix_style["color"].get("alpha") == 0,
                "unselected compensating native prefix is visible",
            )
        cursor = offset + len(prefix.encode("utf-8"))
        for role, piece in (("gray", "MMMM"), ("green", "MMMM"), ("orange", " MMMM")):
            expected_color = COLORS[role if chosen else "gray"]
            expected_font = case["font_names"][int(not chosen and role != "gray")]
            for byte in range(cursor, cursor + len(piece.encode("utf-8"))):
                attributes = attribute_at(styled, byte)
                require(
                    all(abs(a - b) < 0.015 for a, b in zip(rgb(attributes), expected_color)),
                    "native attributed-text role color differs",
                )
                require(
                    attributes["font"]["name"] == expected_font,
                    "native attributed-text bold role differs",
                )
                require(
                    abs(attributes["font"]["size"] - 14) < 0.01,
                    "native attributed-text font size differs",
                )
                require(
                    abs(attributes["color"].get("alpha", 1) - 1) < 0.01, "native role is not opaque"
                )
            cursor += len(piece.encode("utf-8"))
        offset = cursor + 1  # One native newline between rows.
    require(styled[0] == "\n".join(expected_rows), "independent text/prefix expectation differs")


def color_class(pixel):
    r, g, b, a = pixel
    if a < 200:
        return None
    if g > 85 and g - r > 45 and g - b > 35:
        return "green"
    if r > 100 and r - g > 35 and g - b > 35:
        return "orange"
    if 67 <= r <= 145 and max(r, g, b) - min(r, g, b) <= 5:
        return "gray"
    return None


def validate_pixels(case, directory):
    path = Path(directory) / case["image"]
    original = path.read_bytes()
    with Image.open(path) as decoded:
        require(decoded.format == "PNG", "capture is not a native PNG")
        decoded.load()
        image = decoded.convert("RGBA")  # Observer buffer only; original file is untouched.
    frame = case["frame"]
    sx, sy = image.width / frame["w"], image.height / frame["h"]
    require(0.5 <= sx <= 4 and abs(sx - sy) < 0.03, "native pixel/point geometry differs")
    zone = case["predictions_frame"]
    x0, x1 = math.ceil(zone["x"] * sx), math.floor((zone["x"] + zone["w"]) * sx)
    y0, y1 = math.ceil(zone["y"] * sy), math.floor((zone["y"] + zone["h"]) * sy)
    pixels = image.load()
    ink = {}
    for y in range(y0, y1):
        row = [(x, color_class(pixels[x, y])) for x in range(x0, x1)]
        accepted = [(x, kind) for x, kind in row if kind is not None]
        if len(accepted) >= 4:
            ink[y] = accepted
    bands = []
    for y in sorted(ink):
        if not bands or y > bands[-1][-1] + 1:
            bands.append([y])
        else:
            bands[-1].append(y)
    require(len(bands) == 3, "native pixels do not contain three separate prediction rows")
    observations = []
    for index, band in enumerate(bands, 1):
        counts = {kind: sum(kind == value for y in band for _, value in ink[y]) for kind in COLORS}
        require(counts["gray"] >= 25, "typed/unselected gray pixels missing")
        if index == case["selected"]:
            require(
                counts["green"] >= 15 and counts["orange"] >= 15,
                "selected correction/continuation pixels missing",
            )
        else:
            require(
                counts["green"] == 0 and counts["orange"] == 0,
                "unselected row contains selected-role color",
            )
        gray = [x for y in band for x, kind in ink[y] if kind == "gray"]
        left = min(gray)
        if index == case["selected"]:
            # Emoji antialiasing can contain gray pixels before the typed text.
            # The independently observed correction color and regular MMMM
            # advance bound the complete typed run, not the marker's pixels.
            green_left = min(x for y in band for x, kind in ink[y] if kind == "green")
            normal_width = case["glyph_widths"][0] * sx
            tolerance = 2.5 * sx
            body = [x for x in gray if green_left - normal_width - tolerance <= x < green_left]
            require(len(body) >= 25, "native gray typed body missing")
            # Glyph advances describe origins, not antialiased ink bounds.
            # Four separate regular M glyphs must span the typed run before
            # the first green M; a fragment or shifted run cannot borrow it.
            columns = sorted(set(body))
            starts = [
                x for offset, x in enumerate(columns) if offset == 0 or x > columns[offset - 1] + 1
            ]
            require(
                len(starts) == 4
                and all(
                    abs(right - left - normal_width / 4) <= tolerance
                    for left, right in zip(starts, starts[1:])
                ),
                "native typed body width does not match independent regular glyphs",
            )
            left = starts[0]
            require(
                abs(green_left - left - normal_width) <= tolerance,
                "native typed body is not adjacent to its correction",
            )
        observations.append(
            {"row": index, "counts": counts, "typed_left": left, "top": band[0], "bottom": band[-1]}
        )
    chosen = observations[case["selected"] - 1]
    others = [row for row in observations if row["row"] != case["selected"]]
    expected_delta = (case["prefix_advances"][0] - case["prefix_advances"][1]) * sx
    for other in others:
        require(
            abs(chosen["typed_left"] - other["typed_left"] - expected_delta) <= 2.5 * sx,
            "native row indentation does not match independent prefixes",
        )
    # Actual bold ink must be heavier than adjacent regular MMMM on each gray row.
    # This complements genuine native font-attribute readback with raster evidence.
    for row in others:
        band = bands[row["row"] - 1]
        start = row["typed_left"]
        normal_width = case["glyph_widths"][0] * sx
        bold_width = case["glyph_widths"][1] * sx
        # The role classifier deliberately recognizes a narrow gray band. Its
        # count excludes solid antialiased cores on color-managed captures and
        # therefore measures edges, not glyph weight. Integrate neutral contrast
        # above the same row's empty backplate in the unchanged native windows.
        require(start > x0, "native row backplate missing")
        backplate = {y: pixels[x0, y] for y in band}
        require(
            all(
                pixel[3] >= 200
                and max(pixel[:3]) - min(pixel[:3]) <= 5
                and color_class(pixel) is None
                for pixel in backplate.values()
            ),
            "native row backplate is not opaque neutral background",
        )

        def contrast_mass(left, right):
            total = 0
            for y in band:
                background = sum(backplate[y][:3]) / 3
                for x in range(left, min(x1, right)):
                    pixel = pixels[x, y]
                    if pixel[3] >= 200 and max(pixel[:3]) - min(pixel[:3]) <= 5:
                        total += max(0, sum(pixel[:3]) / 3 - background)
            return total

        regular_ink = contrast_mass(start, math.floor(start + normal_width))
        bold_start = math.ceil(start + normal_width)
        bold_ink = contrast_mass(bold_start, math.floor(bold_start + bold_width))
        require(
            bold_ink > regular_ink * 1.03, "native unselected correction is not visibly heavier"
        )
        row["regular_ink"] = regular_ink
        row["bold_ink"] = bold_ink
    require(path.read_bytes() == original, "observer changed a native image")
    return {
        "image": case["image"],
        "sha256": hashlib.sha256(original).hexdigest(),
        "size": [image.width, image.height],
        "scale": [sx, sy],
        "rows": observations,
    }


def observe(result, directory):
    require(
        result.get("status") == "ok" and result.get("runtime") == "native Hammerspoon",
        "native producer did not succeed",
    )
    require(
        result.get("canvas_cleanup") is True and result.get("production_errors") == [],
        "native producer retained canvas/error debt",
    )
    require(
        result.get("physical_input") == "unmeasured"
        and result.get("watcher_orchestration") == "unmeasured",
        "diagnostic scope was overstated",
    )
    require(
        result.get("isolation")
        == {
            "logger": True,
            "locale": True,
            "input_tag_storage": "strict in-memory reservation",
            "storage_reads": 1,
            "storage_writes": 1,
        },
        "configuration isolation receipt differs",
    )
    cases = result.get("cases")
    require(isinstance(cases, list) and len(cases) == 12, "native capture matrix incomplete")
    observations = []
    for ordinal, (indent, selected) in enumerate(
        ((i, s) for i in (0, 2, -1, -3) for s in (1, 2, 3)), 1
    ):
        case = cases[ordinal - 1]
        require(
            (case.get("ordinal"), case.get("indent"), case.get("selected"), case.get("image"))
            == (ordinal, indent, selected, f"paint-{ordinal:02}.png"),
            "capture identities differ",
        )
        require(
            case.get("showing") is True and case.get("hidden_after") is True,
            "actual showing/hidden state missing",
        )
        validate_attributes(case)
        observations.append(validate_pixels(case, directory))
    return observations
