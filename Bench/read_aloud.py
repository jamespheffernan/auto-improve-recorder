#!/usr/bin/env python3
"""Prepare and record a read-aloud benchmark corpus."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
import time
import wave
from pathlib import Path
from typing import Any


DEFAULT_ITEMS = Path(__file__).with_name("read_aloud_items.json")
DEFAULT_ROOT = Path(".autoresearch/read-aloud-corpus")
DEFAULT_MANIFEST = Path(".autoresearch/read-aloud.corpus.json")


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")


def load_items(path: Path) -> list[dict[str, Any]]:
    raw = load_json(path)
    items = raw["items"] if isinstance(raw, dict) else raw
    seen: set[str] = set()
    parsed: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            raise SystemExit(f"Invalid item in {path}: {item!r}")
        item_id = str(item.get("id", "")).strip()
        if not item_id:
            raise SystemExit(f"Item is missing id: {item!r}")
        if item_id in seen:
            raise SystemExit(f"Duplicate read-aloud item id: {item_id}")
        seen.add(item_id)
        for key in ("read_transcript", "reference_improved", "title"):
            if not str(item.get(key, "")).strip():
                raise SystemExit(f"Item {item_id} is missing {key}")
        parsed.append(item)
    return parsed


def audio_duration_seconds(path: Path) -> float | None:
    try:
        with wave.open(str(path), "rb") as wav:
            return wav.getnframes() / float(wav.getframerate())
    except Exception:
        return None


def item_dir(root: Path, item_id: str) -> Path:
    return root / item_id


def select_items(
    items: list[dict[str, Any]],
    item_ids: list[str] | None,
    limit: int | None,
) -> list[dict[str, Any]]:
    if item_ids:
        wanted = set(item_ids)
        items = [item for item in items if item["id"] in wanted]
        missing = wanted - {item["id"] for item in items}
        if missing:
            raise SystemExit(f"Unknown item id(s): {', '.join(sorted(missing))}")
    if limit is not None:
        items = items[:limit]
    return items


def prepare(args: argparse.Namespace) -> None:
    items = load_items(Path(args.items))
    root = Path(args.root)
    manifest_path = Path(args.manifest)
    root.mkdir(parents=True, exist_ok=True)

    manifest_items: list[dict[str, Any]] = []
    for item in items:
        folder = item_dir(root, item["id"])
        folder.mkdir(parents=True, exist_ok=True)
        audio_path = folder / "audio.wav"
        (folder / "read_transcript.txt").write_text(item["read_transcript"].strip() + "\n", encoding="utf-8")
        (folder / "reference_improved.txt").write_text(item["reference_improved"].strip() + "\n", encoding="utf-8")
        (folder / "prompt.md").write_text(
            f"# {item['title']}\n\n"
            "Read this exactly, including filler words and corrections.\n\n"
            f"{item['read_transcript'].strip()}\n",
            encoding="utf-8",
        )
        manifest_items.append(
            {
                "id": item["id"],
                "audio": str(audio_path),
                "reference_transcript": item["read_transcript"].strip(),
                "improvement_input": item["read_transcript"].strip(),
                "reference_improved": item["reference_improved"].strip(),
                "metadata": {
                    "category": item.get("category"),
                    "prompt_markdown": str(folder / "prompt.md"),
                    "read_transcript_path": str(folder / "read_transcript.txt"),
                    "reference_improved_path": str(folder / "reference_improved.txt"),
                    "title": item["title"],
                },
            }
        )

    write_json(manifest_path, {"items": manifest_items})
    print(f"Wrote {len(manifest_items)} read-aloud items under {root}")
    print(f"Wrote corpus manifest to {manifest_path}")


def devices(_: argparse.Namespace) -> None:
    cmd = ["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""]
    subprocess.run(cmd, check=False)


def load_manifest(path: Path) -> list[dict[str, Any]]:
    raw = load_json(path)
    return raw["items"] if isinstance(raw, dict) else raw


def print_script(item: dict[str, Any]) -> None:
    title = item.get("metadata", {}).get("title") or item["id"]
    text = item["reference_transcript"]
    print("\n" + "=" * 80)
    print(f"{item['id']} - {title}")
    print("=" * 80)
    print(text)
    print("=" * 80)


def record(args: argparse.Namespace) -> None:
    if args.device is None:
        raise SystemExit("Pass --device with an AVFoundation audio device index or name. Run `Bench/read_aloud.py devices` first.")

    manifest = load_manifest(Path(args.manifest))
    items = select_items(manifest, args.item, args.limit)
    if not items:
        raise SystemExit("No items selected.")

    for item in items:
        audio_path = Path(item["audio"])
        audio_path.parent.mkdir(parents=True, exist_ok=True)
        if audio_path.exists() and not args.overwrite:
            print(f"Skipping existing recording: {audio_path}")
            continue

        print_script(item)
        input("Press Enter, start reading after the recording begins, then press Enter here again when finished.")
        cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "warning",
            "-f",
            "avfoundation",
            "-i",
            f":{args.device}",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-sample_fmt",
            "s16",
            "-y",
            str(audio_path),
        ]
        started = time.perf_counter()
        process = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        try:
            input("Recording. Press Enter to stop.")
            if process.stdin:
                process.stdin.write(b"q\n")
                process.stdin.flush()
            process.wait(timeout=8)
        except KeyboardInterrupt:
            process.terminate()
            process.wait(timeout=8)
            raise
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=8)

        elapsed = time.perf_counter() - started
        duration = audio_duration_seconds(audio_path)
        meta = {
            "device": args.device,
            "duration_seconds": duration,
            "elapsed_wall_seconds": elapsed,
            "item_id": item["id"],
            "recorded_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        }
        write_json(audio_path.parent / "recording_meta.json", meta)
        print(f"Saved {audio_path} ({duration or elapsed:.1f}s)")


def status(args: argparse.Namespace) -> None:
    manifest = load_manifest(Path(args.manifest))
    total = len(manifest)
    present = 0
    for item in manifest:
        audio_path = Path(item["audio"])
        exists = audio_path.exists()
        present += 1 if exists else 0
        duration = audio_duration_seconds(audio_path) if exists else None
        marker = "ok" if exists else "missing"
        detail = f"{duration:.1f}s" if duration else ""
        print(f"{marker:7} {item['id']:<28} {detail}")
    print(f"\n{present}/{total} recordings present")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("prepare", help="write prompt files and a model_eval corpus manifest")
    p.add_argument("--items", default=str(DEFAULT_ITEMS))
    p.add_argument("--root", default=str(DEFAULT_ROOT))
    p.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    p.set_defaults(func=prepare)

    p = sub.add_parser("devices", help="list ffmpeg AVFoundation audio devices")
    p.set_defaults(func=devices)

    p = sub.add_parser("record", help="record selected read-aloud items with ffmpeg")
    p.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    p.add_argument("--device", help="AVFoundation audio device index or name, for example 4")
    p.add_argument("--item", action="append", help="item id; repeat to select several")
    p.add_argument("--limit", type=int)
    p.add_argument("--overwrite", action="store_true")
    p.set_defaults(func=record)

    p = sub.add_parser("status", help="show which read-aloud items have audio")
    p.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    p.set_defaults(func=status)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
