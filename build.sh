#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
WORK_DIR="$ROOT_DIR/work"
KERNEL_DIR="$WORK_DIR/android_kernel_motorola_sm8250"
OUT_DIR="$KERNEL_DIR/out"
BOOT_DIR="$WORK_DIR/boot"
BOOT_URL="${BOOT_URL:-https://mirrorbits.lineageos.org/full/kiev/20260809/boot.img}"
KSU_REF="${KSU_REF:-v3.2.5}"
SUSFS_PATCH_DIR="${SUSFS_PATCH_DIR:-$ROOT_DIR/patches/susfs-kiev}"

log() { printf '\n==== %s ====\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Commande absente: $1" >&2; exit 1; }; }

for c in curl git make clang ld.lld llvm-ar unzip zip sed grep awk sha256sum; do
  need "$c"
done

mkdir -p "$WORK_DIR" "$BOOT_DIR"

log "Téléchargement du boot.img stock"
curl --fail --location --retry 3 --retry-all-errors \
  --output "$WORK_DIR/boot-stock.img" "$BOOT_URL"
BOOT_SIZE="$(stat -c '%s' "$WORK_DIR/boot-stock.img")"
if [ "$BOOT_SIZE" -lt 50000000 ] || [ "$BOOT_SIZE" -gt 200000000 ]; then
  echo "Taille inattendue pour boot.img: $BOOT_SIZE octets" >&2
  exit 1
fi

log "Récupération du noyau LineageOS 23.2"
rm -rf "$KERNEL_DIR"
git clone --depth=1 --branch lineage-23.2 \
  https://github.com/LineageOS/android_kernel_motorola_sm8250 "$KERNEL_DIR"

cd "$KERNEL_DIR"

log "Intégration KernelSU $KSU_REF"
git clone --depth=1 --branch "$KSU_REF" \
  https://github.com/backslashxx/KernelSU KernelSU
ln -s ../KernelSU/kernel drivers/kernelsu
printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

# Le script SUSFS générique du dépôt NonGKI injecte des APIs absentes de
# KernelSU v3.2.5. On ne l’exécute pas. Le port SUSFS doit être fourni sous
# forme de patchs vérifiables pour cette base précise.
log "Vérification du port SUSFS kiev"
if [ ! -d "$SUSFS_PATCH_DIR" ]; then
  echo "Port SUSFS absent: $SUSFS_PATCH_DIR" >&2
  echo "Ajoutez des patchs SUSFS adaptés à KernelSU $KSU_REF et au noyau 4.19." >&2
  exit 1
fi
mapfile -t SUSFS_PATCHES < <(find "$SUSFS_PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print | sort)
if [ "${#SUSFS_PATCHES[@]}" -eq 0 ]; then
  echo "Aucun patch SUSFS dans $SUSFS_PATCH_DIR" >&2
  exit 1
fi
for patch in "${SUSFS_PATCHES[@]}"; do
  echo "Contrôle: $patch"
  git apply --check "$patch"
done
for patch in "${SUSFS_PATCHES[@]}"; do
  git apply "$patch"
done

# Refuser explicitement les anciennes APIs responsables des échecs précédents.
if grep -RInE \
  'ksu_is_init_rc_hook_enabled|ksu_handle_sys_read([^_a-zA-Z]|$)|ksu_hide_setprocattr([^_a-zA-Z]|$)' \
  fs security include drivers --include='*.c' --include='*.h'; then
  echo "APIs KernelSU obsolètes détectées après le port SUSFS." >&2
  exit 1
fi

log "Configuration du noyau"
DEFCONFIG="arch/arm64/configs/vendor/lito-perf_defconfig"
test -f "$DEFCONFIG"
if ! grep -q '^config KSU_SUSFS' drivers/kernelsu/Kconfig; then
  echo "Le port SUSFS n’ajoute pas les symboles KSU_SUSFS dans Kconfig." >&2
  exit 1
fi
cat >> "$DEFCONFIG" <<'EOF'

CONFIG_KSU=y
# CONFIG_KSU_KPROBES_KSUD is not set
CONFIG_KSU_LSM_SECURITY_HOOKS=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
EOF

git diff --check

log "Compilation de l’image noyau uniquement"
rm -rf "$OUT_DIR"
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- vendor/lito-perf_defconfig
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
test -s "$IMAGE"
grep -E '^(CONFIG_KSU|CONFIG_KSU_SUSFS)' "$OUT_DIR/.config" \
  | tee "$ROOT_DIR/kiev-effective-config.txt"
cp "$IMAGE" "$ROOT_DIR/Image-kiev-ksu-susfs"

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
cp "$IMAGE" kernel
"$WORK_DIR/magiskboot" repack boot.img boot-kiev-ksu-susfs.img
test -s boot-kiev-ksu-susfs.img
cp boot-kiev-ksu-susfs.img "$ROOT_DIR/boot-kiev-ksu-susfs.img"
sha256sum "$ROOT_DIR/boot-kiev-ksu-susfs.img" \
  | tee "$ROOT_DIR/boot-kiev-ksu-susfs.sha256"

log "Build terminé"
