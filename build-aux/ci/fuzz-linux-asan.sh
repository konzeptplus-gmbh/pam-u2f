#!/usr/bin/env sh
#
# Copyright (C) 2025 Yubico AB - See COPYING

set -eux

CORPUS_URL="https://storage.googleapis.com/yubico-pam-u2f/corpus.tgz"

WORKDIR="${WORKDIR:-$(pwd)}"

LIBCBOR_URL="https://github.com/pjk/libcbor"
LIBCBOR_TAG="v0.11.0"
LIBCBOR_CFLAGS="-fsanitize=address,alignment,bounds"
LIBFIDO2_URL="https://github.com/Yubico/libfido2"
LIBFIDO2_TAG="1.15.0"
LIBFIDO2_CFLAGS="-fsanitize=address,alignment,bounds"

COMMON_CFLAGS="-g2 -fno-omit-frame-pointer"
PAM_U2F_CFLAGS="-fsanitize=address,pointer-compare,pointer-subtract"
PAM_U2F_CFLAGS="${PAM_U2F_CFLAGS},undefined,bounds"
PAM_U2F_CFLAGS="${PAM_U2F_CFLAGS},leak"
PAM_U2F_CFLAGS="${PAM_U2F_CFLAGS} -fno-sanitize-recover=all"
PAM_U2F_CFLAGS="${PAM_U2F_CFLAGS} -fprofile-instr-generate -fcoverage-mapping"
PAM_U2F_CFLAGS="${PAM_U2F_CFLAGS} -fcoverage-compilation-dir=$WORKDIR"

NPROC="$(nproc)"

${CC} --version

if [ -n "${FAKEROOT:-}" ]; then
	mkdir -p "${FAKEROOT}"
	FAKEROOT="$(cd "$FAKEROOT" && pwd)" # Must be absolute
else
	FAKEROOT="$(mktemp -d)"
	trap 'rm -rf "$FAKEROOT"' 0
fi

export LD_LIBRARY_PATH="${FAKEROOT}/lib"
export PKG_CONFIG_PATH="${FAKEROOT}/lib/pkgconfig"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"
export ASAN_OPTIONS="detect_leaks=1:detect_invalid_pointer_pairs=2"

cd "${FAKEROOT}"

[ -e libcbor ]  || git clone --depth 1 "${LIBCBOR_URL}" -b "${LIBCBOR_TAG}"
[ -e libfido2 ] || {
	git clone --depth 1 "${LIBFIDO2_URL}" -b "${LIBFIDO2_TAG}"

	# libcbor (with libfido2 patch)
	patch -d libcbor -p0 -s <libfido2/fuzz/README
}

cmake -B libcbor.build -S libcbor \
	-DBUILD_SHARED_LIBS=ON \
	-DCMAKE_BUILD_TYPE=Debug \
	-DCMAKE_C_FLAGS_DEBUG="${LIBCBOR_CFLAGS} ${COMMON_CFLAGS}" \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DCMAKE_INSTALL_PREFIX="${FAKEROOT}" \
	-DSANITIZE=OFF \
	-DWITH_EXAMPLES=OFF \
	-GNinja
cmake --build libcbor.build -j "$NPROC"
cmake --install libcbor.build

cmake -B build.libfido2 -S libfido2 \
	-DBUILD_EXAMPLES=OFF \
	-DBUILD_MANPAGES=OFF \
	-DBUILD_TOOLS=OFF \
	-DCMAKE_BUILD_TYPE=Debug \
	-DCMAKE_C_FLAGS_DEBUG="${LIBFIDO2_CFLAGS} ${COMMON_CFLAGS}" \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DCMAKE_INSTALL_PREFIX="${FAKEROOT}" \
	-DFUZZ=1 \
	-DFUZZ_LDFLAGS="-fsanitize=fuzzer" \
	-GNinja
cmake --build build.libfido2 -j "$NPROC"
cmake --install build.libfido2

# pam-u2f
cmake -B build.pam_u2f -S "$WORKDIR" \
	-DBUILD_FUZZER=ON \
	-DBUILD_MANPAGES=OFF \
	-DBUILD_MODULE=OFF \
	-DBUILD_PAMU2FCFG=OFF \
	-DBUILD_TESTING=OFF \
	-DCMAKE_BUILD_TYPE=Debug \
	-DCMAKE_C_FLAGS_DEBUG="${PAM_U2F_CFLAGS} ${COMMON_CFLAGS}" \
	-GNinja
cmake --build build.pam_u2f -j "$NPROC"

# fuzz
if ! [ -d corpus ]; then
	curl --retry 4 -s -o corpus.tgz "${CORPUS_URL}"
	tar xzf corpus.tgz
fi

run_fuzzer() (
	FUZZER_NAME="$1"

	export LLVM_PROFILE_FILE="$FAKEROOT/$FUZZER_NAME.profraw"

	FUZZER_BINARY="$FAKEROOT/build.pam_u2f/fuzz/fuzz_$FUZZER_NAME"
	CORPUS="$FAKEROOT/corpus/$FUZZER_NAME"
	PROFILE_MERGED="${LLVM_PROFILE_FILE%.*}.profdata"

	"$FUZZER_BINARY" "$CORPUS" \
		-reload=30 \
		-print_pcs=1 \
		-print_funcs=30 \
		-timeout=10 \
		-runs=1

	llvm-profdata merge \
		-sparse "$LLVM_PROFILE_FILE" \
		-o "$PROFILE_MERGED"

	llvm-cov report --show-branch-summary=false \
		"$FAKEROOT/build.pam_u2f/fuzz/libpam_u2f_fuzz.so" \
		-instr-profile "$PROFILE_MERGED" \
		-sources "$WORKDIR"
)

find "$FAKEROOT" \( -name '*.profraw' -or -name '*.profdata' \) -exec rm -v {} +

run_fuzzer format_parsers
run_fuzzer auth

if [ -n "${WITH_COVERAGE_REPORT:-}" ]; then
	find "$FAKEROOT" -name '*.profraw' -print0 |
		xargs -0tr llvm-profdata merge -sparse -o "$FAKEROOT/global.profdata"
	llvm-cov show \
		-o "$WORKDIR/cov-report" -format=html \
		"$FAKEROOT/build.pam_u2f/fuzz/libpam_u2f_fuzz.so" \
		-instr-profile "$FAKEROOT/global.profdata" \
		-sources "$WORKDIR"
fi
