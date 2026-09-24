#!/bin/bash
# Rebuild the macOS universal runtime from pinned source revisions.
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 OUTPUT_DIRECTORY" >&2; exit 2; }
mkdir -p "$1"
output="$(cd "$1" && pwd)"
assets="$(cd "$(dirname "$0")" && pwd)"
revision=e75de9b6b9b688fd293aa22f7e27aa724ea286f8
source_dir="$output/source"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --no-checkout https://github.com/mudler/parakeet.cpp.git "$source_dir"
  git -C "$source_dir" checkout --detach "$revision"
  git -C "$source_dir" submodule update --init --recursive
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || exit 2
make_dir="$(mktemp -d /tmp/asr-build-tools.XXXXXX)"
trap 'rm -f "$make_dir/make"; rmdir "$make_dir"' EXIT
ln -s "$(xcrun --find make)" "$make_dir/make"
for arch in arm64 x86_64; do
  cmake -S "$source_dir" -B "$output/build-$arch" \
    -DCMAKE_MAKE_PROGRAM="$make_dir/make" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$arch" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DPARAKEET_SHARED=ON -DBUILD_SHARED_LIBS=OFF -DPARAKEET_BUILD_SERVER=OFF \
    -DPARAKEET_GGML_METAL=OFF -DGGML_NATIVE=OFF -DGGML_LLAMAFILE=OFF \
    -DGGML_BLAS=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF \
    '-DCMAKE_INSTALL_RPATH=@executable_path/../capi' -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  cmake --build "$output/build-$arch" -j 6
done
runtime="$output/SpeechRuntime"
mkdir -p "$runtime/bin" "$runtime/capi"
lipo -create "$output/build-arm64/examples/cli/parakeet-cli" "$output/build-x86_64/examples/cli/parakeet-cli" -output "$runtime/bin/parakeet-cli"
lipo -create "$output/build-arm64/libparakeet.dylib" "$output/build-x86_64/libparakeet.dylib" -output "$runtime/capi/libparakeet.dylib"
cp "$assets/models.json" "$assets/THIRD-PARTY-NOTICES.txt" "$runtime/"
ditto "$assets/licenses" "$runtime/licenses"
echo "Runtime: $runtime"
