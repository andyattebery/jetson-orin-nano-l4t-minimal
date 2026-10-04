# Jetson Orin Nano L4T minimal SD card image

A headless NVIDIA Jetson Linux (L4T) image for the **Jetson Orin Nano Developer Kit's module
(P3767-0005)**, written to its microSD card. Like Raspberry Pi OS, it's configured on first boot
from text files you copy onto the card: cloud-init reads `user-data` and `meta-data` from the
card's FAT volume `CIDATA`. One image serves every card. GitHub Actions builds a new image when
NVIDIA publishes a release.

## What you need

- **The module:** the Orin Nano Developer Kit's module, P3767-0005. It's the only Orin Nano/NX
  module with a microSD slot. Production Orin Nano (P3767-0003/0004) and Orin NX modules have no
  slot, and NVIDIA's tools allow SD layouts only for SKU 0005 (`flash.sh`, `check_device_mismatch`).
  Any carrier works.
- **Its QSPI firmware:** the same L4T release and board config as the image. Both are in the
  release's name and notes.
  - QSPI is flashed separately, from an x86-64 Linux host, with NVIDIA's tools. This repo doesn't
    do it.
  - NVIDIA staff: "the QSPI version must match the JetPack version flashed onto the SD card".
- **A microSD card** bigger than the image. The root partition grows to fill it on first boot.
  NVIDIA's Quick Start asks for 64 GB or more, because its own flash layouts reserve a 57 GiB root.
  This image sizes the root to its contents.

## Making a card

1. Download the `.img.xz` and its `.sha256` from the newest
   [release](https://github.com/andyattebery/jetson-orin-nano-l4t-minimal/releases) for your
   module's QSPI. Its tag starts with the same `R<version>`. The newest release overall can be a
   newer L4T.
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

**Packages and `runcmd` wait for NTP.** cloud-init's final stage starts only once
`systemd-timesyncd` has set the clock from NTP. That stage runs:
- `packages`;
- `runcmd`'s commands;
- deferred `write_files`.

The module boots with its clock at 1970, and apt can't work until it's right (Traps). Users, keys,
the hostname, `write_files` and the root growth all come before the wait, so you can log in while
it waits.
- **With no NTP server in reach**, the final stage waits, with no timeout, until one answers.
  `timedatectl` shows whether the clock is synchronized. NVIDIA sets timesyncd's fallback servers
  to `0.pool.ntp.org 1.pool.ntp.org 0.fr.pool.ntp.org`.
- **The config stage doesn't wait.** Its modules, such as `apt` sources and `snap`, can run with
  the clock still at 1970 and before DHCP has finished (Traps).

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
Once the marker exists, `cloud-init status` says `disabled`, and after a reboot it stops showing
the first boot's errors. The first boot's outcome stays in `/var/lib/cloud/data/result.json` and
`/var/log/cloud-init.log`.

**With no seed:** NVIDIA's default applies. cloud-init runs with no data and disables itself.
There's no user and no way in, so rewrite the card.

## What's in the image

- **Root filesystem:** NVIDIA's `minimal` flavor from `nv_build_samplefs.sh` (Ubuntu 24.04, no
  desktop, no oem-config), plus `cloud-init`, `fwupd` and `udisks2`
  ([files/extra-packages](files/extra-packages)). `cloud-guest-utils`, for growpart, comes in as a
  dependency.
- **NVIDIA's packages**, installed by `apply_binaries.sh` and left unchanged.
- **[files/99-nocloud-seed.cfg](files/99-nocloud-seed.cfg)**, which turns cloud-init back on for
  `CIDATA` (Traps).
- **`systemd-time-wait-sync` enabled.** systemd ships it disabled. With it, `time-sync.target`
  waits for NTP, and so does cloud-init's final stage (First boot).
  - The only other units that wait are the calendar timers, such as `apt-daily`.
  - Logins and `multi-user.target` don't wait for NTP. No NVIDIA unit in R39.2.1 is ordered after
    `time-sync.target`.
- **No SSH host keys.**
- **The card layout** from NVIDIA's `jetson-disk-image-creator.sh` (`flash_t234_qspi_sd.xml`), with
  its `UDA` partition made into `CIDATA` by [scripts/make-cidata.sh](scripts/make-cidata.sh).

Everything else is NVIDIA's default, including:
- its first-boot 2 GB `/swapfile`;
- its masked `NetworkManager-wait-online` (Traps);
- its automatic QSPI updates (Traps).

## Building

[scripts/build.sh](scripts/build.sh) runs in two stages, as root, on Ubuntu 24.04. Each step is
stamped with the time in the log.

1. **`rootfs`, on arm64 or x86-64.** It makes NVIDIA's minimal root filesystem plus
   `files/extra-packages`, using NVIDIA's `nv_build_samplefs.sh`. The output is
   `<flavor>-<codename>-R<version>-rootfs.tbz2` with its `.sha256`.
   - **On arm64** the roughly 990 arm64 packages install natively, behind a two-line `arch` shim
     for NVIDIA's x86 check (Traps).
   - **On x86-64** they install under qemu. In CI that takes NVIDIA's script over an hour,
     against about 4 minutes natively on arm64.
2. **`image`, on x86-64 only**, because NVIDIA's flashing tools are x86 binaries. It takes that
   tarball and runs:
   - NVIDIA's host prerequisites;
   - `apply_binaries.sh`;
   - the image edits:
     - the cloud-init drop-in, and a check that it sorts last;
     - removal of the SSH host keys;
     - `systemd-time-wait-sync` enabled;
   - `jetson-disk-image-creator.sh ... -d SD`;
   - `make-cidata.sh`;
   - `xz` and sha256.

Each stage first installs the host packages it needs, then downloads the BSP and checks it against
`BSP_SHA256`.

**In CI.** [.github/workflows/build.yml](.github/workflows/build.yml) runs `rootfs` on GitHub's
`ubuntu-24.04-arm` runner and `image` on `ubuntu-24.04`.
- **The hand-off:** the tarball passes between the two jobs through the Actions cache, keyed by
  run. Artifacts would count against the account's storage quota.
- **When:**
  - a push to `main` that changes `versions.env`, `scripts/`, `files/` or the workflow;
  - a manual run from the Actions tab;
  - daily, when it finds a newer NVIDIA release (A new L4T release).
- **What it publishes:** a release, `R<L4T_VERSION>-<n>`, where `n` counts the builds of that L4T
  version. Its notes name the QSPI release the card needs. It has three files:
  - the image;
  - its `.sha256`;
  - NVIDIA's license text.

**Locally**, from the repo root:
```
mkdir -p work
sudo scripts/build.sh rootfs --work-dir work --out out
. ./versions.env
sudo scripts/build.sh image --rootfs-tar "out/$ROOTFS_FLAVOR-$UBUNTU_CODENAME-R$L4T_VERSION-rootfs.tbz2" \
  --work-dir work --out out
```
- **Hosts:** run `rootfs` on an arm64 or x86-64 host and `image` on an x86-64 one. Copy the
  tarball and its `.sha256` between them.
- **Space:** `work` needs 10 GiB free for `rootfs` and 30 GiB for `image`.
- **Re-running:** neither stage reuses its existing `work/R<version>-<stage>/`. Remove it first,
  after checking that nothing is mounted under it or attached to it.

## A new L4T release

**Within the same major version, it's automatic.** Every day the workflow runs
[scripts/check-release.py](scripts/check-release.py).
1. **Finding releases:** it reads NVIDIA's
   [Jetson Linux archive](https://developer.nvidia.com/embedded/jetson-linux-archive), where each
   release is a link whose text is its version. It also reads the main Jetson Linux page, which
   links the current release's BSP.
2. **The bump:** for the newest release with `versions.env`'s major version:
   - it follows that release's page to its BSP link;
   - it downloads the BSP once for its SHA-256;
   - it rewrites `L4T_VERSION`, `BSP_URL` and `BSP_SHA256`.
3. **The build:** the workflow commits that to `main` as `github-actions[bot]` and builds it in the
   same run.

Why not something simpler:
- **Not NVIDIA's apt repository:** it carries updates that have no BSP.
- **Not a URL built from the version:** NVIDIA's paths differ between releases.

**The build stops, rather than publishes, when a release breaks an assumption:**
- **A `cloud.cfg.d` file sets `datasource_list` after `99-nocloud-seed.cfg`.**
- **`systemd-time-wait-sync` changes its `[Install]` section.**
- **NVIDIA's package list for the flavor and codename is missing.**
- **`nv_build_samplefs.sh` changes its host check** (Traps).

To run the check by hand: the Actions tab, "Build image", "Run workflow", with "Look for a newer
NVIDIA release first" ticked.

**A newer major version opens an issue instead,** once per major, titled "Jetson Linux R<major>
is out". A new major can move to another Ubuntu release or drop the Orin Nano: R38 was Thor-only.
Moving to it is by hand:
1. Check that the release supports the P3767-0005 and `BOARD_CONFIG`, and which Ubuntu release it
   uses.
2. Set `L4T_VERSION`, `BSP_URL` and `BSP_SHA256` in `versions.env`, and `UBUNTU_CODENAME` if it
   changed. NVIDIA publishes no checksum, so compute it once: `curl -fL <url> | sha256sum`.
3. Push to `main`.

**Either way, by hand:** flash every module's QSPI to the new release before it boots a card from
it.

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
- **New releases aren't re-checked.** NVIDIA reserves the partition for user data. A release whose
  software used it anyway would show at the first boot of its first card, and a new release's
  first card is always a deliberate step, after reflashing QSPI.
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
  - NVIDIA doesn't support building on arm64.
  - If NVIDIA changes that check, the arm64 build fails rather than builds something wrong. The
    script exits 1 (lines 106-110), and `build.sh` stops when no `sample_fs.tbz2` was written.
- **R39.2's image never grows its root partition.** NVIDIA, 2026-09-02: "On R39.2 the image from
  jetson-disk-image-creator.sh never expands, so the root filesystem stays at its generated size
  with no free space. Up to R36.5 this expansion was done on first boot by nvresizefs, which R39.2
  no longer ships." Here cloud-init's growpart and resizefs do it.
- **NVIDIA ships cloud-init disabled.** `nvidia-l4t-configs` installs
  `/etc/cloud/cloud.cfg.d/99-disable-cloud-init.cfg`, with `datasource_list: [None]` plus user-data
  that turns off growpart and writes `/etc/cloud/cloud-init.disabled`. `99-nocloud-seed.cfg` sorts
  after it and puts NoCloud first.
- **A new card's clock starts at 1970,** and nothing sets it before NTP. Until then apt rejects
  every Ubuntu index: "Release file … is not valid yet".
  - So the image makes cloud-init's final stage wait for NTP (First boot).
  - Anything that runs before the sync sees 1970, when TLS certificates aren't valid yet either.
- **`network-online.target` doesn't wait for the network.** NVIDIA masks
  `NetworkManager-wait-online.service` (`nv_customize_rootfs.sh` lines 80-85, "for Bug 200290321",
  which isn't public).
  - Units ordered after `network-online.target` can start before DHCP finishes, and that includes
    cloud-init's config stage.
  - The image keeps the mask. An NTP sync needs DNS and a route out, so the wait for NTP holds the
    final stage until the network works.
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
- **GitHub turns the daily check off after 60 days without activity.** GitHub's docs: "In a
  public repository, scheduled workflows are automatically disabled when no repository activity
  has occurred in 60 days."
  - NVIDIA's gap from R39.2.0 to R39.2.1 was 66 days.
  - Users report a warning email first ("… will be disabled soon").
  - Turn it back on with `gh workflow enable build.yml`, or from the Actions tab.
- **The workflow commits to `main`.** A release bump is a commit by `github-actions[bot]`, so pull
  before pushing.
- **A failed automatic build isn't retried.**
  - `versions.env` already names the new release, so the next day's check finds nothing newer.
  - GitHub emails the failure to "the user who last modified the cron syntax in the workflow
    file".
  - Fix the cause and push, and the push builds it.
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
  the source at tag `26.1`, and Ubuntu's `26.1-0ubuntu1~24.04.1` package: its systemd units,
  `cloud.cfg`, `cmd/main.py` and `cmd/status.py`.
- **systemd 255 on noble** (`255.4-1ubuntu8.17`): the man pages for
  `systemd-time-wait-sync.service`(8), `systemd.timer`(5) and `systemd.target`(5) at
  https://manpages.ubuntu.com/manpages/noble/, and the units in the root filesystem.
- **NVIDIA's release pages:** https://developer.nvidia.com/embedded/jetson-linux-archive,
  https://developer.nvidia.com/embedded/jetson-linux, and the release pages they link.
- **GitHub Actions docs:** "Events that trigger workflows" (`schedule`) and "Triggering a
  workflow" (`GITHUB_TOKEN`):
  https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/
- **Raspberry Pi OS's move to cloud-init:**
  https://www.raspberrypi.com/news/cloud-init-on-raspberry-pi-os/ (2025-11-27).
