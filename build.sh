#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
WORK_DIR="$ROOT_DIR/work"
KERNEL_DIR="$WORK_DIR/android_kernel_motorola_sm8250"
KSU_DIR="$KERNEL_DIR/KernelSU"
OUT_DIR="$KERNEL_DIR/out"
BOOT_WORK="$WORK_DIR/boot"
OUTPUT_DIR="$ROOT_DIR/output"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_motorola_sm8250}"
KERNEL_REF="${KERNEL_REF:-lineage-23.2}"
KSU_REPO="${KSU_REPO:-https://github.com/backslashxx/KernelSU}"
KSU_REF="${KSU_REF:-0909ad8b04103581230800997d2bcbc6d30e223e}"
BOOT_URL="${BOOT_URL:-https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img}"
PATCH_DIR="${PATCH_DIR:-$ROOT_DIR/patches/susfs-kiev}"
DEFCONFIG="${DEFCONFIG:-vendor/lito-perf_defconfig}"

log() { printf '\n==== %s ====\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Commande absente: $1" >&2; exit 1; }; }

for c in curl git make clang ld.lld llvm-ar unzip sed grep awk sha256sum stat nproc; do need "$c"; done

mkdir -p "$WORK_DIR" "$BOOT_WORK" "$OUTPUT_DIR"
rm -rf "$KERNEL_DIR" "$BOOT_WORK"
mkdir -p "$BOOT_WORK"

log "Téléchargement du boot.img stock"
curl --fail --location --retry 3 --retry-all-errors --output "$WORK_DIR/boot-stock.img" "$BOOT_URL"
BOOT_SIZE="$(stat -c '%s' "$WORK_DIR/boot-stock.img")"
[ "$BOOT_SIZE" -ge 50000000 ] && [ "$BOOT_SIZE" -le 200000000 ] || {
  echo "Taille inattendue pour boot.img: $BOOT_SIZE octets" >&2; exit 1;
}

log "Clone du noyau"
git clone --depth=1 --branch "$KERNEL_REF" "$KERNEL_REPO" "$KERNEL_DIR"
cd "$KERNEL_DIR"

log "Intégration KernelSU depuis le SHA commun"
curl --fail --location --retry 3 --retry-all-errors \
  "https://raw.githubusercontent.com/backslashxx/KernelSU/$KSU_REF/kernel/setup.sh" \
  | bash -s "$KSU_REF"
test -d "$KSU_DIR/kernel"
ACTUAL_KSU_REF="$(git -C "$KSU_DIR" rev-parse HEAD)"
[ "$ACTUAL_KSU_REF" = "$KSU_REF" ] || {
  echo "KernelSU inattendu: $ACTUAL_KSU_REF, attendu: $KSU_REF" >&2; exit 1;
}

log "Vérification du port SUSFS"
[ -d "$PATCH_DIR" ] || { echo "Port SUSFS absent: $PATCH_DIR" >&2; exit 1; }
mapfile -t SUSFS_PATCHES < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print | sort)
[ "${#SUSFS_PATCHES[@]}" -gt 0 ] || { echo "Aucun patch SUSFS dans $PATCH_DIR" >&2; exit 1; }
for p in "${SUSFS_PATCHES[@]}"; do
  echo "Contrôle: $p"
  git apply --check --verbose "$p"
done
for p in "${SUSFS_PATCHES[@]}"; do
  echo "Application: $p"
  git apply --index "$p"
done

log "Contrôle des anciennes APIs"
if grep -RInE 'ksu_is_init_rc_hook_enabled|ksu_handle_sys_read([^_a-zA-Z]|$)|ksu_hide_setprocattr([^_a-zA-Z]|$)' \
    fs security include drivers --include='*.c' --include='*.h'; then
  echo "Anciennes APIs KernelSU détectées après application SUSFS." >&2
  exit 1
fi

log "Configuration du noyau"
CONFIG_FILE="arch/arm64/configs/$DEFCONFIG"
test -f "$CONFIG_FILE"
cat >> "$CONFIG_FILE" <<'EOF'

# KernelSU non-GKI / kiev
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KPROBES is not set
# CONFIG_HAVE_KPROBES is not set
# CONFIG_KPROBE_EVENTS is not set
CONFIG_KSU_LSM_SECURITY_HOOKS=y

# SUSFS: ces symboles doivent être fournis par le port local
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
EOF

git diff --check

log "Compilation du noyau"
rm -rf "$OUT_DIR"
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- "$DEFCONFIG"
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image
IMAGE="$OUT_DIR/arch/arm64/boot/Image"
test -s "$IMAGE"
cp "$IMAGE" "$OUTPUT_DIR/Image-kiev-ksu-susfs"
grep -E '^(CONFIG_KSU|CONFIG_KSU_SUSFS)' "$OUT_DIR/.config" \
  | tee "$OUTPUT_DIR/kiev-effective-config.txt"

log "Compilation de ksud depuis le même checkout"
KSUD_DIR="$KSU_DIR/userspace/ksud"
test -f "$KSUD_DIR/Cargo.toml"
NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"
[ -n "$NDK_ROOT" ] || { echo "ANDROID_NDK_ROOT/ANDROID_NDK_HOME absent" >&2; exit 1; }
CLANG_ANDROID="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
CLANGXX_ANDROID="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
LLVM_AR_ANDROID="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
SYSROOT="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
test -x "$CLANG_ANDROID"; test -x "$CLANGXX_ANDROID"; test -x "$LLVM_AR_ANDROID"
mkdir -p "$KSUD_DIR/.cargo"
cat > "$KSUD_DIR/.cargo/config.toml" <<EOF
[target.aarch64-linux-android]
linker = "$CLANG_ANDROID"

[env]
CC_aarch64_linux_android = "$CLANG_ANDROID"
CXX_aarch64_linux_android = "$CLANGXX_ANDROID"
AR_aarch64_linux_android = "$LLVM_AR_ANDROID"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "--sysroot=$SYSROOT -I$SYSROOT/usr/include/aarch64-linux-android"
EOF
rustup target add aarch64-linux-android
cargo build --manifest-path "$KSUD_DIR/Cargo.toml" --target aarch64-linux-android --release
KSUD_BIN="$KSU_DIR/target/aarch64-linux-android/release/ksud"
test -x "$KSUD_BIN"
cp "$KSUD_BIN" "$OUTPUT_DIR/ksud"
sha256sum "$OUTPUT_DIR/ksud" | tee "$OUTPUT_DIR/ksud.sha256"

log "Reconstruction du boot.img"
MAGISK_APK="$WORK_DIR/Magisk.apk"
curl --fail --location --retry 3 --retry-all-errors \
  --output "$MAGISK_APK" \
  https://github.com/topjohnwu/Magisk/releases/download/v28.1/Magisk-v28.1.apk
unzip -p "$MAGISK_APK" lib/x86_64/libmagiskboot.so > "$WORK_DIR/magiskboot"
chmod +x "$WORK_DIR/magiskboot"
cp "$WORK_DIR/boot-stock.img" "$BOOT_WORK/boot.img"
cd "$BOOT_WORK"
"$WORK_DIR/magiskboot" unpack boot.img
test -f kernel
cp "$IMAGE" kernel
"$WORK_DIR/magiskboot" repack boot.img "$OUTPUT_DIR/boot-kiev-ksu-susfs.img"
sha256sum "$OUTPUT_DIR/boot-kiev-ksu-susfs.img" | tee "$OUTPUT_DIR/boot-kiev-ksu-susfs.sha256"

printf '%s\n' "$KSU_REF" > "$OUTPUT_DIR/kernelsu-commit.txt"
printf '%s\n' "$ACTUAL_KSU_REF" > "$OUTPUT_DIR/kernelsu-commit-verified.txt"
printf '%s\n' "$KERNEL_REF" > "$OUTPUT_DIR/kernel-ref.txt"
git -C "$KERNEL_DIR" diff --stat | tee "$OUTPUT_DIR/kernel-diff-stat.txt"
log "Build terminé"
ls -lh "$OUTPUT_DIR"
