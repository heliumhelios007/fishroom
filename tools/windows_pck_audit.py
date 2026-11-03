"""Audit the embedded PCK of the shipped Windows exe against the live runtime allowlist.

Read-only: parses the exe, never launches Godot.

Notes on the comparison model (learned from tools/android_package.py):
- Compiled scripts ship as ``<path>.gdc`` (script_export_mode=2) and/or ``.godot/exported/*.scn``.
- Source images/fonts ship as ``.godot/imported/<file>-<md5>.ctex|fontdata``, so the original
  ``assets/...png`` path is intentionally absent from the PCK. Comparing raw paths would
  report ~1400 false "missing" entries; coverage is asserted by 1:1 counts instead.
"""
import json
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from android_package import runtime_files  # noqa: E402
OUT = ROOT / "dist/windows-pck-audit.json"


def preset_export_count() -> dict:
    """Catch a stale preset after content was added without re-running prepare()."""
    text = (ROOT / "export_presets.cfg").read_text(encoding="utf-8-sig")
    section = re.search(r'\[preset\.\d+\]\s*\nname="Windows Desktop".*?(?=\n\[preset\.|\Z)', text, re.S)
    if section is None:
        return {"preset": "Windows Desktop", "present": 0, "runtime": len(runtime_files()),
                "missing": ["<preset missing>"], "stale": True}
    body = section.group(0)
    files = re.search(r'export_files=PackedStringArray\((.*?)\)', body, re.S)
    present = set(re.findall(r'"res://([^"]+)"', files.group(1))) if files else set()
    include = re.search(r'^include_filter="([^"]*)"', body, re.M)
    if include:
        present.update(x for x in include.group(1).split(",") if x.strip())
    present.add("project.godot")
    runtime = set(runtime_files())
    missing = sorted(runtime - present)
    return {"preset": "Windows Desktop", "present": len(present), "runtime": len(runtime),
            "missing": missing, "stale": bool(missing)}

FORBIDDEN = re.compile(
    r"(^|/)(logs?|docs?|tests?|integrations|companion_core|memory_service|addons|autoload|debug"
    r"|\.dshwolf|Godot|output|build|tools)(/|$)"
    r"|(^|/)(save[^/]*\.json|connection\.json|persona\.md|.*\.keystore|.*\.jsonl)$",
    re.I,
)
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".webp", ".otf", ".ttf", ".svg")


def pck_names(data: bytes, start: int):
    assert data[start:start + 4] == b"GDPC", "Unknown PCK header"
    version, = struct.unpack_from("<I", data, start + 4)
    flags, = struct.unpack_from("<I", data, start + 20)
    assert not flags & 1, "Encrypted directory cannot be audited"
    offset = start + (96 if version == 2 else struct.unpack_from("<Q", data, start + 32)[0])
    count, = struct.unpack_from("<I", data, offset)
    offset += 4
    names = []
    for _ in range(count):
        length, = struct.unpack_from("<I", data, offset)
        offset += 4
        names.append(data[offset:offset + length].rstrip(b"\0").decode("utf-8").removeprefix("res://"))
        offset += length + 8 + 8 + 16 + 4
    return version, names


def assert_clean_autoload() -> None:
    """The bridge can re-add McpInteractionServer to project.godot after a run."""
    text = (ROOT / "project.godot").read_text(encoding="utf-8-sig")
    block = re.search(r'^\[autoload\]\s*(.*?)(?=^\[|\Z)', text, re.M | re.S)
    if block is None:
        raise SystemExit("AUTOLOAD_SECTION_MISSING")
    if "McpInteractionServer" in block.group(1):
        raise SystemExit("DIRTY_AUTOLOAD: remove McpInteractionServer before export")


def find_pck(data: bytes):
    idx = data.rfind(b"GDPC")
    while idx != -1:
        try:
            version, names = pck_names(data, idx)
            if len(names) > 100:
                return idx, version, names
        except Exception:
            pass
        idx = data.rfind(b"GDPC", 0, idx)
    raise SystemExit("no parseable embedded PCK found")


def main(exe: Path):
    assert_clean_autoload()
    data = exe.read_bytes()
    start, version, names = find_pck(data)

    runtime = set(runtime_files())
    shipped_runtime = {n[:-1] if n.endswith(".gdc") else n for n in names}
    generated = lambda n: (n.startswith(".godot/imported/") or n.startswith(".godot/exported/")
                           or n in ("_cl_", "project.binary", ".godot/uid_cache.bin",
                                    ".godot/global_script_class_cache.cfg"))
    allowed = (runtime | {n + ".import" for n in runtime} | {n + ".remap" for n in runtime}
               | {n.removesuffix(".gd") + ".gdc" for n in runtime if n.endswith(".gd")})
    unknown = [n for n in names if n not in allowed and not generated(n)]

    scripts_expected = {n for n in runtime if n.endswith(".gd")}
    scripts_shipped = {n for n in shipped_runtime if n.startswith(("scripts/", "scenes/")) and n.endswith(".gd")}
    images_expected = {n for n in runtime if n.lower().endswith(IMAGE_EXT)}
    imported = [n for n in names if n.startswith(".godot/imported/")]

    preset = preset_export_count()
    report = {
        "exe": str(exe),
        "exe_bytes": len(data),
        "exe_sha256_note": "hash recorded by caller",
        "pck_offset": start,
        "pck_version": version,
        "pck_entries": len(names),
        "runtime_allowlist_entries": len(runtime),
        "forbidden": [n for n in names if FORBIDDEN.search(n)],
        "unknown": unknown,
        "debug_entries": [n for n in names if "mcp" in n.lower() or "dev_panel" in n.lower()],
        "scripts_expected": len(scripts_expected),
        "scripts_shipped": len(scripts_shipped),
        "scripts_missing": sorted(scripts_expected - scripts_shipped),
        "json_expected": sorted(n for n in runtime if n.endswith(".json")),
        "json_shipped": sorted(n for n in names if n.endswith(".json")),
        "images_expected": len(images_expected),
        "imported_payloads": len(imported),
        "preset_freshness": preset,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: (v if not isinstance(v, list) else (f"{len(v)} items" if len(v) > 3 else v))
                      for k, v in report.items()}, ensure_ascii=False, indent=1))
    if preset["stale"]:
        raise SystemExit("STALE_EXPORT_PRESET: rerun tools/android_package.py prepare before export")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
