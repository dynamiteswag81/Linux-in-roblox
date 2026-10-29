# Brick Linux (the guest OS)

This directory builds the Linux system that runs inside the in-game computers:
a RISC-V **rv32ima, no-MMU** Linux 6.8 kernel with an embedded initramfs
(busybox userland + Brick Linux's scripts). The emulator in
`src/shared/Emulator` boots the resulting `Image` directly.

| Path | What it is |
| --- | --- |
| `configs/base/` | Known-good configs from [cnlohr/mini-rv32ima](https://github.com/cnlohr/mini-rv32ima) (MIT) |
| `configs/*.fragment` | Our additions: disk (virtio-blk + ext2), networking (virtio-net + IPv4), a much fuller busybox |
| `overlay/` | Files copied into the root filesystem: `/init`, rc scripts, `brick`, `brickstrap`, the install guide |
| `src/hostlink.c` | The guest side of the host link (package manager / workshop channel) |
| `patches/` | Source patches buildroot applies on top of cnlohr's (a uClibc riscv32 syscall fix) |
| `build.sh` | Builds everything with buildroot into `linux/out/Image` |

## Building

CI does this automatically (`.github/workflows/build-linux.yml`) whenever
anything under `linux/` changes, then commits the result to
`src/images/BrickLinux` as Luau modules.

To build by hand on a Linux machine with buildroot's prerequisites:

```sh
linux/build.sh                                   # -> linux/out/Image (first build ~1h)
python3 tools/image2luau.py linux/out/Image src/images/BrickLinux --name "Brick Linux"
```

## Boot flow

1. The in-game firmware loads the kernel and passes settings on the kernel command
   line: `brick.hostname=`, `brick.ip=`, `brick.time=`, `brick.root=/dev/vda1`.
2. `/init` mounts `brick.root`. If it holds an installed system it `switch_root`s
   to it; otherwise the **live installer** starts (auto-login as root).
3. The player installs to disk Arch-style (`install-guide`). The only shortcut is
   the paid auto-install button in the game's GUI, which writes the system to the
   disk from the server.

## Host link

`hostlink` talks to an MMIO mailbox at `0x10001000`. Because the kernel has no
MMU, user programs can access the device and hand it pointers into their own
memory directly. No kernel driver is needed. See the comment at the top of
`src/hostlink.c` for the register layout. Commands are implemented on the Roblox
side in `src/server/Services/HostLinkCommands.luau`.

## Licenses

The kernel and busybox are GPL-2.0. Their sources are the upstream releases
named in the build configs; buildroot downloads them during the build.
