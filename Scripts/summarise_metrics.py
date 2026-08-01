#!/usr/bin/env python3
"""Summarise Murmur's local session-metrics log against the 10x plan targets.

Reads the JSON-lines file written by SessionMetricsRecorder and prints the
metric table from docs/plans/2026-07-30-10x-plan.md filled in with real
measurements.

Loads no models and starts no Swift build — safe to run anywhere, including
the development Mac mini.

Usage:
    python3 Scripts/summarise_metrics.py [path/to/session-metrics.jsonl]
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any


DEFAULT_PATH = os.path.expanduser(
    "~/Library/Application Support/Murmur/session-metrics.jsonl"
)


def load(path: str) -> list[dict[str, Any]]:
    if not os.path.exists(path):
        print(f"No metrics file at {path}")
        print("Run some dictation sessions first — metrics are written locally.")
        sys.exit(0)

    records: list[dict[str, Any]] = []
    skipped = 0
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                # A torn final line from a crash costs one session, not the file.
                skipped += 1
    if skipped:
        print(f"note: skipped {skipped} malformed line(s)\n")
    return records


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(round((pct / 100.0) * (len(ordered) - 1))))
    return ordered[idx]


def collect(records: list[dict[str, Any]], key: str, mode: str | None = None) -> list[float]:
    out = []
    for record in records:
        if mode is not None and record.get("mode") != mode:
            continue
        value = record.get(key)
        if isinstance(value, (int, float)):
            out.append(float(value))
    return out


def fmt_ms(value: float | None) -> str:
    return "—" if value is None else f"{value:.0f} ms"


def fmt_pct(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.2f}%"


def verdict(actual: float | None, target: float, lower_is_better: bool = True) -> str:
    if actual is None:
        return "no data"
    ok = actual <= target if lower_is_better else actual >= target
    return "MEETS" if ok else "MISSES"


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
    records = load(path)
    if not records:
        print("Metrics file is empty.")
        return

    injected = [r for r in records if r.get("outcome") == "injected"]
    v3 = [r for r in injected if r.get("mode") == "v3"]

    stop_to_final = collect(injected, "stopToFinalTextMs")
    ttfw = collect(v3, "timeToFirstWordMs")
    edit = collect(v3, "editDistanceRatio")

    p50_final = percentile(stop_to_final, 50)
    p50_ttfw = percentile(ttfw, 50)
    p50_edit = percentile(edit, 50)

    gated = sum(1 for r in records if r.get("outcome") == "silenceGated")
    failed = sum(1 for r in records if r.get("outcome") == "failed")
    fallbacks = sum(1 for r in records if r.get("cpuFallback"))

    print(f"Murmur session metrics — {len(records)} session(s) from {path}\n")
    print(f"{'Metric':<38} {'p50':>10} {'p95':>10}  {'Target':>10}  Verdict")
    print("-" * 88)
    print(
        f"{'Stop → final text':<38} {fmt_ms(p50_final):>10} "
        f"{fmt_ms(percentile(stop_to_final, 95)):>10}  {'< 700 ms':>10}  "
        f"{verdict(p50_final, 700)}"
    )
    print(
        f"{'Time to first word (streaming)':<38} {fmt_ms(p50_ttfw):>10} "
        f"{fmt_ms(percentile(ttfw, 95)):>10}  {'< 1000 ms':>10}  "
        f"{verdict(p50_ttfw, 1000)}"
    )
    print(
        f"{'Streamed vs final edit distance':<38} {fmt_pct(p50_edit):>10} "
        f"{fmt_pct(percentile(edit, 95)):>10}  {'< 1%':>10}  "
        f"{verdict(p50_edit, 0.01)}"
    )
    print("-" * 88)
    print(f"\nSessions: {len(injected)} injected, {gated} silence-gated, {failed} failed")
    print(f"CPU fallbacks: {fallbacks}")
    if gated:
        print(
            "\nNote: silence-gated sessions are recordings the gate discarded. "
            "A rising count is the 0.4.x dropped-utterance class of bug."
        )


if __name__ == "__main__":
    main()
