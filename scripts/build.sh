#!/usr/bin/env bash
# Builds the SD card image (README.md), in two stages:
#   rootfs  NVIDIA's minimal Ubuntu 24.04 root filesystem plus files/extra-packages (cloud-init).
#           Runs natively on arm64 behind a one-line shim for NVIDIA's x86 check, or on x86-64
#           under qemu, which is much slower.
#   image   NVIDIA's L4T packages, the cloud-init drop-in, the wait for NTP, NVIDIA's SD card
#           layout and the CIDATA seed volume, compressed. x86-64 only: NVIDIA's flashing tools
#           are x86 binaries.
# Both run as root on Ubuntu 24.04. The GitHub workflow (.github/workflows/build.yml) runs rootfs
# on ubuntu-24.04-arm and image on ubuntu-24.04.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export DEBIAN_FRONTEND=noninteractive

usage() {
    cat >&2 <<EOF
Usage: sudo $(basename "$0") rootfs --work-dir DIR --out DIR
       sudo $(basename "$0") image --rootfs-tar FILE --work-dir DIR --out DIR

rootfs  Writes <flavor>-<codename>-R<L4T_VERSION>-rootfs.tbz2 and its .sha256 into --out.
        Runs on arm64 or x86-64.
image   Takes that tarball, which must have its .sha256 beside it. Writes
        <BOARD_CONFIG>-R<L4T_VERSION>.img.xz, its .sha256 and NVIDIA's license text into --out.
        Runs on x86-64 only.

--work-dir DIR  An existing directory with enough space free: 10 GiB for rootfs, 30 GiB for image.
                The BSP download is kept in DIR. Each stage builds in DIR/R<L4T_VERSION>-<stage>/,
                which must not exist yet. Nothing outside that new directory is removed.
--out DIR       Created if it's missing.
EOF
    exit 2
}

die() {
    echo "build.sh: $*" >&2
    exit 1
}

# Each step is stamped with the time, so a CI log shows how long each one took.
step() {
    echo
    echo "==> $(date -u '+%H:%M:%S UTC') $*"
}

[[ $# -ge 1 ]] || usage
STAGE="$1"
shift
[[ "$STAGE" == rootfs || "$STAGE" == image ]] || usage
WORK=""
OUT=""
ROOTFS_TAR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir)
            [[ $# -ge 2 ]] || usage
            WORK="$2"
            shift 2
            ;;
        --out)
            [[ $# -ge 2 ]] || usage
            OUT="$2"
            shift 2
            ;;
        --rootfs-tar)
            [[ $# -ge 2 && "$STAGE" == image ]] || usage
            ROOTFS_TAR="$2"
            shift 2
            ;;
        -h | --help)
            usage
            ;;
        *)
            echo "build.sh: unknown argument: $1" >&2
            usage
            ;;
    esac
done
[[ -n "$WORK" && -n "$OUT" ]] || usage
[[ "$STAGE" == rootfs || -n "$ROOTFS_TAR" ]] || usage

[[ "$(id -u)" -eq 0 ]] || die "run it as root (sudo)"
HOST_ARCH="$(uname -m)"
case "$STAGE:$HOST_ARCH" in
    rootfs:x86_64 | rootfs:aarch64 | image:x86_64) ;;
    *) die "the $STAGE stage doesn't run on $HOST_ARCH (rootfs: aarch64 or x86_64; image: x86_64)" ;;
esac
# Read in a subshell: Ubuntu's os-release sets UBUNTU_CODENAME and NAME, which must not leak in
# beside versions.env's.
# shellcheck source=/dev/null
os="$(. /etc/os-release && echo "${ID:-} ${VERSION_ID:-}")"
# NVIDIA's nv_build_samplefs.sh builds noble only on Ubuntu 24.04, and the image stage is run there
# too, as in CI.
[[ "$os" == "ubuntu 24.04" ]] || die "this build runs on Ubuntu 24.04 only; this is $os"

# shellcheck source=../versions.env
. "$REPO/versions.env"
for v in L4T_VERSION BSP_URL BSP_SHA256 BOARD_CONFIG ROOTFS_FLAVOR UBUNTU_CODENAME; do
    [[ -n "${!v:-}" ]] || die "$v is not set in versions.env"
done
[[ "$BSP_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "BSP_SHA256 in versions.env is not a SHA-256"

if [[ "$STAGE" == image ]]; then
    [[ -f "$ROOTFS_TAR" && -f "$ROOTFS_TAR.sha256" ]] ||
        die "--rootfs-tar $ROOTFS_TAR and its .sha256 must both exist"
    ROOTFS_TAR="$(cd "$(dirname "$ROOTFS_TAR")" && pwd -P)/$(basename "$ROOTFS_TAR")"
    (cd "$(dirname "$ROOTFS_TAR")" && sha256sum -c --quiet "$(basename "$ROOTFS_TAR").sha256") ||
        die "$ROOTFS_TAR does not match its .sha256"
fi

[[ -d "$WORK" ]] || die "--work-dir $WORK does not exist"
WORK="$(cd "$WORK" && pwd -P)"
TREE="$WORK/R$L4T_VERSION-$STAGE"
if [[ -e "$TREE" ]]; then
    die "$TREE already exists. Check that nothing is mounted under it (findmnt -R $TREE) or attached" \
        "to an image in it (losetup -a), remove it, and run again"
fi
need_gib=10
[[ "$STAGE" == rootfs ]] || need_gib=30
avail="$(df --output=avail -B1 "$WORK" | tail -n 1 | tr -d ' ')"
((avail >= need_gib * 1024 ** 3)) ||
    die "$((avail / 1024 ** 3)) GiB free in $WORK; the $STAGE stage needs $need_gib"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

L4T="$TREE/Linux_for_Tegra"

step "Host packages"
# curl and bzip2 fetch and unpack the BSP, and xz-utils compresses the image. qemu-user-static,
# wget, sudo and bzip2 are NVIDIA's documented host packages for nv_build_samplefs.sh, which its
# prerequisites script doesn't cover.
apt-get update
apt-get install -y curl bzip2 xz-utils qemu-user-static wget sudo

step "BSP: Jetson Linux R$L4T_VERSION"
# Only a download that matches the pin takes the final name, so an interrupted one is fetched again.
BSP="$WORK/${BSP_URL##*/}"
if [[ ! -f "$BSP" ]]; then
    curl -fL --retry 3 -o "$BSP.partial" "$BSP_URL"
    echo "$BSP_SHA256  $BSP.partial" | sha256sum -c --quiet - || die "$BSP_URL does not match BSP_SHA256"
    mv "$BSP.partial" "$BSP"
fi
echo "$BSP_SHA256  $BSP" | sha256sum -c --quiet - || die "$BSP does not match BSP_SHA256; remove it to download it again"
mkdir "$TREE"
tar -xpf "$BSP" -C "$TREE"

if [[ "$STAGE" == rootfs ]]; then
    step "Root filesystem: NVIDIA's $ROOTFS_FLAVOR $UBUNTU_CODENAME, plus files/extra-packages"
    SAMPLEFS="$L4T/tools/samplefs"
    LIST="nvubuntu-$UBUNTU_CODENAME-$ROOTFS_FLAVOR-aarch64-packages"
    [[ -f "$SAMPLEFS/$LIST" ]] || die "NVIDIA's package list $SAMPLEFS/$LIST is missing"
    # nvubuntu_samplefs.sh reads ubuntu/<version>/<list> before its own flat list, so NVIDIA's file
    # stays as shipped.
    mkdir -p "$SAMPLEFS/ubuntu/$UBUNTU_CODENAME"
    {
        cat "$SAMPLEFS/$LIST"
        grep -v -E '^[[:space:]]*(#|$)' "$REPO/files/extra-packages"
    } >"$SAMPLEFS/ubuntu/$UBUNTU_CODENAME/$LIST"
    # nv_build_samplefs.sh refuses any host that isn't x86-64 (line 106: arch | grep x86_64), its
    # only use of the host's architecture. Everything else downloads Ubuntu's arm64 base, chroots
    # into it and installs the package list, which an arm64 host runs natively instead of under
    # qemu. On arm64 the shim answers that one check. It is first on PATH for NVIDIA's script only;
    # the script's own sudo calls reset PATH, and the chroot can't see it.
    path="$PATH"
    if [[ "$HOST_ARCH" == aarch64 ]]; then
        mkdir "$TREE/arch-shim"
        printf '#!/bin/sh\necho x86_64\n' >"$TREE/arch-shim/arch"
        chmod 0755 "$TREE/arch-shim/arch"
        path="$TREE/arch-shim:$PATH"
    fi
    (cd "$SAMPLEFS" && env PATH="$path" ./nv_build_samplefs.sh --abi aarch64 --distro ubuntu \
        --flavor "$ROOTFS_FLAVOR" --version "$UBUNTU_CODENAME")
    [[ -f "$SAMPLEFS/sample_fs.tbz2" ]] || die "nv_build_samplefs.sh wrote no sample_fs.tbz2"

    step "Output"
    NAME="$ROOTFS_FLAVOR-$UBUNTU_CODENAME-R$L4T_VERSION-rootfs.tbz2"
    install -m 0644 "$SAMPLEFS/sample_fs.tbz2" "$OUT/$NAME"
    (cd "$OUT" && sha256sum "$NAME" >"$NAME.sha256")
    ls -l "$OUT"
    exit 0
fi

step "NVIDIA's host prerequisites"
"$L4T/tools/l4t_flash_prerequisites.sh"

step "NVIDIA's L4T packages, into the root filesystem from the rootfs stage"
"$L4T/apply_binaries.sh" --rootfs-tar "$ROOTFS_TAR"

step "Image edits"
ROOTFS="$L4T/rootfs"
[[ -x "$ROOTFS/usr/bin/cloud-init" ]] || die "cloud-init is not in the root filesystem"
install -m 0644 "$REPO/files/99-nocloud-seed.cfg" "$ROOTFS/etc/cloud/cloud.cfg.d/99-nocloud-seed.cfg"
echo "cloud-init $(dpkg-query --admindir="$ROOTFS/var/lib/dpkg" -W -f '${Version}' cloud-init)"
# cloud-init reads cloud.cfg.d in sorted order, and the last file to set a key wins. NVIDIA's
# 99-disable-cloud-init.cfg sets datasource_list: [None], so this image's file must come after
# every file that sets it, or cloud-init ignores CIDATA and the card has no user.
last_ds="$(cd "$ROOTFS/etc/cloud/cloud.cfg.d" && grep -l '^datasource_list[[:space:]]*:' -- *.cfg | LC_ALL=C sort | tail -n 1)"
[[ "$last_ds" == 99-nocloud-seed.cfg ]] ||
    die "$last_ds sets datasource_list after 99-nocloud-seed.cfg, so cloud-init would ignore CIDATA"
echo "datasource_list: 99-nocloud-seed.cfg is the last file to set it"
# The root filesystem build generated SSH host keys, and a public image must not carry them.
# cloud-init generates each card's own on its first boot.
rm -f "$ROOTFS"/etc/ssh/ssh_host_*
if compgen -G "$ROOTFS/etc/ssh/ssh_host_*" >/dev/null; then
    die "SSH host keys remain in the root filesystem"
fi
# cloud-init's final stage (packages, runcmd) is ordered after time-sync.target, which waits for
# NTP only if systemd-time-wait-sync is enabled, and systemd ships it disabled. A new card boots
# with its clock at 1970, so without the wait apt rejects Ubuntu's indexes as not yet valid.
wait_sync=usr/lib/systemd/system/systemd-time-wait-sync.service
grep -qx 'WantedBy=sysinit.target' "$ROOTFS/$wait_sync" ||
    die "$wait_sync is missing from the root filesystem, or is no longer WantedBy=sysinit.target"
ln -sv "/$wait_sync" "$ROOTFS/etc/systemd/system/sysinit.target.wants/"

step "SD card image"
NAME="$BOARD_CONFIG-R$L4T_VERSION.img"
# -d is required: the script rejects NVIDIA's documented line without it. The revision stays at
# the script's default, 300 for SKU 0005.
"$L4T/tools/jetson-disk-image-creator.sh" -o "$TREE/$NAME" -b "$BOARD_CONFIG" -d SD
"$REPO/scripts/make-cidata.sh" "$TREE/$NAME"

step "Compress"
xz -T0 "$TREE/$NAME"
# Hashed from the image's own directory, so the .sha256 holds the bare file name and
# "sha256sum -c" / "shasum -a 256 -c" work wherever the two files are downloaded together.
(cd "$TREE" && sha256sum "$NAME.xz" >"$NAME.xz.sha256")
install -m 0644 "$TREE/$NAME.xz" "$TREE/$NAME.xz.sha256" \
    "$L4T/Tegra_Software_License_Agreement-Tegra-Linux.txt" "$OUT/"
ls -l "$OUT"
