#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo=$PWD
if [ "$(uname -s)" != Darwin ]; then
  echo "RootHide builds require macOS and Xcode." >&2
  exit 1
fi
for tool in git python3 make xcrun codesign lipo dpkg-deb curl shasum tar; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null

# Keep the build-time Node.js/npm installation local to this checkout.
if ! command -v node >/dev/null 2>&1 ||
   ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' ||
   ! command -v npm >/dev/null 2>&1; then
  node_version=22.23.2
  case "$(uname -m)" in
    arm64) node_arch=arm64; node_sha=61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6 ;;
    x86_64) node_arch=x64; node_sha=58e99022c2ff89395576cc7fd4d98cea24bb68081475d5f88b801ee8729fb026 ;;
    *) echo "Unsupported build architecture" >&2; exit 1 ;;
  esac
  node_name="node-v${node_version}-darwin-${node_arch}"
  node_root="$repo/deps/build-tools"
  mkdir -p "$node_root"
  if [ ! -x "$node_root/$node_name/bin/node" ]; then
    archive="$node_root/$node_name.tar.gz"
    curl -fL --retry 3 --connect-timeout 20 \
      "https://nodejs.org/dist/v${node_version}/$node_name.tar.gz" -o "$archive"
    echo "$node_sha  $archive" | shasum -a 256 -c -
    tar -xzf "$archive" -C "$node_root"
    rm "$archive"
  fi
  export PATH="$node_root/$node_name/bin:$PATH"
fi
node --version
npm --version
export IOS_CERTID="${IOS_CERTID:--}"
export npm_config_cache="$repo/deps/npm-cache"
export FRIDA_VERSION
# Local build-script commits must not bump the upstream release version.
FRIDA_VERSION=$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*')

# Fail early if this checkout no longer has the requested port configuration.
python3 - <<'PY'
from pathlib import Path
import re

base = Path('subprojects/frida-core')
checks = {
    'lib/base/socket.vala': {'DEFAULT_CONTROL_PORT': 2909, 'DEFAULT_CLUSTER_PORT': 27052},
    'lib/base/p2p.vala': {'sctp_port': 5000},
}
for filename, values in checks.items():
    source = (base / filename).read_text()
    for name, value in values.items():
        if not re.search(r'\b' + name + r'\s*=\s*' + str(value) + r'\s*;', source):
            raise SystemExit(f'Expected {name} = {value} in {filename}')
PY

if [ ! -f build/build.ninja ]; then
  ./configure --prefix=/usr --host=ios-arm64e \
    --enable-server --disable-gadget --disable-inject \
    --disable-frida-python --disable-frida-tools --disable-graft-tool \
    -- -Dfrida-core:assets=installed -Dfrida-core:compiler_backend=disabled \
    -Dfrida-core:frida_version="$FRIDA_VERSION" -Dfrida-gum:frida_version="$FRIDA_VERSION"
else
  python3 - <<'PY'
import json
from pathlib import Path

info = Path('build/meson-info')
options = {o['name']: o['value'] for o in json.loads((info / 'intro-buildoptions.json').read_text())}
expected = {'prefix': '/usr', 'server': 'enabled', 'frida-core:assets': 'installed',
            'frida-core:compiler_backend': 'disabled', 'gadget': 'disabled',
            'inject': 'disabled', 'frida_python': 'disabled', 'frida_tools': 'disabled',
            'graft_tool': 'disabled'}
for key, value in expected.items():
    if options.get(key) != value:
        raise SystemExit(f'Existing build has incompatible {key}: {options.get(key)!r}')
machine = Path('build/frida-ios-arm64e.txt')
if not machine.is_file():
    raise SystemExit('Existing build is not configured for ios-arm64e')
PY
  python3 releng/meson/meson.py configure build \
    -Dfrida-core:frida_version="$FRIDA_VERSION" -Dfrida-gum:frida_version="$FRIDA_VERSION"
fi
# Compatibility builds cache their own version options independently.
for compat_build in "$repo"/build/subprojects/frida-core/compat/arch-support.bundle.p/*; do
  if [ -f "$compat_build/build.ninja" ]; then
    python3 releng/meson/meson.py configure "$compat_build" \
      -Dfrida_version="$FRIDA_VERSION" -Dfrida-gum:frida_version="$FRIDA_VERSION"
    # The top-level Ninja graph does not track the nested Meson option cache.
    rm -f "$repo/build/subprojects/frida-core/compat/arch-support.bundle"
  fi
done
make

python3 - <<'PY'
from pathlib import Path
import re
import os

headers = list(Path('build/subprojects/frida-core').rglob('frida-base.h'))
if not headers:
    raise SystemExit('Missing generated port definitions')
for header in headers:
    if not re.search(r'#define FRIDA_DEFAULT_CONTROL_PORT \(\(guint16\) 2909\)', header.read_text()):
        raise SystemExit(f'Unexpected compiled control port in {header}')
for header in Path('build/subprojects/frida-core').rglob('config.h'):
    source = header.read_text()
    if '#define FRIDA_VERSION ' in source:
        if f'#define FRIDA_VERSION "{os.environ["FRIDA_VERSION"]}"' not in source:
            raise SystemExit(f'Unexpected compiled version in {header}')
PY

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

# Verify the actual package, including the launchd path and packaged signatures.
unpacked="$stage/package-check"
dpkg-deb --raw-extract "$output" "$unpacked"
python3 - "$unpacked" <<'PY'
from pathlib import Path
import os
import plistlib
import sys

root = Path(sys.argv[1])
with (root / 'Library/LaunchDaemons/re.frida.server.plist').open('rb') as f:
    config = plistlib.load(f)
assert config['Program'] == '/usr/sbin/frida-server', config
assert config['ProgramArguments'] == ['/usr/sbin/frida-server'], config
assert 'Architecture: iphoneos-arm64e' in (root / 'DEBIAN/control').read_text()
assert f'Version: {os.environ["FRIDA_VERSION"]}\n' in (root / 'DEBIAN/control').read_text()
assert not (root / 'var/jb').exists(), 'Unexpected rootless prefix'
PY
for binary in "$unpacked/usr/sbin/frida-server" "$unpacked/usr/lib/frida-1.0/frida-agent.dylib"; do
  lipo "$binary" -verify_arch arm64 arm64e
  codesign --verify --strict --all-architectures "$binary"
done
shasum -a 256 "$output" | tee "$output.sha256"
echo "RootHide package ready (default listen address 127.0.0.1:2909): $output"
