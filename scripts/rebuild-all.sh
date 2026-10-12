#!/bin/bash
# Rebuild every ArtCraft Android port with the build machine's identity stripped from the
# shipped binaries, package each APK, publish it to dist/, then free that app's build trees
# before starting the next one.
#
# Why one-at-a-time with cleanup: a single app's Rust target is ~2 GB and its Gradle build
# ~0.5 GB, and this machine only has ~17 GB free. Four targets co-existing would exhaust it
# mid-build, which is a failure mode that wastes the whole run.
#
# Why the rebuild at all: Rust bakes absolute panic-location paths into object code, so the
# previously published APKs leaked /Users/<name>/.cargo/... to anyone running
# `strings libmain.so` (632-1221 occurrences each). scripts/build-app.sh now passes
# RUSTFLAGS=--remap-path-prefix, so every crate must be recompiled for the fix to apply.
set -uo pipefail

REPO="$HOME/artcraft-mobile"
cd "$REPO" || exit 2

export PATH="$HOME/.cargo/bin:$HOME/Library/Android/sdk/platform-tools:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/28.2.13676358"
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export PATH="$JAVA_HOME/bin:$PATH"

# app:version pairs
APPS="lightcraft:0.2.1 photocraft:0.3.0 effectcraft:0.4.0 printcraft:0.2.1 filmcraft:0.2.1"

ver_of() { case "$1" in
  filmcraft) echo 0.2.1;; lightcraft) echo 0.2.1;; photocraft) echo 0.3.0;;
  effectcraft) echo 0.4.0;; printcraft) echo 0.2.1;; esac; }
# dist/ filename prefix differs from the clone dir for filmcraft/printcraft
name_of() { case "$1" in
  filmcraft) echo FilmCraft;; lightcraft) echo LightCraft;; photocraft) echo PhotoCraft;;
  effectcraft) echo EffectCraft;; printcraft) echo PrintCraft;; esac; }

rc_all=0
for pair in $APPS; do
  app="${pair%%:*}"; ver="$(ver_of "$app")"; nm="$(name_of "$app")"
  echo "==================== $app ($nm $ver) ===================="

  # 1. Rust library (build-app.sh mirrors the patch, picks the profile, takes the lock)
  "$REPO/scripts/build-app.sh" "$app" || { echo "!! $app: rust build failed"; rc_all=1; continue; }

  SO="$app/apps/$app-android/jniLibs/arm64-v8a/libmain.so"
  if [ ! -f "$SO" ]; then echo "!! $app: no libmain.so"; rc_all=1; continue; fi
  leak=$(strings "$SO" 2>/dev/null | grep -c "/Users/")
  echo "-- leak check: $leak occurrences of /Users/ (must be 0)"
  [ "$leak" -ne 0 ] && { echo "!! $app: path remap did not take effect"; rc_all=1; }

  # 2. Gradle APK
  GRADLE_DIR="$app/apps/$app-android/android"
  if [ ! -d "$GRADLE_DIR" ]; then echo "!! $app: no Gradle shell"; rc_all=1; continue; fi
  ( cd "$GRADLE_DIR" && "$REPO/tools/gradle-9.3.1/bin/gradle" assembleRelease \
      --no-daemon -Dhttp.nonProxyHosts='*' > "/tmp/gradle-$app.log" 2>&1 )
  grc=$?
  APK="$GRADLE_DIR/app/build/outputs/apk/release/app-release.apk"
  if [ "$grc" -ne 0 ] || [ ! -f "$APK" ]; then
    echo "!! $app: gradle failed (rc=$grc)"; tail -12 "/tmp/gradle-$app.log"; rc_all=1; continue
  fi

  # 3. Publish
  cp -f "$APK" "$REPO/dist/$nm-$ver-android-arm64.apk"
  echo "-- published dist/$nm-$ver-android-arm64.apk ($(stat -f%z "$APK") B)"
  strings "$APK" 2>/dev/null | grep -c "/Users/" | sed 's/^/-- apk leak check (approx): /'

  # 4. Free this app's build trees before the next one starts
  rm -rf "$app/target" "$GRADLE_DIR/app/build"
  echo "-- cleaned; free: $(df -h /System/Volumes/Data | tail -1 | awk '{print $4}')"
  echo
done

echo "==================== done (rc=$rc_all) ===================="
ls -la "$REPO"/dist/*.apk | awk '{printf "  %10s  %s\n",$5,$9}'
exit $rc_all
