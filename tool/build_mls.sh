#!/usr/bin/env bash
# Builds the native MLS library (native/peak_mls, OpenMLS) for:
#   - Android: app/android/app/src/main/jniLibs/<abi>/libpeak_mls.so
#   - this machine: native/peak_mls/target/release/libpeak_mls.so (the Dart
#     FFI tests load it via PEAK_MLS_LIB)
# Outputs are build artifacts (gitignored). An APK built without them just
# reports E2EE as unavailable and messaging stays transport-only.
#
# Needs: rustup (targets aarch64-linux-android, armv7-linux-androideabi,
# x86_64-linux-android), cargo-ndk, and the Android NDK.
set -euo pipefail
cd "$(dirname "$0")/../native/peak_mls"
: "${ANDROID_NDK_HOME:=$(ls -d "$HOME"/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -1)}"
export ANDROID_NDK_HOME

cargo test --release
cargo build --release
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o ../../app/android/app/src/main/jniLibs build --release
ls -la ../../app/android/app/src/main/jniLibs/*/libpeak_mls.so target/release/libpeak_mls.so
