"""Prepare Android allowlist and audit actual APK/PCK. Never launches Godot."""
from pathlib import Path
import argparse, hashlib, json, re, struct, zipfile

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = re.compile(r'(^|/)(logs?|docs?|tests?|integrations|companion_core|memory_service|addons|autoload|debug|\.dshwolf|Godot|output|build|tools)(/|$)|(^|/)(save[^/]*\.json|connection\.json|persona\.md|.*\.keystore|.*\.jsonl)$', re.I)

def runtime_files():
    files = {"project.godot"}
    for directory in ("scripts", "scenes"):
        files.update(p.relative_to(ROOT).as_posix() for p in (ROOT / directory).rglob("*")
                     if p.is_file() and p.suffix in (".gd", ".tscn") and "debug" not in p.parts)
    files.update(p.relative_to(ROOT).as_posix() for p in (ROOT / "data").glob("*.json"))
    # Follow code/scene/JSON resource references, including dynamically loaded frames.
    queue = list(files)
    while queue:
        name = queue.pop()
        path = ROOT / name
        if path.suffix not in (".gd", ".tscn", ".json", ".tres", ".godot"):
            continue
        text = path.read_text(encoding="utf-8-sig")
        for ref in re.findall(r'res://(assets/[^"\s]+)', text):
            if (ROOT / ref).is_file() and ref not in files:
                files.add(ref)
                queue.append(ref)
    # ContentManager builds these canonical paths from components.
    for ref in ("assets/furniture/furniture_manifest.json",):
        if ref not in files:
            files.add(ref)
            queue.append(ref)
    while queue:
        name = queue.pop()
        for ref in re.findall(r'res://(assets/[^"\s]+)', (ROOT / name).read_text(encoding="utf-8-sig")):
            if (ROOT / ref).is_file() and ref not in files:
                files.add(ref)
                if Path(ref).suffix in (".json", ".tres"):
                    queue.append(ref)
    assert not any(FORBIDDEN.search(f) for f in files), "Forbidden runtime dependency"
    return sorted(files)

def prepare():
    files = runtime_files()
    resources = ["res://" + f for f in files if Path(f).suffix not in (".json", ".godot")]
    includes = [f for f in files if f.endswith(".json")]
    cfg = ROOT / "export_presets.cfg"
    text = cfg.read_text(encoding="utf-8-sig")
    # Own preset.1 only; retain later presets such as Windows Desktop.
    following = re.search(r'\n\[preset\.(?!1\])\d+\]\s*\n', text.split('[preset.1]', 1)[1])
    android_tail = text.split('[preset.1]', 1)[1]
    later_presets = android_tail[following.start():] if following else ''
    text = text.split("[preset.1]")[0].rstrip()
    text += '\n\n[preset.1]\n\nname="Android Debug"\nplatform="Android"\nrunnable=true\n'
    text += 'custom_features="fishroom_clean"\nexport_filter="resources"\n'
    text += 'export_files=PackedStringArray(' + ', '.join(json.dumps(f) for f in resources) + ')\n'
    text += 'include_filter=' + json.dumps(','.join(includes)) + '\n'
    excludes = ['logs/*','docs/*','tests/*','.dshwolf/*','integrations/*','companion_core/*','addons/*','autoload/*','tools/*','Godot/*','output/*','build/*','dist/*','scripts/debug/*','scenes/debug/*','assets/ui/reference/*','*.md','*.bak*','*.tmp','*.log','*.jsonl','*save*.json','*connection*.json','*.keystore']
    text += 'exclude_filter=' + json.dumps(','.join(excludes)) + '\n'
    text += 'export_path="dist/fishroom-debug.apk"\npatches=PackedStringArray()\nencryption_include_filters=""\nencryption_exclude_filters=""\nencrypt_pck=false\nencrypt_directory=false\nscript_export_mode=2\n\n[preset.1.options]\n\n'
    text += '''custom_template/debug=""
custom_template/release=""
gradle_build/use_gradle_build=false
gradle_build/export_format=0
gradle_build/min_sdk=""
gradle_build/target_sdk=""
architectures/armeabi-v7a=true
architectures/arm64-v8a=true
architectures/x86=false
architectures/x86_64=false
version/code=1
version/name="1.0.0"
package/unique_name="com.fishroom.game"
package/name="fishroom"
package/signed=true
package/app_category=0
package/retain_data_on_uninstall=false
package/exclude_from_recents=false
package/show_in_android_tv=false
package/show_in_app_library=true
permissions/internet=true
permissions/access_network_state=true
permissions/read_external_storage=false
permissions/write_external_storage=false
user_data_backup/allow=false
screen/immersive_mode=true
screen/support_small=true
screen/support_normal=true
screen/support_large=true
screen/support_xlarge=true
'''
    cfg.write_text(text.rstrip() + '\n' + later_presets, encoding="utf-8")
    out = ROOT / "dist"
    out.mkdir(exist_ok=True)
    rows = [{"path":f,"sha256":hashlib.sha256((ROOT/f).read_bytes()).hexdigest()} for f in files]
    (out / "android-runtime-allowlist.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    imports = []
    for name in files:
        if Path(name).suffix in (".png", ".jpg", ".webp", ".otf", ".ttf"):
            sidecar = ROOT / (name + ".import")
            assert sidecar.is_file(), f"Missing formal .import: {name}"
            text = sidecar.read_text(encoding="utf-8-sig")
            destinations = re.findall(r'path(?:\.[a-z0-9_]+)?="res://([^"\n]+)"',text)
            assert destinations, f"Missing imported output: {name}"
            assert all((ROOT/p).is_file() for p in destinations), f"Missing import cache: {name}"
            imports.append(name)
    travel = [f for f in imports if f.startswith("assets/travel/")]
    assert len(travel) == 7, f"Expected 7 formal travel images, got {len(travel)}"
    print(json.dumps({"runtime_files":len(files),"formal_imports":len(imports),"travel_images":len(travel),"forbidden_files":0}))

def pck_names(data):
    assert data[:4] == b'GDPC', 'Unknown PCK header'
    version, = struct.unpack_from('<I',data,4)
    assert version in (2,3,4), f'Unsupported PCK format {version}; inspect manually'
    # Godot 4 PCK: magic/version/engine[3]/flags/file_base/reserved[16]/count.
    flags, = struct.unpack_from('<I',data,20)
    assert not flags & 1, 'Encrypted directory cannot be audited'
    offset = 96 if version == 2 else struct.unpack_from('<Q',data,32)[0]
    count, = struct.unpack_from('<I',data,offset)
    offset += 4
    result=[]
    for _ in range(count):
        length, = struct.unpack_from('<I',data,offset)
        offset += 4
        name=data[offset:offset+length].rstrip(b'\0').decode('utf-8')
        offset += length + 8 + 8 + 16 + 4
        result.append(name.removeprefix('res://'))
    return result

def audit(apk):
    with zipfile.ZipFile(apk) as z:
        outer=z.namelist()
        assert not any(FORBIDDEN.search(f) for f in outer), 'Forbidden file in APK ZIP entries'
        content=[]
        for name in outer:
            if name.startswith('assets/'):
                content.append(name.removeprefix('assets/'))
                if name.endswith(('.pck', '.sparsepck')):
                    content.extend(pck_names(z.read(name)))
        assert content, 'No game payload found'
        forbidden=[f for f in content if FORBIDDEN.search(f)]
        assert not forbidden, f'Forbidden APK payload: {forbidden}'
        assert not any('mcp_interaction_server' in f or 'dev_panel' in f for f in content), 'Debug entry included'
        allowed=set(runtime_files())
        allowed |= {f+'.remap' for f in allowed} | {f+'.import' for f in allowed}
        # Godot generated imported resources and compiled scripts are expected.
        generated=lambda f: (f.startswith('.godot/imported/') and Path(f).suffix in ('.ctex','.fontdata','.sample','.oggvorbisstr','.mp3str')) or (f.startswith('.godot/exported/') and Path(f).suffix in ('.gdc','.scn','.res'))
        unknown=[f for f in content if f not in allowed and not generated(f) and not f.endswith(('.pck','.sparsepck')) and f not in ('_cl_','project.binary','.godot/uid_cache.bin','.godot/global_script_class_cache.cfg') and not (f.endswith('.gdc') and f[:-1] in allowed)]
        assert not unknown, f'Unreviewed APK game payload: {unknown}'
    report={"apk":Path(apk).name,"sha256":hashlib.sha256(Path(apk).read_bytes()).hexdigest(),"zip_entries":outer,"game_entries":content,"forbidden":forbidden,"unknown":unknown}
    (ROOT/'dist/android-apk-audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({"apk":report['apk'],"game_entries":len(content),"forbidden":0,"unknown":0}))

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--audit',type=Path)
    args=parser.parse_args()
    audit(args.audit) if args.audit else prepare()
