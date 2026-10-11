#!/usr/bin/env python3
"""Adds Swift files to the Runner target of an Xcode project (next to
AppDelegate.swift: same group, same Sources phase). Idempotent.

  tool/xcode_add_swift.py apps/relay/macos/Runner.xcodeproj LoginItem.swift StatusMenu.swift
"""
import hashlib
import re
import sys

proj, files = sys.argv[1], sys.argv[2:]
path = f'{proj}/project.pbxproj'
s = open(path).read()


def oid(seed):
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


anchor_ref = re.search(r'\t\t(\w{24}) /\* AppDelegate\.swift \*/ = \{isa = PBXFileReference;[^\n]*\n', s)
anchor_build = re.search(r'\t\t(\w{24}) /\* AppDelegate\.swift in Sources \*/ = \{isa = PBXBuildFile;[^\n]*\n', s)
ref_id, build_id = anchor_ref.group(1), anchor_build.group(1)
for f in files:
    if f'/* {f} */ = {{isa = PBXFileReference' in s:
        continue
    r, b = oid(f'ref:{f}'), oid(f'build:{f}')
    s = s.replace(anchor_ref.group(0), anchor_ref.group(0) +
                  f'\t\t{r} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};\n')
    s = s.replace(anchor_build.group(0), anchor_build.group(0) +
                  f'\t\t{b} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {r} /* {f} */; }};\n')
    s = s.replace(f'\t\t\t\t{ref_id} /* AppDelegate.swift */,\n', f'\t\t\t\t{ref_id} /* AppDelegate.swift */,\n\t\t\t\t{r} /* {f} */,\n', 1)
    s = s.replace(f'\t\t\t\t{build_id} /* AppDelegate.swift in Sources */,\n',
                  f'\t\t\t\t{build_id} /* AppDelegate.swift in Sources */,\n\t\t\t\t{b} /* {f} in Sources */,\n', 1)
    print(f'added {f}')
open(path, 'w').write(s)
