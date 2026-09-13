#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo=$PWD
if ! command -v node >/dev/null 2>&1; then
  for node_dir in "$repo"/deps/build-tools/node-*-darwin-arm64/bin; do
    if [ -x "$node_dir/node" ]; then
      export PATH="$node_dir:$PATH"
      break
    fi
  done
fi
export IOS_CERTID="${IOS_CERTID:--}"
export npm_config_cache="$repo/deps/npm-cache"
export FRIDA_VERSION
FRIDA_VERSION=$(python3 releng/frida_version.py)

if [ ! -f build/build.ninja ]; then
  ./configure --prefix=/usr --host=ios-arm64e \
    --enable-server --disable-gadget --disable-inject \
    --disable-frida-python --disable-frida-tools --disable-graft-tool \
    -- -Dfrida-core:assets=installed -Dfrida-core:compiler_backend=disabled
else
  python3 - <<'PY'
import json
from pathlib import Path

info = Path('build/meson-info')
options = {o['name']: o['value'] for o in json.loads((info / 'intro-buildoptions.json').read_text())}
expected = {'prefix': '/usr', 'server': 'enabled', 'frida-core:assets': 'installed',
            'frida-core:compiler_backend': 'disabled'}
for key, value in expected.items():
    if options.get(key) != value:
        raise SystemExit(f'Existing build has incompatible {key}: {options.get(key)!r}')
machine = Path('build/frida-ios-arm64e.txt')
if not machine.is_file():
    raise SystemExit('Existing build is not configured for ios-arm64e')
PY
fi
make

stage=$(mktemp -d "$repo/build/roothide-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
DESTDIR="$stage" make install

# AssetLocation resolves the agent relative to the executable, so the package
# can be relocated into RootHide's randomized jbroot without a /var/jb prefix.
server="$stage/usr/bin/frida-server"
agent="$stage/usr/lib/frida-1.0/frida-agent.dylib"
for binary in "$server" "$agent"; do
  lipo "$binary" -verify_arch arm64 arm64e
done

# Preserve Frida's existing entitlements and add RootHide's required access.
python3 - "$repo" "$stage" <<'PY'
from pathlib import Path
import plistlib
import sys

repo, stage = map(Path, sys.argv[1:])
with (repo / 'subprojects/frida-core/server/frida-server.xcent').open('rb') as f:
    entitlements = plistlib.load(f)
for key in ('platform-application',
            'com.apple.private.security.no-sandbox',
            'com.apple.private.security.storage.AppBundles',
            'com.apple.private.security.storage.AppDataContainers'):
    entitlements[key] = True
with (stage / 'roothide.xcent').open('wb') as f:
    plistlib.dump(entitlements, f)
PY
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements "$stage/roothide.xcent" "$server"
codesign --force --sign - --timestamp=none "$agent"
codesign --verify --strict --all-architectures "$server"
codesign --verify --strict --all-architectures "$agent"

mkdir -p "$repo/build/release-assets"
output="$repo/build/release-assets/frida_${FRIDA_VERSION}_iphoneos-arm64e.deb"
/bin/sh -e subprojects/frida-core/tools/package-server-fruity.sh \
  iphoneos-arm64e "$stage" "$output"
dpkg-deb --info "$output"
shasum -a 256 "$output"
