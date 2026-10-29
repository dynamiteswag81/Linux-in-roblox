# Roadmap

Living document: what works, what's next. Each work session updates it.

## Status

### Done and tested headless (Lune)

- **RISC-V VM in Luau** boots real Linux 6.8 in ~72M instructions (~3 s of CPU
  with native codegen at ~30 MIPS; ~4 MIPS interpreted). The CPU is checked against
  a Python reference: 25k+ ALU cases plus loads, stores, branches and atomics
  (`tools/gen_cpu_tests.py`).
- **Devices:** console UART (interrupt-driven), PLIC, virtio disk (`/dev/vda`, ext2),
  virtio network (`eth0`), host link mailbox, syscon power off/reboot, runtime
  device tree.
- **Brick Linux** (built by CI from `linux/`): live installer with busybox (vi, less,
  awk, tar, fdisk, mkfs.ext2, wget, nc, httpd...), `brick` package manager,
  `brickstrap`/`brick-chroot`/`genfstab`/`brickinstall`, `install-guide`, `msg`.
  Guest bugs found and fixed: uClibc riscv32 64-bit syscall arguments (vi saved
  empty files), busybox's 4 KB stack (any `$(a | b)` crashed the shell), `/init`
  PATH, brickstrap ordering.
- **Terminal emulator** (VT100/xterm subset) with exact snapshots for late joiners and
  flood protection.
- **Firmware** (BrickBIOS) with POST screen and boot menu.
- **Server:** per-player computers, desks, CPU budgeting, streaming, disk saving
  (DataStore, two-slot), Community Workshop (publish/search/install, filtering,
  ownership, quotas), 12 official starter packages (incl. `snake`, `cowsay`,
  `webserver`, `browse`), in-game network (switch + gateway with ARP/ping/DNS),
  the **Workshop website** at `http://workshop/` (TCP + HTTP in Luau), filtered
  player messaging (`msg`).
- **Client:** desk screens, focus mode with keyboard capture, on-screen keyboard
  (Esc, F-keys...), physical `Key_*` parts, zoom view, Workshop browser.
- **Roblox simulation** (`tools/lune/sim.luau`): the real server and client scripts
  run against reflection-validated instances: prompt → boot → typing → workshop →
  leave, no errors.
- End-to-end scenarios (`tests/scenarios`): packages, two computers pinging and
  fetching web pages from each other by name, vi editing, fdisk/mkfs/brickstrap
  install and booting the installed system, the workshop website.

### Not yet verified in Roblox Studio

Nobody has pressed Play in Studio yet. The simulation catches API misuse, but expect
small fixes on first run (see the checklist in docs/SETUP.md).

## Next up (in order)

1. **Verify CI image #5**: busybox patches for the hush `$(...)` crash (re-executed
   subshells became login shells and freed `-F` function names) and httpd 404 on
   `/` (CGI without basic auth); `/init` no longer falls back to the live system
   when booted from disk (the installer needs the flash drive). Rerun all
   `tests/scenarios/*.txt` and measure idle cost with `lune run tools/lune/idle.luau`.
2. **Studio smoke test** with the owner, and fixes from it.
3. **Speed / scale:** run VMs in Actors for multi-core servers; an instruction decode
   cache for 2× interpreted speed (for client-side VMs).
4. **Snapshots:** save a booted machine's RAM so power-on can resume instantly,
   and suspend computers whose owner hasn't touched them for a while.
5. **Installer polish:** password prompt on first boot of an installed system,
   `brickinstall` as a dialog, progress output in `brick`.
6. **Workshop:** likes/ratings, "my packages" view, unpublish from the GUI, package
   screenshots (text previews).
7. **More software:** an `edit` text editor that's friendlier than vi, games
   (2048, tetris), a `man`-style help system.

## Decisions waiting on the owner

- Moderation choices in `docs/MODERATION.md` (screen sharing, package contents, raw
  network traffic like `talk`/`webserver`).
- Game name / OS name (currently "Brick Linux", `Config.OS_NAME`).
- Whether VMs should run on the server (current) or on each player's client.
- Memory: 32 MB RAM per running computer (`Config.RAM_MB`).
