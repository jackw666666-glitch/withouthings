#!/bin/bash
# macOS only: build the Rust core for iPhone and generate the Swift bindings.
set -euxo pipefail
cd "$(dirname "$0")/.."
rustup target add aarch64-apple-ios
export IPHONEOS_DEPLOYMENT_TARGET=17.0
cargo build --release --target aarch64-apple-ios -p wpp-ffi
cargo build --release -p wpp-ffi           # host build, only to read the interface for bindgen
mkdir -p ios/lib ios/Generated
cp target/aarch64-apple-ios/release/libwpp_ffi.a ios/lib/
cargo run --release -p uniffi-bindgen -- generate --library target/release/libwpp_ffi.dylib --language swift --out-dir ios/Generated
