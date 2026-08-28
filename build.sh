#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
WORK_DIR="$ROOT_DIR/work"
KERNEL_DIR="$WORK_DIR/android_kernel_motorola_sm8250"
OUT_DIR="$KERNEL_DIR/out"
BOOT_DIR="$WORK_DIR/boot"
BOOT_URL="${BOOT_URL:?BOOT_URL est obligatoire}"
KSU_REF="${KSU_REF:-v3.2.5}"

log() { printf '\n==== %s ====\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Commande absente: $1" >&2; exit 1; }; }

for c in curl git make clang ld.lld llvm-ar unzip zip; do need "$c"; done
mkdir -p "$WORK_DIR" "$BOOT_DIR"

log "Téléchargement du boot.img"
curl --fail --location --retry 3 --retry-all-errors \
  --output "$WORK_DIR/boot-stock.img" "$BOOT_URL"
test "$(stat -c '%s' "$WORK_DIR/boot-stock.img")" -eq 100663296

log "Récupération du noyau LineageOS 23.2"
if [[ ! -d "$KERNEL_DIR/.git" ]]; then
  git clone --depth 1 --branch lineage-23.2 \
    https://github.com/LineageOS/android_kernel_motorola_sm8250 "$KERNEL_DIR"
fi

cd "$KERNEL_DIR"
log "Intégration KernelSU ${KSU_REF}"
git clone --branch "$KSU_REF" --depth 1 \
  https://github.com/backslashxx/KernelSU KernelSU
ln -s ../KernelSU/kernel drivers/kernelsu
grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
grep -qF 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || \
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

log "Application des scripts SUSFS 2.2 du dépôt de référence"
SUSFS_BASE_URL="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches"
for script in susfs_inline_hook_patches.sh syscall_hook_patches.sh; do
  curl --fail --location --retry 3 --retry-all-errors \
    --output "$WORK_DIR/$script" "$SUSFS_BASE_URL/$script"
  chmod +x "$WORK_DIR/$script"
  # Le script de référence contient son propre git diff --check ; il peut
  # retourner 2 pour un simple espace avant tabulation dans seccomp.h.
  sed -i -E '/^[[:space:]]*git diff --check[[:space:]]*$/d' "$WORK_DIR/$script"
  set +e
  bash "$WORK_DIR/$script" 2>&1 | tee "$WORK_DIR/$script.log"
  script_status=${PIPESTATUS[0]}
  set -e

  if [ "$script_status" -ne 0 ]; then
    if grep -q 'include/linux/seccomp.h:.*space before tab' "$WORK_DIR/$script.log"; then
      echo "Correction de l’espace avant tabulation dans seccomp.h"
      sed -i -E 's/^[ ]+\t/\t/' include/linux/seccomp.h
    else
      echo "Le script SUSFS a échoué : $script" >&2
      exit "$script_status"
    fi
  fi
done

# Normaliser les espaces avant tabulation introduits par SUSFS.
sed -i -E 's/^[ ]+\t/\t/' include/linux/seccomp.h
git diff --check
defconfig="arch/arm64/configs/vendor/lito-perf_defconfig"
test -f "$defconfig"
cat >> "$defconfig" <<'EOF'

# KernelSU backslashxx / SUSFS 2.2
CONFIG_KSU=y
# CONFIG_KSU_KPROBES_KSUD is not set
CONFIG_KSU_HACK_ARM64_BRANCH_LINK=y
CONFIG_KSU_LSM_SECURITY_HOOKS=y
# CONFIG_KSU_DEBUG is not set
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
# CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT is not set
# CONFIG_KSU_SUSFS_SUS_OVERLAYFS is not set
# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set
# CONFIG_KSU_SUSFS_ENABLE_LOG is not set
EOF

git diff --check

log "Compilation standalone du noyau"
rm -rf "$OUT_DIR"
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- vendor/lito-perf_defconfig
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"
test -f "$OUT_DIR/arch/arm64/boot/Image"
grep -E '^(CONFIG_KSU|CONFIG_KSU_SUSFS)' "$OUT_DIR/.config" \
  | tee "$ROOT_DIR/kiev-effective-config.txt"
cp "$OUT_DIR/arch/arm64/boot/Image" "$ROOT_DIR/Image-kiev-ksu-susfs"

log "Téléchargement de magiskboot"
MAGISK_APK="$WORK_DIR/Magisk.apk"
curl --fail --location --retry 3 --retry-all-errors \
  --output "$MAGISK_APK" \
  https://github.com/topjohnwu/Magisk/releases/download/v28.1/Magisk-v28.1.apk
unzip -p "$MAGISK_APK" lib/x86_64/libmagiskboot.so > "$WORK_DIR/magiskboot"
chmod +x "$WORK_DIR/magiskboot"

log "Reconstruction du boot.img"
rm -rf "$BOOT_DIR"
mkdir -p "$BOOT_DIR"
cp "$WORK_DIR/boot-stock.img" "$BOOT_DIR/boot.img"
cd "$BOOT_DIR"
"$WORK_DIR/magiskboot" unpack boot.img

test -f kernel
cp "$OUT_DIR/arch/arm64/boot/Image" kernel
"$WORK_DIR/magiskboot" repack boot.img boot-kiev-ksu-susfs.img
test -s boot-kiev-ksu-susfs.img
cp boot-kiev-ksu-susfs.img "$ROOT_DIR/boot-kiev-ksu-susfs.img"
sha256sum "$ROOT_DIR/boot-kiev-ksu-susfs.img" | tee "$ROOT_DIR/boot-kiev-ksu-susfs.sha256"
log "Build kernel-only terminé"
