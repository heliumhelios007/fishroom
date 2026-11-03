"""Build the outer Windows release ZIP.

Player-facing files stay at their documented paths; maintainer-only documents
are segregated under maintainer/. LICENSE and THIRD_PARTY_NOTICES.md are always
included because README links them and MIT requires the notice with binaries.
"""
from pathlib import Path
import argparse
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_VERSION = "1.1.2"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=DEFAULT_VERSION)
    version = parser.parse_args().version
    out = ROOT / f"dist/fishroom-windows-v{version}.zip"
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    readme = readme.replace("docs/PROJECT_HANDOFF.md", "maintainer/PROJECT_HANDOFF.md")
    assert "maintainer/PROJECT_HANDOFF.md" in readme, "README handoff link rewrite did not match"
    files = {
        "fishroom.exe": ROOT / "dist/fishroom-fixed/fishroom.exe",
        "README.md": readme,
        "LICENSE": ROOT / "LICENSE",
        "THIRD_PARTY_NOTICES.md": ROOT / "THIRD_PARTY_NOTICES.md",
        "docs/PLAYER_DSH_QQ_SETUP.md": ROOT / "docs/PLAYER_DSH_QQ_SETUP.md",
        "docs/MODDING_GUIDE.md": ROOT / "docs/MODDING_GUIDE.md",
        "maintainer/PROJECT_HANDOFF.md": ROOT / "docs/PROJECT_HANDOFF.md",
        "maintainer/AGENTS.md": ROOT / "AGENTS.md",
        "maintainer/STAGE_STATUS.md": ROOT / "docs/STAGE_STATUS.md",
        "licenses/CHARACTER_CREDITS.md": ROOT / "assets/character/dsh_pet/CREDITS.md",
    }
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, path in files.items():
            if isinstance(path, str):
                z.writestr(name, path.encode("utf-8"))
            else:
                if not path.is_file():
                    raise SystemExit(f"missing release input: {path}")
                z.write(path, name)
    print(out)
    print("\n".join(zipfile.ZipFile(out).namelist()))


if __name__ == "__main__":
    main()
