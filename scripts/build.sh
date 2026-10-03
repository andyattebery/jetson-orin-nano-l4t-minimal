#!/usr/bin/env bash
# Builds the SD card image (README.md). It contains:
#   - NVIDIA's minimal Ubuntu 24.04 root filesystem plus cloud-init;
#   - NVIDIA's L4T packages;
#   - a FAT volume labelled CIDATA, which cloud-init's NoCloud datasource reads on first boot.
# Runs as root on x86-64 Ubuntu 24.04, the host NVIDIA's tools need. The GitHub workflow
# (.github/workflows/build.yml) runs it on ubuntu-24.04.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export DEBIAN_FRONTEND=noninteractive

usage() {
    cat >&2 <<EOF
Usage: sudo $(basename "$0") --work-dir DIR --out DIR

Builds <BOARD_CONFIG>-R<L4T_VERSION>.img.xz from versions.env. It writes the image, its .sha256
and NVIDIA's license text into --out, creating it if it's missing.

--work-dir DIR  An existing directory with at least 30 GiB free. The BSP download is kept in DIR.
                The build tree is DIR/R<L4T_VERSION>/, which must not exist yet. Nothing outside
                that new tree is removed.
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

WORK=""
OUT=""
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

[[ "$(id -u)" -eq 0 ]] || die "run it as root (sudo)"
[[ "$(uname -m)" == x86_64 ]] || die "NVIDIA's flashing tools are x86-64 Linux only; this is $(uname -m)"
# Read in a subshell: Ubuntu's os-release sets UBUNTU_CODENAME and NAME, which must not leak in
# beside versions.env's.
# shellcheck source=/dev/null
os="$(. /etc/os-release && echo "${ID:-} ${VERSION_ID:-}")"
[[ "$os" == "ubuntu 24.04" ]] || die "NVIDIA's nv_build_samplefs.sh builds noble only on Ubuntu 24.04; this is $os"

# shellcheck source=../versions.env
. "$REPO/versions.env"
for v in L4T_VERSION BSP_URL BSP_SHA256 BOARD_CONFIG ROOTFS_FLAVOR UBUNTU_CODENAME; do
    [[ -n "${!v:-}" ]] || die "$v is not set in versions.env"
done
[[ "$BSP_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "BSP_SHA256 in versions.env is not a SHA-256"

[[ -d "$WORK" ]] || die "--work-dir $WORK does not exist"
WORK="$(cd "$WORK" && pwd -P)"
TREE="$WORK/R$L4T_VERSION"
if [[ -e "$TREE" ]]; then
    die "$TREE already exists. Check that nothing is mounted under it (findmnt -R $TREE) or attached" \
        "to an image in it (losetup -a), remove it, and run again"
fi
avail="$(df --output=avail -B1 "$WORK" | tail -n 1 | tr -d ' ')"
((avail >= 30 * 1024 ** 3)) || die "$((avail / 1024 ** 3)) GiB free in $WORK; the build needs 30"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

L4T="$TREE/Linux_for_Tegra"
NAME="$BOARD_CONFIG-R$L4T_VERSION.img"

step "Host packages for the download and the root filesystem build"
# curl and bzip2 fetch and unpack the BSP, and xz-utils compresses the image. qemu-user-static,
# wget, sudo and bzip2 are NVIDIA's documented host packages for nv_build_samplefs.sh, which its
# prerequisites script (run once the BSP is unpacked) doesn't cover.
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

step "NVIDIA's host prerequisites"
"$L4T/tools/l4t_flash_prerequisites.sh"

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
(cd "$SAMPLEFS" && ./nv_build_samplefs.sh --abi aarch64 --distro ubuntu --flavor "$ROOTFS_FLAVOR" \
    --version "$UBUNTU_CODENAME")
[[ -f "$SAMPLEFS/sample_fs.tbz2" ]] || die "nv_build_samplefs.sh wrote no sample_fs.tbz2"

step "NVIDIA's L4T packages"
"$L4T/apply_binaries.sh" --rootfs-tar "$SAMPLEFS/sample_fs.tbz2"

step "Image edits"
ROOTFS="$L4T/rootfs"
[[ -x "$ROOTFS/usr/bin/cloud-init" ]] || die "cloud-init is not in the root filesystem"
install -m 0644 "$REPO/files/99-nocloud-seed.cfg" "$ROOTFS/etc/cloud/cloud.cfg.d/99-nocloud-seed.cfg"
echo "cloud-init $(dpkg-query --admindir="$ROOTFS/var/lib/dpkg" -W -f '${Version}' cloud-init)"
# The root filesystem build generated SSH host keys, and a public image must not carry them.
# cloud-init generates each card's own on its first boot.
rm -f "$ROOTFS"/etc/ssh/ssh_host_*
if compgen -G "$ROOTFS/etc/ssh/ssh_host_*" >/dev/null; then
    die "SSH host keys remain in the root filesystem"
fi

step "SD card image"
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
