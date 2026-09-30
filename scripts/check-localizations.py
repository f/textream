#!/usr/bin/env python3
"""Check macOS localization syntax, key coverage, and format parity without Xcode."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "Textream" / "Textream"
ENTRY = re.compile(r'\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;')
FORMAT = re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGcCsSp%]')


def read_table(path):
    text = path.read_text(encoding="utf-8")
    entries = {}
    pos = 0
    while text[pos:].strip():
        match = ENTRY.match(text, pos)
        assert match, f"Invalid .strings entry in {path} near offset {pos}"
        key, value = map(json.loads, match.groups())
        assert key not in entries, f"Duplicate key {key} in {path}"
        entries[key] = value
        pos = match.end()
    return entries


english = read_table(ROOT / "en.lproj/Localizable.strings")
chinese = read_table(ROOT / "zh-Hans.lproj/Localizable.strings")
assert english.keys() == chinese.keys(), "Localization keys differ between languages"
for key in english:
    assert FORMAT.findall(english[key]) == FORMAT.findall(chinese[key]), f"Format mismatch: {key}"
for name in ["InfoPlist.strings"]:
    en = read_table(ROOT / "en.lproj" / name)
    zh = read_table(ROOT / "zh-Hans.lproj" / name)
    assert en.keys() == zh.keys(), f"Keys differ in {name}"

# Include web dictionaries and SwiftUI's literal localization keys as well as L10n calls.
prefixes = {key.split('.')[0] for key in english if '.' in key}
used = set()
for path in ROOT.glob("*.swift"):
    source = path.read_text(encoding="utf-8")
    used.update(re.findall(r'L10n\.(?:string|format)\("([^"]+)"', source))
    used.update(key for key in re.findall(r'"([A-Za-z][A-Za-z0-9.]+)"', source)
                if '.' in key and key.split('.')[0] in prefixes)
assert not (used - english.keys()), f"Missing localization keys: {sorted(used - english.keys())}"
for name in ["BrowserServer.swift", "DirectorServer.swift"]:
    source = (ROOT / name).read_text(encoding="utf-8")
    assert 'let lang = L10n.webLanguageCode\n        return """' in source, f"Missing HTML return in {name}"
print(f"Validated {len(english)} translations, {len(used)} used keys, InfoPlist parity, and HTML returns")
