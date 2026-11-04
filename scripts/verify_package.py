"""Verify delivered bytes and native-project/IP file dependencies. Python stdlib only."""
from pathlib import Path
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def resolve(base, value):
    path = (base / value.replace('\\', '/')).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError('Reference escapes release root: ' + value)
    return path


def main():
    manifest = json.loads((ROOT / 'MANIFEST.sha256.json').read_text('utf-8'))
    errors = []
    for item in manifest['files']:
        path = resolve(ROOT, item['path'])
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
            errors.append('Missing/changed: ' + item['path'])
    refs = 0
    for board in manifest['boards']:
        project = ROOT / board / 'td_project/camera_to_dsi_display.al'
        text = project.read_text('utf-8-sig')
        for value in re.findall(r'<File\s+Path="([^"]+)"', text):
            refs += 1
            if not resolve(project.parent, value).is_file():
                errors.append('Native project dependency: ' + value)
        for xml in (ROOT / board / 'user_source').rglob('*.xml'):
            for node in ET.parse(xml).getroot().iter():
                if node.tag.rsplit('}', 1)[-1] != 'file':
                    continue
                for child in node:
                    if child.tag.rsplit('}', 1)[-1] == 'name' and child.text:
                        refs += 1
                        if not resolve(xml.parent, child.text).is_file():
                            errors.append('IP dependency: ' + child.text)
    if errors:
        print('FAIL\n' + '\n'.join(errors))
        return 1
    print(f"PASS: {len(manifest['files'])} file hashes; {refs} native/IP dependencies. No FPGA build or hardware test.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
