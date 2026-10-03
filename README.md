# Jetson Orin Nano L4T minimal SD card image

A headless NVIDIA Jetson Linux (L4T) image for the **Jetson Orin Nano Developer Kit's module
(P3767-0005)**, written to its microSD card. Like Raspberry Pi OS, it's configured on first boot
from text files you copy onto the card: cloud-init reads `user-data` and `meta-data` from the
card's FAT volume `CIDATA`. One image serves every card. A new L4T release is a new image, built
by GitHub Actions.

## Status

WIP. The first build hasn't run yet, and no card from this image has booted.

## What you need

- **The module:** the Orin Nano Developer Kit's module, P3767-0005. It's the only Orin Nano/NX
  module with a microSD slot. Production Orin Nano (P3767-0003/0004) and Orin NX modules have no
  slot, and NVIDIA's tools allow SD layouts only for SKU 0005 (`flash.sh`, `check_device_mismatch`).
  Any carrier works.
- **Its QSPI firmware:** the same L4T release and board config as the image. Both are in
  [versions.env](versions.env): R39.2.1, `jetson-orin-nano-devkit-super`.
  - QSPI is flashed separately, from an x86-64 Linux host, with NVIDIA's tools. This repo doesn't
    do it.
  - NVIDIA staff: "the QSPI version must match the JetPack version flashed onto the SD card".
- **A microSD card** bigger than the image. The root partition grows to fill it on first boot.
  NVIDIA's Quick Start asks for 64 GB or more, because its own flash layouts reserve a 57 GiB root.
  This image sizes the root to its contents.

## Making a card

1. Download the `.img.xz` and its `.sha256` from a
   [release](https://github.com/andyattebery/jetson-orin-nano-l4t-minimal/releases).
2. Check the download: `sha256sum -c <name>.img.xz.sha256` (on macOS, `shasum -a 256 -c`).
3. Write it to the card with balenaEtcher, NVIDIA's recommended tool, or with
   `xz -dc <name>.img.xz | sudo dd of=<card> bs=4M`. In Raspberry Pi Imager, pick no OS
   customisation.
4. Re-insert the card. The `CIDATA` volume mounts.
5. Copy your `user-data` and `meta-data` onto it. Start from [examples/](examples/); cloud-init
   needs both files. Use a plain-text editor, and name the files with no extension.
6. Eject the card, put it in the module, and power on.

## First boot

**With a seed:** cloud-init's NoCloud datasource finds `CIDATA` and applies `user-data`. That
means users and keys, plus anything else `user-data` sets. The hostname comes from `meta-data`'s
`local-hostname`. cloud-init also:
- grows the root partition, `APP`, which is physically last on the card, and its filesystem to the
  end of the card (growpart, resizefs);
- generates the card's SSH host keys. The image carries none.

**Networking:** NetworkManager runs DHCP on Ethernet. NVIDIA turns off cloud-init's network
configuration, so a `network-config` file on `CIDATA` is ignored.

**cloud-init stays enabled** unless `user-data` turns it off. While enabled, it reads `CIDATA` on
every boot:
- edits there apply only with a new `instance-id`;
- deleting the files makes cloud-init treat the card as a new instance, which regenerates its SSH
  host keys.

To make it run once, add this entry to `user-data`'s `write_files` list (create the list if
there's none):
```yaml
write_files:
  - path: /etc/cloud/cloud-init.disabled
    defer: true
    content: ""
```

**With no seed:** NVIDIA's default applies. cloud-init runs with no data and disables itself.
There's no user and no way in, so rewrite the card.

## What's in the image

- **Root filesystem:** NVIDIA's `minimal` flavor from `nv_build_samplefs.sh` (Ubuntu 24.04, no
  desktop, no oem-config), plus `cloud-init` ([files/extra-packages](files/extra-packages)).
  `cloud-guest-utils`, for growpart, comes in as a dependency.
- **NVIDIA's packages**, installed by `apply_binaries.sh` and left unchanged.
- **[files/99-nocloud-seed.cfg](files/99-nocloud-seed.cfg)**, which turns cloud-init back on for
  `CIDATA` (Traps).
- **No SSH host keys.**
- **The card layout** from NVIDIA's `jetson-disk-image-creator.sh` (`flash_t234_qspi_sd.xml`), with
  its `UDA` partition made into `CIDATA` by [scripts/make-cidata.sh](scripts/make-cidata.sh).

Everything else is NVIDIA's default, including its first-boot 2 GB `/swapfile` and its automatic
QSPI updates (Traps).

## Building

[scripts/build.sh](scripts/build.sh) runs in two stages, as root, on Ubuntu 24.04. Each step is
stamped with the time in the log.

1. **`rootfs`, on arm64 or x86-64.** It makes NVIDIA's minimal root filesystem plus
   `files/extra-packages`, using NVIDIA's `nv_build_samplefs.sh`. The output is
   `<flavor>-<codename>-R<version>-rootfs.tbz2` with its `.sha256`.
   - **On arm64** the roughly 990 arm64 packages install natively, behind a one-line `arch` shim
     for NVIDIA's x86 check (Traps).
   - **On x86-64** they install under qemu. The first CI run spent over 38 minutes there.
2. **`image`, on x86-64 only**, because NVIDIA's flashing tools are x86 binaries. It takes that
   tarball and runs:
   - NVIDIA's host prerequisites;
   - `apply_binaries.sh`;
   - the cloud-init drop-in, and removal of the SSH host keys;
   - `jetson-disk-image-creator.sh ... -d SD`;
   - `make-cidata.sh`;
   - `xz` and sha256.

Each stage first installs the host packages it needs, then downloads the BSP and checks it against
`BSP_SHA256`.

**In CI.** [.github/workflows/build.yml](.github/workflows/build.yml) runs `rootfs` on GitHub's
`ubuntu-24.04-arm` runner and `image` on `ubuntu-24.04`.
- **The hand-off:** the tarball passes between the two jobs through the Actions cache, keyed by
  run. Artifacts would count against the account's storage quota.
- **When:** a push to `main` that changes `versions.env`, `scripts/`, `files/` or the workflow,
  or a manual run from the Actions tab.
- **What it publishes:** a release, `R<L4T_VERSION>-<run number>`, with three files:
  - the image;
  - its `.sha256`;
  - NVIDIA's license text.

**Locally**, from the repo root:
```
mkdir -p work
sudo scripts/build.sh rootfs --work-dir work --out out
sudo scripts/build.sh image --rootfs-tar out/minimal-noble-R39.2.1-rootfs.tbz2 --work-dir work --out out
```
- **Hosts:** run `rootfs` on an arm64 or x86-64 host and `image` on an x86-64 one. Copy the
  tarball and its `.sha256` between them.
- **Space:** `work` needs 10 GiB free for `rootfs` and 30 GiB for `image`.
- **Re-running:** neither stage reuses its existing `work/R<version>-<stage>/`. Remove it first,
  after checking that nothing is mounted under it or attached to it.

## A new L4T release

1. Update `L4T_VERSION`, `BSP_URL` and `BSP_SHA256` in `versions.env`. NVIDIA publishes no
   checksum, so compute it once: `curl -fL <url> | sha256sum`.
2. Re-check `UDA` (next section) in the new BSP. Unpack it (`tar -xf <bsp>.tbz2`), then, on a
   Debian or Ubuntu host:
   ```
   for d in $(find Linux_for_Tegra -name '*.deb'); do
     n=$(dpkg-deb --fsys-tarfile "$d" | tar -xO 2>/dev/null | grep -a -c -w UDA)
     [ "$n" != 0 ] && echo "$n $d"
   done
   ```
   R39.2.1's hits:
   - `nvidia-l4t-bootloader`, 26: the flash-server strings in its capsules;
   - `nvidia-igx-bootloader`, 1: its capsule, not inspected;
   - `nvidia-l4t-multimedia`, 1: inside a binary library, next to CUDA messages.

   A new hit is worth reading before building.
3. Push to `main`.
4. Flash every module's QSPI to the same release before it boots a new card.

## Why `UDA`

The seed has to sit on a FAT partition that a laptop mounts by itself. NVIDIA's SD layout already
has one free for it.
- **NVIDIA's description of `UDA`** (400 MiB): "**Required.** This partition may be mounted and
  used to store user data."
- **What touches it — only flashing:**
  - `flash.sh --uda-dir` builds an *encrypted* UDA for disk encryption.
  - NVIDIA's initrd flash skips UDA unless it's given such an image.
  - The bootloader's USB-recovery flash server lists it among special partition names.
- **At runtime: nothing.** In R39.2.1, none of NVIDIA's 77 packages, the initrd, or the OTA and
  backup tools reference it, apart from those flash-server strings.
- **What `make-cidata.sh` changes:** the partition's type, from Linux `8300` to Microsoft basic
  data `0700`, so macOS and Windows mount it. It also formats the partition FAT with the label
  `CIDATA`.
- **What stays the same:** its GPT name and its place. The NVIDIA tools read for this find
  partitions by GPT name: the layout XML, and `/dev/disk/by-partlabel`. The only partition type
  they check is the ESP's.
- **Why not the ESP:** it's FAT too, but L4TLauncher lives there, NVIDIA mounts it at `/boot/efi`,
  and laptops don't mount EFI partitions on their own.

## Traps

- **NVIDIA's docs contradict themselves on the SD image.**
  - "Flashing to an SD Card" says "Applies to: only the Jetson Orin Nano Developer Kit … with the
    p3767-0005 module".
  - Its subsection "Generating an Image to be Flashed to an SD Card" says "only the Jetson Orin NX
    series", while its example is `-b jetson-orin-nano-devkit -r 100`.
  - The code agrees with the section: `jetson-disk-image-creator.sh` hard-codes SKU 0005 for both
    Orin Nano configs. The documented line without `-d` fails ("Incorrect root filesystem device").
- **NVIDIA's rootfs builder only runs on x86-64, as shipped.** `nv_build_samplefs.sh` stops at
  `arch | grep x86_64` (line 106 in R39.2.1). That is its only use of the host's architecture: the
  rest downloads Ubuntu's arm64 base, chroots into it and installs packages, which an arm64 host
  does natively.
  - On arm64, `build.sh` puts a shim first on `PATH` for that script only, a two-line `arch` that
    prints `x86_64`.
  - NVIDIA doesn't support building on arm64. The shim built the same R39.2.1 rootfs on an arm64
    Mac in about 2.5 minutes (2026-10-02).
  - Re-check line 106 when bumping L4T.
- **R39.2's image never grows its root partition.** NVIDIA, 2026-09-02: "On R39.2 the image from
  jetson-disk-image-creator.sh never expands, so the root filesystem stays at its generated size
  with no free space. Up to R36.5 this expansion was done on first boot by nvresizefs, which R39.2
  no longer ships." Here cloud-init's growpart and resizefs do it.
- **NVIDIA ships cloud-init disabled.** `nvidia-l4t-configs` installs
  `/etc/cloud/cloud.cfg.d/99-disable-cloud-init.cfg`, with `datasource_list: [None]` plus user-data
  that turns off growpart and writes `/etc/cloud/cloud-init.disabled`. `99-nocloud-seed.cfg` sorts
  after it and puts NoCloud first.
- **QSPI and the card must be the same release.** Rebuild for a new release, and flash QSPI too.
- **Carriers without the developer kit's EEPROM**, such as the Turing Pi 2, need two things:
  - QSPI flashed with NVIDIA's EEPROM read turned off;
  - NVIDIA's packages must never update QSPI. Installing any `nvidia-l4t-bootloader` package
    stages NVIDIA's stock capsule, and `nv-l4t-bootloader-config.service` installs one at boot
    whenever the package is newer than QSPI.

  For such a carrier, `user-data` can turn the boot-time update off before that service runs
  (`bootcmd` runs before `sysinit.target`) and hold the packages:
  ```yaml
  bootcmd:
    - [sed, -i, 's/^ENABLE_AUTO_QSPI_UPDATE=.*/ENABLE_AUTO_QSPI_UPDATE="0"/', /opt/nvidia/l4t-bootloader-config/nv-l4t-bootloader-config.conf]
  runcmd:
    - |
      apt-mark hold $(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'nvidia-l4t-*' | awk '$1 == "ii" {print $2}')
  ```
  Nothing stops a later `apt install --reinstall nvidia-l4t-bootloader` or `dpkg-reconfigure`.
- **Not for NVIDIA's OTA updates.** NVIDIA: "The memory layout used by flash.sh differs from the
  layout used by initrd flashing. To ensure successful OTA updates, production systems must use
  initrd flashing." Upgrade by writing a new card and flashing QSPI.
- **License.** The image contains NVIDIA's software under the Tegra Software License Agreement,
  attached to every release. §1.1(d) permits distributing it "for use with operating system
  kernels distributed under the terms of an OSI-approved open source license", provided "(i) the
  binary files thereof are not modified in any way… and (ii) this Agreement is provided to each
  SOFTWARE recipient". The packages are installed unmodified.

## Sources

- **NVIDIA Jetson Linux R39.2.1 Developer Guide**, Flashing Support (Flashing to an SD Card;
  Resizing the Root Partition) and Root File System:
  https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/
- **The R39.2.1 BSP**, `Jetson_Linux_R39.2.1_aarch64.tbz2`:
  - `tools/jetson-disk-image-creator.sh`, `tools/nvptparser.py`, `flash.sh`, `apply_binaries.sh`;
  - `nv_tools/scripts/nv_customize_rootfs.sh`, `tools/samplefs/`;
  - `bootloader/generic/cfg/flash_t234_qspi_sd.xml`;
  - the `nvidia-l4t-configs`, `-firstboot`, `-bootloader` and `-bootloader-utils` packages.
- **NVIDIA developer forum** thread 380597, "Issue on external sdcard image generate by
  jetson-disk-image-creator.sh for jetson orin nano board" (2026-08/09):
  https://forums.developer.nvidia.com/t/issue-on-external-sdcard-image-generate-by-jetson-disk-image-creator-sh-for-jetson-orin-nano-board/380597
- **cloud-init 26.1:** https://docs.cloud-init.io/en/26.1/ (NoCloud, base configuration, modules),
  and the source at tag `26.1`.
- **Raspberry Pi OS's move to cloud-init:**
  https://www.raspberrypi.com/news/cloud-init-on-raspberry-pi-os/ (2025-11-27).
