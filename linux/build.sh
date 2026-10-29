#!/usr/bin/env bash
# Builds the Brick Linux image (kernel + embedded initramfs) for the Roblox emulator.
#
#   linux/build.sh [workdir]
#
# Needs a normal Linux host with buildroot's prerequisites (gcc, g++, make, git,
# rsync, bc, cpio, unzip, file, wget, python3). The first build compiles a RISC-V
# toolchain and takes 30-90 minutes; ccache and the download cache make later
# builds much faster. The result is written to linux/out/Image.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${1:-$HERE/../build/buildroot}"
OUT="$HERE/out"

# cnlohr's buildroot fork: adds the RV32 nommu FLAT toolchain fixes mini-rv32ima uses.
BUILDROOT_REPO="https://github.com/cnlohr/buildroot"
BUILDROOT_REV="851edd247f5e2e8e10f943c52218bc54c657688f"

if [ ! -d "$WORK/.git" ]; then
	mkdir -p "$WORK"
	git -C "$WORK" init -q
	git -C "$WORK" remote add origin "$BUILDROOT_REPO"
fi
if [ "$(git -C "$WORK" rev-parse HEAD 2>/dev/null || true)" != "$BUILDROOT_REV" ]; then
	git -C "$WORK" fetch -q --depth 1 origin "$BUILDROOT_REV"
	git -C "$WORK" checkout -q FETCH_HEAD
fi

# Our configs, overlay and helper sources live at <buildroot>/brick.
rm -rf "$WORK/brick"
mkdir -p "$WORK/brick"
cp -a "$HERE/configs" "$HERE/overlay" "$HERE/src" "$HERE/patches" "$HERE/post-build.sh" "$WORK/brick/"

cat "$HERE/configs/base/buildroot.config" "$HERE/configs/buildroot.fragment" > "$WORK/.config"
make -C "$WORK" olddefconfig >/dev/null

make -C "$WORK"

mkdir -p "$OUT"
cp "$WORK/output/images/Image" "$OUT/Image"

# Record what was actually enabled (Kconfig silently drops options with unmet deps).
{
	echo "# kernel"
	grep -E "^CONFIG_(BLOCK|VIRTIO_BLK|VIRTIO_NET|VIRTIO_MMIO|EXT2_FS|NET|INET|SIFIVE_PLIC|SERIAL_8250_NR_UARTS|TMPFS|LOCALVERSION)=" "$WORK"/output/build/linux-*/.config || true
	echo "# busybox"
	grep -cE "^CONFIG_[A-Z0-9_]+=y" "$WORK"/output/build/busybox-*/.config || true
	ls -la "$OUT/Image"
} | tee "$OUT/build-info.txt"
