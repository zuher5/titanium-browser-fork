#!/bin/bash
set -euo pipefail

# Ensure key artifacts directory is always cleaned up on exit
cleanup() {
  rm -rf "${SCRIPT_DIR:-.}/keys"
}
trap cleanup EXIT

source common.sh
set_keys

export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' "$SCRIPT_DIR/vanadium/args.gn")
if [[ -z "$VERSION" ]]; then
  echo "Error: Failed to determine VERSION from vanadium/args.gn" >&2
  exit 1
fi

# Use the GitHub mirror: googlesource throttles GitHub-hosted runners below
# the point where a ~2.5 GB depth-1 pack fetch can complete.
export CHROMIUM_SOURCE=https://github.com/chromium/chromium.git
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow imagemagick librsvg2-bin
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y libgcc-s1:i386

# Setup depot_tools (reuse if already present)
if [[ ! -d "depot_tools" ]]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$PWD/depot_tools:$PATH"

# Setup Chromium source directory (reuse checkout if compatible)
mkdir -p chromium/src/out/Default
cd chromium/src

if [[ ! -d ".git" ]]; then
  git init
  git remote add origin "$CHROMIUM_SOURCE"
else
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "$CHROMIUM_SOURCE"
  else
    git remote set-url origin "$CHROMIUM_SOURCE"
  fi
fi

# Configure git for large fetch operations. Keep the low-speed abort generous
# enough to not kill a slow-but-progressing transfer, only a truly stalled one.
git config --global http.postBuffer 524288000
git config --global http.lowSpeedLimit 50
git config --global http.lowSpeedTime 600

fetched=0
for attempt in {1..5}; do
  if git fetch --depth 1 origin "+refs/tags/$VERSION:chromium_$VERSION"; then
    fetched=1
    break
  fi
  echo "git fetch failed on attempt $attempt, retrying in 10s..." >&2
  sleep 10
done

if [[ $fetched -ne 1 ]]; then
  echo "Error: Failed to fetch Chromium source tag $VERSION after 5 attempts." >&2
  exit 1
fi
git checkout -f "$VERSION"
git clean -ffd
cp "$SCRIPT_DIR/.gclient" ../.gclient

# Reset and prepare Vanadium submodule patches cleanly
if [[ -d "$SCRIPT_DIR/vanadium/.git" || -f "$SCRIPT_DIR/vanadium/.git" ]]; then
  git -C "$SCRIPT_DIR/vanadium" checkout -f
  git -C "$SCRIPT_DIR/vanadium" clean -fd
fi

# https://grapheneos.org/build#browser-and-webview
rm -rf "$SCRIPT_DIR/vanadium/patches"/*trichrome-{apk-build-targets,browser-apk-targets}.patch
rm -rf "$SCRIPT_DIR/vanadium/patches"/*{detailed,supported}-language*.patch
rm -rf "$SCRIPT_DIR/vanadium/patches"/*javascript-optimizer-{site-setting,settings-UI}.patch
rm -rf "$SCRIPT_DIR/vanadium/patches"/*component-updates.patch
rm -rf "$SCRIPT_DIR/vanadium/patches"/*{pdf,PDF,for-content-public,toolbar-button,configs-from-config-app,config-app-parsing,new-tab-card,predictive-back}*.patch

replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "TITANIUM"
replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Titanium"
replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "titanium"

git am --whitespace=nowarn --keep-non-patch "$SCRIPT_DIR/vanadium/patches"/*.patch
git am --whitespace=nowarn --keep-non-patch "$SCRIPT_DIR/patches"/*.patch

gclient sync -D --no-history --nohooks
gclient runhooks
./build/install-build-deps.sh --no-prompt

source "$SCRIPT_DIR/patch.sh"
cp "$SCRIPT_DIR/args.gn" out/Default/args.gn
gn gen out/Default

# Build only the Android ARM64 APK. args.gn specifies target_cpu = "arm64".
autoninja -C out/Default chrome_public_apk

# Discover the built APK, ensuring exactly one non-empty APK is generated
mapfile -t APK_FILES < <(find out/Default/apks -maxdepth 1 -type f -name '*.apk' -print)
if [[ ${#APK_FILES[@]} -ne 1 || ! -s "${APK_FILES[0]}" ]]; then
  echo "Expected exactly one non-empty APK in out/Default/apks; found ${#APK_FILES[@]}." >&2
  printf '%s\n' "${APK_FILES[@]}" >&2
  exit 1
fi

FINAL_APK_NAME="Titanium-$VERSION-arm64-v8a.apk"
mkdir -p out/tmp out/release
mv "${APK_FILES[0]}" "out/tmp/$FINAL_APK_NAME"

export PATH="$PWD/third_party/jdk/current/bin/:$PATH"
export ANDROID_HOME="$PWD/third_party/android_sdk/public"

sign_apk "out/tmp/$FINAL_APK_NAME" "out/release/$FINAL_APK_NAME"

if [[ ! -s "out/release/$FINAL_APK_NAME" ]]; then
  echo "Error: Signed APK was not produced at out/release/$FINAL_APK_NAME" >&2
  exit 1
fi

echo "Successfully built and signed $FINAL_APK_NAME"
