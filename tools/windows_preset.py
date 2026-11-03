"""Regenerate the Windows preset export_files from the live runtime set.

Run after adding/removing runtime resources and before exporting Windows.
This does not launch Godot and does not touch the Android preset.
"""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from android_package import runtime_files  # noqa: E402


def main() -> None:
    cfg = ROOT / "export_presets.cfg"
    text = cfg.read_text(encoding="utf-8-sig")
    start = text.index("[preset.2]")
    end = text.find("\n[preset.", start + 1)
    end = len(text) if end < 0 else end
    section = text[start:end]
    files = runtime_files()
    array = "PackedStringArray(" + ", ".join(json.dumps("res://" + f) for f in files) + ")"
    updated, count = re.subn(
        r"export_files=PackedStringArray\(.*?\)\n",
        "export_files=" + array + "\n",
        section,
        count=1,
        flags=re.S,
    )
    if count != 1:
        raise SystemExit("Windows preset has no export_files line; refusing to edit")
    cfg.with_suffix(".cfg.bak-freshness").write_text(text, encoding="utf-8-sig")
    cfg.write_text(text[:start] + updated + text[end:], encoding="utf-8-sig")
    print(json.dumps({"runtime_files": len(files), "preset": "Windows Desktop", "updated": True}))


if __name__ == "__main__":
    main()
