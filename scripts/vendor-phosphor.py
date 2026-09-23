#!/usr/bin/env python3
"""Download the Phosphor glyphs Yeobun uses and write Sources/App/GlyphLibrary.swift.

Phosphor regular and fill weights are filled paths on a shared 256×256 canvas,
so a square frame centers them. Arcs are flattened to cubics here.
"""

import math
import re
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Sources" / "App" / "GlyphLibrary.swift"
BASE = "https://raw.githubusercontent.com/phosphor-icons/core/main/assets"

# (GlyphID case, raw value, phosphor file stem)
ICONS = [
    ("lock", "lock", "lock"),
    ("mouse", "mouse", "mouse"),
    ("moonStars", "moon-stars", "moon-stars"),
    ("coffee", "coffee", "coffee"),
    ("eyeSlash", "eye-slash", "eye-slash"),
    ("microphone", "microphone", "microphone"),
    ("laptop", "laptop", "laptop"),
    ("batteryFull", "battery-full", "battery-full"),
    ("wifiHigh", "wifi-high", "wifi-high"),
    ("hardDrive", "hard-drive", "hard-drive"),
    ("hardDrives", "hard-drives", "hard-drives"),
    ("desktop", "desktop", "desktop"),
    ("cloud", "cloud", "cloud"),
    ("usb", "usb", "usb"),
    ("shareNetwork", "share-network", "share-network"),
    ("house", "house", "house"),
    ("buildings", "buildings", "buildings"),
    ("package", "package", "package"),
    ("terminalWindow", "terminal-window", "terminal-window"),
]

TOKEN = re.compile(r"[AaCcHhLlMmQqSsVvZz]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?")


def fetch(url: str) -> str:
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read().decode("utf-8")


def tokenize(d: str):
    return TOKEN.findall(d)


class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.i = 0
        self.ops = []
        self.cx = 0.0
        self.cy = 0.0
        self.sx = 0.0
        self.sy = 0.0
        self.last_cubic = None
        self.prev = ""

    def parse(self):
        while self.i < len(self.tokens):
            command = self.tokens[self.i]
            if not command.isalpha():
                raise SystemExit(f"expected command, got {command}")
            self.i += 1
            self.command(command)
        return self.ops

    def num(self):
        if self.i >= len(self.tokens) or self.tokens[self.i].isalpha():
            return None
        value = float(self.tokens[self.i])
        self.i += 1
        return value

    def take(self, count):
        values = []
        for _ in range(count):
            value = self.num()
            if value is None:
                return None
            values.append(value)
        return values

    def command(self, command):
        relative = command.islower()
        kind = command.upper()
        first = True
        while True:
            if kind == "Z":
                self.ops.append(("close",))
                self.cx, self.cy = self.sx, self.sy
                self.last_cubic = None
                self.prev = "Z"
                return
            if kind == "M":
                pair = self.take(2)
                if pair is None:
                    if first:
                        raise SystemExit("move without a point")
                    return
                x, y = self.absolute(pair[0], pair[1], relative)
                self.ops.append(("move", x, y))
                self.cx, self.cy = x, y
                self.sx, self.sy = x, y
                self.last_cubic = None
                self.prev = "M"
                kind = "L"
                first = False
                continue
            if kind == "L":
                pair = self.take(2)
                if pair is None:
                    if first:
                        raise SystemExit("line without a point")
                    return
                x, y = self.absolute(pair[0], pair[1], relative)
                self.line(x, y)
                first = False
                continue
            if kind == "H":
                value = self.num()
                if value is None:
                    if first:
                        raise SystemExit("horizontal line without a point")
                    return
                x = self.cx + value if relative else value
                self.line(x, self.cy)
                first = False
                continue
            if kind == "V":
                value = self.num()
                if value is None:
                    if first:
                        raise SystemExit("vertical line without a point")
                    return
                y = self.cy + value if relative else value
                self.line(self.cx, y)
                first = False
                continue
            if kind == "C":
                values = self.take(6)
                if values is None:
                    if first:
                        raise SystemExit("cubic without points")
                    return
                x1, y1 = self.absolute(values[0], values[1], relative)
                x2, y2 = self.absolute(values[2], values[3], relative)
                x, y = self.absolute(values[4], values[5], relative)
                self.cubic(x1, y1, x2, y2, x, y)
                first = False
                continue
            if kind == "S":
                values = self.take(4)
                if values is None:
                    if first:
                        raise SystemExit("smooth cubic without points")
                    return
                if self.prev in ("C", "S") and self.last_cubic is not None:
                    x1 = 2 * self.cx - self.last_cubic[0]
                    y1 = 2 * self.cy - self.last_cubic[1]
                else:
                    x1, y1 = self.cx, self.cy
                x2, y2 = self.absolute(values[0], values[1], relative)
                x, y = self.absolute(values[2], values[3], relative)
                self.cubic(x1, y1, x2, y2, x, y)
                first = False
                continue
            if kind == "Q":
                values = self.take(4)
                if values is None:
                    if first:
                        raise SystemExit("quadratic without points")
                    return
                qx, qy = self.absolute(values[0], values[1], relative)
                x, y = self.absolute(values[2], values[3], relative)
                self.quadratic(qx, qy, x, y)
                first = False
                continue
            if kind == "A":
                values = self.take(7)
                if values is None:
                    if first:
                        raise SystemExit("arc without points")
                    return
                rx, ry, phi, large, sweep, ex, ey = values
                x, y = self.absolute(ex, ey, relative)
                self.arc(rx, ry, phi, large, sweep, x, y)
                first = False
                continue
            raise SystemExit(f"unsupported path command {command}")

    def absolute(self, x, y, relative):
        if relative:
            return self.cx + x, self.cy + y
        return x, y

    def line(self, x, y):
        self.ops.append(("line", x, y))
        self.cx, self.cy = x, y
        self.last_cubic = None
        self.prev = "L"

    def cubic(self, x1, y1, x2, y2, x, y):
        self.ops.append(("cubic", x1, y1, x2, y2, x, y))
        self.cx, self.cy = x, y
        self.last_cubic = (x2, y2)
        self.prev = "C"

    def quadratic(self, qx, qy, x, y):
        c1x = self.cx + 2 / 3 * (qx - self.cx)
        c1y = self.cy + 2 / 3 * (qy - self.cy)
        c2x = x + 2 / 3 * (qx - x)
        c2y = y + 2 / 3 * (qy - y)
        self.cubic(c1x, c1y, c2x, c2y, x, y)
        self.prev = "Q"

    def arc(self, rx, ry, phi_deg, large, sweep, x2, y2):
        x1, y1 = self.cx, self.cy
        if math.hypot(x2 - x1, y2 - y1) < 1e-6:
            return
        if abs(rx) < 1e-6 or abs(ry) < 1e-6:
            self.line(x2, y2)
            return
        phi = math.radians(phi_deg)
        cos_phi, sin_phi = math.cos(phi), math.sin(phi)
        rx, ry = abs(rx), abs(ry)
        dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
        x1p = cos_phi * dx + sin_phi * dy
        y1p = -sin_phi * dx + cos_phi * dy
        lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lam > 1:
            scale = math.sqrt(lam)
            rx *= scale
            ry *= scale
        rx_sq, ry_sq = rx * rx, ry * ry
        num = rx_sq * ry_sq - rx_sq * y1p * y1p - ry_sq * x1p * x1p
        den = rx_sq * y1p * y1p + ry_sq * x1p * x1p
        coef = math.sqrt(max(0.0, num / den)) if den else 0.0
        if bool(large) == bool(sweep):
            coef = -coef
        cxp = coef * rx * y1p / ry
        cyp = coef * -ry * x1p / rx
        cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2
        cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2

        def angle(ux, uy, vx, vy):
            sign = 1 if ux * vy - uy * vx >= 0 else -1
            dot = ux * vx + uy * vy
            norm = math.hypot(ux, uy) * math.hypot(vx, vy)
            if norm == 0:
                return 0.0
            return sign * math.acos(max(-1.0, min(1.0, dot / norm)))

        theta = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        delta = angle(
            (x1p - cxp) / rx,
            (y1p - cyp) / ry,
            (-x1p - cxp) / rx,
            (-y1p - cyp) / ry,
        )
        if not sweep and delta > 0:
            delta -= 2 * math.pi
        elif sweep and delta < 0:
            delta += 2 * math.pi
        segments = max(1, math.ceil(abs(delta) / (math.pi / 2)))
        step = delta / segments
        for index in range(segments):
            a1 = theta + index * step
            a2 = a1 + step
            self.arc_segment(cx, cy, rx, ry, phi, a1, a2)
        self.cx, self.cy = x2, y2
        self.prev = "A"

    def arc_segment(self, cx, cy, rx, ry, phi, a1, a2):
        da = a2 - a1
        alpha = math.sin(da) * (math.sqrt(4 + 3 * math.tan(da / 2) ** 2) - 1) / 3
        cos_phi, sin_phi = math.cos(phi), math.sin(phi)

        def point(angle):
            x, y = math.cos(angle), math.sin(angle)
            return (
                cx + rx * cos_phi * x - ry * sin_phi * y,
                cy + rx * sin_phi * x + ry * cos_phi * y,
            )

        def derivative(angle):
            x, y = -math.sin(angle), math.cos(angle)
            return (
                rx * cos_phi * x - ry * sin_phi * y,
                rx * sin_phi * x + ry * cos_phi * y,
            )

        start = point(a1)
        end = point(a2)
        d1 = derivative(a1)
        d2 = derivative(a2)
        self.ops.append(
            (
                "cubic",
                start[0] + alpha * d1[0],
                start[1] + alpha * d1[1],
                end[0] - alpha * d2[0],
                end[1] - alpha * d2[1],
                end[0],
                end[1],
            )
        )
        self.last_cubic = (end[0] - alpha * d2[0], end[1] - alpha * d2[1])


def paths(svg: str):
    found = re.findall(r'\bd="([^"]+)"', svg)
    if not found:
        raise SystemExit("svg has no path")
    if 'fill-rule="evenodd"' in svg:
        raise SystemExit("even-odd fill is not handled")
    ops = []
    for data in found:
        ops.extend(Parser(tokenize(data)).parse())
    return ops


def bounds(ops):
    xs, ys = [], []
    for op in ops:
        if op[0] == "close":
            continue
        coords = op[1:]
        xs.extend(coords[0::2])
        ys.extend(coords[1::2])
    return min(xs), min(ys), max(xs), max(ys)


def literal(value):
    rounded = round(value, 2)
    if abs(rounded - round(rounded)) < 1e-9:
        return str(int(round(rounded)))
    return f"{rounded:.2f}".rstrip("0").rstrip(".")


def emit_ops(ops):
    lines = []
    for op in ops:
        if op[0] == "move":
            lines.append(f"        .move({literal(op[1])}, {literal(op[2])}),")
        elif op[0] == "line":
            lines.append(f"        .line({literal(op[1])}, {literal(op[2])}),")
        elif op[0] == "cubic":
            nums = ", ".join(literal(value) for value in op[1:])
            lines.append(f"        .cubic({nums}),")
        elif op[0] == "close":
            lines.append("        .close,")
    return "\n".join(lines)


def main():
    arts = []
    for case, raw, stem in ICONS:
        for filled, folder, suffix in (
            (False, "regular", ""),
            (True, "fill", "-fill"),
        ):
            svg = fetch(f"{BASE}/{folder}/{stem}{suffix}.svg")
            ops = paths(svg)
            min_x, min_y, max_x, max_y = bounds(ops)
            if min_x < -1 or min_y < -1 or max_x > 257 or max_y > 257:
                raise SystemExit(f"{stem}{suffix} left the canvas: {bounds(ops)}")
            if max_x - min_x < 20 or max_y - min_y < 20:
                raise SystemExit(f"{stem}{suffix} parsed too small: {bounds(ops)}")
            weight = "Fill" if filled else "Regular"
            arts.append((case, filled, f"{case}{weight}", ops))
            print(f"{stem}{suffix}: {len(ops)} ops, bounds {min_x:.1f},{min_y:.1f} {max_x:.1f},{max_y:.1f}")

    cases = "\n".join(
        f"    case {case} = \"{raw}\"" if case != raw else f"    case {case}"
        for case, raw, _stem in ICONS
    )
    switch = []
    for case, filled, name, _ops in arts:
        flag = "true" if filled else "false"
        switch.append(f"        case (.{case}, {flag}): {name}")
    stored = []
    for _case, _filled, name, ops in arts:
        stored.append(f"    private static let {name} = GlyphArt([\n{emit_ops(ops)}\n    ])")

    text = f"""// Phosphor Icons, used for row, pin, remote, and menu-bar glyphs.
// https://github.com/phosphor-icons/core
//
// MIT License
//
// Copyright (c) 2023 Phosphor Icons
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Generated by scripts/vendor-phosphor.py. Each icon is a filled path on a
// 256×256 canvas. Regular is the outline weight; fill is the solid weight.

import CoreGraphics

enum GlyphID: String, CaseIterable {{
{cases}
}}

enum GlyphLibrary {{
    static func art(_ id: GlyphID, filled: Bool) -> GlyphArt {{
        switch (id, filled) {{
{chr(10).join(switch)}
        }}
    }}

{chr(10).join(stored)}
}}
"""
    OUT.write_text(text)
    print(f"wrote {OUT} ({len(text.splitlines())} lines)")


if __name__ == "__main__":
    main()
