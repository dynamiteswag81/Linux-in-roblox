#!/bin/sh
# buildroot post-build hook: compiles Brick Linux's helper programs into the target.
# $1 = target directory. HOST_DIR is exported by buildroot.
set -e
TARGET="$1"
SRC="$(dirname "$0")/src"
CC="$HOST_DIR/bin/riscv32-buildroot-linux-uclibc-gcc"

# Flags from mini-rv32ima's hello_linux: static PIE converted to a FLAT binary.
CFLAGS="-mabi=ilp32 -march=rv32ima -fPIE -pie -static -Os -s -ffunction-sections -fdata-sections -Wall"
LDFLAGS="-Wl,-elf2flt=-r -Wl,-gc-sections"

for prog in hostlink; do
	"$CC" $CFLAGS "$SRC/$prog.c" $LDFLAGS -o "$TARGET/usr/bin/$prog"
	rm -f "$TARGET/usr/bin/$prog.gdb"
done

chmod 0755 "$TARGET/init" "$TARGET"/usr/bin/* "$TARGET"/etc/init.d/* 2>/dev/null || true
mkdir -p "$TARGET/var/lib/brick/local" "$TARGET/mnt" "$TARGET/home" "$TARGET/root"
