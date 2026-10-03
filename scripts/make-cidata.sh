#!/usr/bin/env bash
# Turns the UDA partition of a Jetson SD card image (the output of NVIDIA's
# jetson-disk-image-creator.sh) into cloud-init's NoCloud seed volume (README.md, "Why UDA"):
#   - GPT type Microsoft basic data, so macOS, Windows and Linux desktops mount it;
#   - a FAT filesystem labelled CIDATA.
# The partition keeps its name and its place.
set -euo pipefail

die() {
    echo "make-cidata.sh: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: make-cidata.sh IMAGE"
img="$1"
# A regular file only, never a block device or a link to one, so this can't be aimed at a disk.
[[ -f "$img" && ! -L "$img" ]] || die "$img is not a regular file"

mapfile -t uda < <(partx --show -g -o NR,START,SECTORS,NAME "$img" | awk '$4 == "UDA" {print $1, $2, $3}')
[[ ${#uda[@]} -eq 1 ]] || die "expected exactly one partition named UDA in $img, found ${#uda[@]}"
read -r nr start sectors <<<"${uda[0]}"

sgdisk -t "$nr:0700" "$img" >/dev/null
# --offset writes the filesystem into the partition inside the image file, with no loop device.
# The block count is in KiB; the partition is counted in 512-byte sectors. mkfs.fat warns "block
# count mismatch ... assuming <count>" because the file runs on past the partition. It uses the
# count it was given, the partition's size.
mkfs.vfat -n CIDATA --offset "$start" -h "$start" "$img" $((sectors / 2)) >/dev/null
probe="$(blkid -p -O $((start * 512)) -o export "$img")"
if ! grep -qx 'TYPE=vfat' <<<"$probe" || ! grep -qx 'LABEL=CIDATA' <<<"$probe"; then
    die "no FAT filesystem labelled CIDATA at partition $nr after formatting"
fi
echo "make-cidata.sh: partition $nr (UDA, $sectors sectors at $start) is now FAT CIDATA, type Microsoft basic data"
