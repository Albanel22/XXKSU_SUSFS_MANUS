#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
LINEAGE_DIR="${ROOT_DIR}/lineage"
DEVICE="${DEVICE:-kiev}"
LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-23.2}"
KSU_REF="${KSU_REF:-v3.2.5}"
PATCH_DIR="${ROOT_DIR}/${SUSFS_PATCH_DIR:-patches/susfs-kiev}"
BUILD_ROM="${BUILD_ROM:-false}"

log() {
  printf '\n==== %s ====\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Commande absente : $1" >&2
    exit 1
  }
}

for command in git curl repo ccache; do
  require_command "$command"
done

mkdir -p "$LINEAGE_DIR"
cd "$LINEAGE_DIR"

log "Synchronisation LineageOS ${LINEAGE_BRANCH}"
if [[ ! -d .repo ]]; then
  repo init \
    -u https://github.com/LineageOS/android.git \
    -b "$LINEAGE_BRANCH" \
    --git-lfs \
    --no-clone-bundle
fi
repo sync -c \
  --no-clone-bundle \
  --no-tags \
  --optimized-fetch \
  --prune \
  -j"$(nproc)"

log "Préparation du produit ${DEVICE}"
source build/envsetup.sh
breakfast "$DEVICE"

KERNEL_DIR="$LINEAGE_DIR/kernel/motorola/sm8250"
cd "$KERNEL_DIR"

log "Intégration KernelSU ${KSU_REF}"
if [[ -e KernelSU || -L drivers/kernelsu ]]; then
  echo "KernelSU est déjà présent dans l'arbre du noyau." >&2
  echo "Supprimez lineage/KernelSU et drivers/kernelsu, ou utilisez un checkout propre." >&2
  exit 1
fi

git clone --branch "$KSU_REF" --depth 1 \
  https://github.com/backslashxx/KernelSU.git KernelSU

echo "KernelSU commit: $(git -C KernelSU rev-parse HEAD)"
ln -s KernelSU/kernel drivers/kernelsu

grep -qF 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile

grep -qF 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || \
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

git diff --check

log "Application des patchs SUSFS locaux"
if [[ ! -d "$PATCH_DIR" ]]; then
  echo "Répertoire de patchs absent : $PATCH_DIR" >&2
  echo "Ajoutez les patchs SUSFS portés dans patches/susfs-kiev/." >&2
  exit 1
fi

mapfile -t patches < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' | sort)
if [[ "${#patches[@]}" -eq 0 ]]; then
  echo "Aucun patch SUSFS trouvé dans $PATCH_DIR" >&2
  exit 1
fi

for patch in "${patches[@]}"; do
  echo "Contrôle : $patch"
  git apply --check --verbose "$patch"
done
for patch in "${patches[@]}"; do
  echo "Application : $patch"
  git apply --index "$patch"
done

git diff --check

log "Configuration KernelSU et SUSFS"
CONFIG="arch/arm64/configs/vendor/ext_config/kiev-default.config"
test -f "$CONFIG"

cat >> "$CONFIG" <<'EOF'

# KernelSU backslashxx : kiev non-GKI 4.19
CONFIG_KSU=y
# CONFIG_KSU_KPROBES_KSUD is not set
CONFIG_KSU_HACK_ARM64_BRANCH_LINK=y
CONFIG_KSU_LSM_SECURITY_HOOKS=y
# CONFIG_KSU_DEBUG is not set

# SUSFS 2.2 : symboles présents dans le port local validé
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

log "Compilation"
cd "$LINEAGE_DIR"
source build/envsetup.sh
lunch lineage_kiev-userdebug

export USE_CCACHE=1
export CCACHE_EXEC="$(command -v ccache)"
ccache -M "${CCACHE_SIZE:-50G}"

mka bootimage

KERNEL_OBJ="out/target/product/${DEVICE}/obj/KERNEL_OBJ"
test -f "out/target/product/${DEVICE}/boot.img"
test -f "$KERNEL_OBJ/.config"
grep -E '^(CONFIG_KSU|CONFIG_KSU_SUSFS)' "$KERNEL_OBJ/.config" \
  | tee "$ROOT_DIR/kiev-effective-config.txt"
cp "out/target/product/${DEVICE}/boot.img" \
  "$ROOT_DIR/boot-${DEVICE}-lineage23.2-ksu-susfs.img"

if [[ "$BUILD_ROM" == "true" ]]; then
  log "Compilation ROM complète"
  brunch "$DEVICE"
fi

ccache -s | tee "$ROOT_DIR/ccache-stats.txt"
log "Build terminé"
