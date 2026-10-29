# Roadmap

Living document: what works, what's next. Each work session updates it.

## Status

### Done and tested headless (Lune)

- **RISC-V VM in Luau** boots real Linux 6.8: ~2 s of CPU to a shell with native
  codegen (~30 MIPS), ~4 MIPS interpreted.
- **Devices:** console UART, PLIC, virtio disk (`/dev/vda`, ext2), virtio network
  (`eth0`), host link mailbox, syscon power off/reboot, runtime device tree.
- **Brick Linux** (custom image, built by CI from `linux/`): live installer with
  busybox (vi, less, awk, tar, fdisk, mkfs.ext2, wget, nc, httpd, telnet...),
  `brick` package manager, `brickstrap`/`brick-chroot`/`genfstab`/`brickinstall`,
  `install-guide`.
- **Terminal emulator** (VT100/xterm subset) with exact snapshots for late joiners and
  flood protection.
- **Firmware** (BrickBIOS) with POST screen and boot menu.
- **Server:** per-player computers, desks, CPU budgeting, streaming, disk saving
  (DataStore, two-slot), Community Workshop (publish/search/install, filtering,
  ownership), official starter packages, in-game network (switch + DNS/ping gateway).
- **Client:** desk screens, focus mode with keyboard capture, on-screen keyboard
  (Esc, F-keys...), physical `Key_*` parts, zoom view, Workshop browser.
- End-to-end scenarios (`tests/scenarios`): package search/install, two computers
  pinging each other by name, fdisk/mkfs/mount, booting an installed disk.

### Not yet verified in Roblox Studio

All the Roblox-facing code (`src/client`, `ComputerService`) compiles but hasn't run in
Studio yet (no Studio access during development). Expect small fixes on first run.

## Next up (in order)

1. **Verify the second CI image** (uClibc riscv32 syscall fix, init PATH, brickstrap,
   brick plain-tar) with `tests/scenarios/*.txt`: vi saves files, full install →
   reboot → installed system → `brick install` works there.
2. **Studio smoke test checklist** for the user (docs/SETUP.md) and fixes from it.
3. **Speed:** an instruction/basic-block decode cache in `Cpu` (target 2× interpreted
   speed for clients), and/or run VMs in Actors for multi-core servers.
4. **Snapshots:** save a booted machine's RAM so "power on" can resume instantly
   (compressed RAM ~2–4 MB), and suspend computers when their owner leaves the desk
   for a long time.
5. **Installer polish:** `brickinstall` dialog, password prompt on first boot of an
   installed system, `brick` progress output.
6. **More official packages:** games (snake, 2048 in awk), `figlet`-style banners, a
   chat bridge (`talk` via the host, filtered), a `wiki`/manual package.
7. **Workshop GUI:** likes/ratings, "my packages" view, screenshots (text previews).
8. **Network:** a host-side HTTP server on 10.0.0.1 serving the workshop index
   (`wget http://workshop/`), and optional friends-only networking.

## Decisions waiting on the owner

- Moderation choices in `docs/MODERATION.md` (screen sharing, package contents, network).
- Game name / OS name (currently "Brick Linux", `Config.OS_NAME`).
- Whether VMs should run on the server (current) or on each player's client.
