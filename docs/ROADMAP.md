# Roadmap

Living document: what works, what's next. Each work session updates it.

## Design constraints from the owner

- **One player per server.** Each server runs exactly one person's computer.
  Consequences:
  - The in-game internet can't stay inside one server: other players' computers
    are on other servers. It needs a cross-server relay (MessagingService for
    frames/messages, MemoryStore for the directory of online computers and
    globally unique addresses). Budget: about 840 messages/min of up to 1 KB
    per one-player server, with up to about 1 s of latency. That's enough for
    ping, `msg`, `talk` and small web pages, not for bulk transfers.
  - Offline players' computers aren't running, so their websites are down while
    they're away (an optional "hosted pages" feature could serve a published
    copy).
  - `msg` must reach other servers (MessagingService), plus a DataStore inbox
    for players who are offline.
  - The whole server CPU belongs to one VM: raise the per-frame budget
    (`Config.FRAME_BUDGET` / `MAX_COMPUTER_BUDGET`) and consider running it in an
    Actor.
  - Showing your screen to other players (docs/MODERATION.md item 1) no longer
    applies.
  - The flash drive, desks and the Workshop are unaffected.

## Monetization ideas (from the owner, not started)

Possible paid features. Every one needs a game pass or developer product checked on
the server (`MarketplaceService:UserOwnsGamePassAsync`, re-checked after
`PromptGamePassPurchaseFinished`); the client never decides.

- **Auto install.** The manual Arch-style install stays free. The pass skips it
  with a button in an in-game GUI, outside the computer. Nothing is added to the
  computer's screen or firmware. The button asks the server, which checks the pass
  and writes a ready-made system straight to the player's disk (a server API such as
  `ComputerService.autoInstall(player)`). That's instant and needs no flash drive
  or typing. Open question: whether `brickinstall` in the live system stays free.
- **More disk space.** Free disks are `Config.DISK_MB` (32 MB). Cleanest as a
  second drive (`/dev/vdb`, "install a bigger hard drive") rather than growing
  `/dev/vda`, because a grown disk still needs its partition and ext2 resized
  inside Linux. Cost to watch: DataStore storage limits scale with the
  experience's lifetime players, and disks only store used blocks (LZ4), so
  paying players with full big disks are the main storage cost. Cap sizes, for
  example 128 MB and 512 MB.
- **Web hosting.** With one player per server, a website is down while its owner
  is offline. Hosting publishes a copy of `/www` (size-capped, text filtered like
  Workshop READMEs) that the network serves when the owner's computer isn't
  online. Could include a custom name (`coolsite` alongside `alice`).

Others that fit if wanted: a faster computer (more CPU budget or RAM), extra
Workshop publishing slots, cosmetic desks and monitors.

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
2. **Flash drive (server side).** The owner's game inserts the installer drive;
   we provide the hook: a `FlashDrive` attribute on the desk plus
   `ComputerService.insertFlashDrive(desk)` / `ejectFlashDrive(desk)`. Firmware boot
   order: the disk if it holds a system (MBR + ext2 on partition 1), else the flash
   drive (live installer, `brick.live=1`), else a "No bootable device, insert the
   installer flash drive" screen that retries when a drive goes in.
   `Config.REQUIRE_FLASH_DRIVE` (off for Studio testing without the mechanic).
   Document it in docs/SETUP.md. (Guest side is done: `/init` no longer falls
   back to the live system when booted from disk.)
3. **Cross-server internet** (see Design constraints): relay network frames and
   `msg` between servers, a directory of online computers (`net.who`, DNS), unique
   addresses, and a bigger CPU budget for the single VM.
4. **Built from scratch:** remove the copied prebuilt `src/images/MiniLinux` image
   and its fallback boot entry; README section on what is written for this
   project (emulator, devices, terminal, firmware, OS integration, packages) vs.
   upstream sources we compile (Linux, busybox, uClibc via buildroot).
5. **Monitor for desktop environments:** `simple-framebuffer` in guest RAM
   (kernel `CONFIG_FB_SIMPLE`), virtio-input for keyboard + mouse (`evdev`), a guest
   drawing tool so shell scripts can draw, server-side dirty-tile streaming, client
   rendering on the desk's monitor with EditableImage.
6. **Docs:** player guide (installing, packages, network), package authoring guide,
   flash-drive integration guide for the owner; confirm disk saving across visits
   (DiskStore, autosave, save on leave/shutdown) and document it.
7. **Studio smoke test** with the owner, and fixes from it.
8. **Speed / scale:** run VMs in Actors for multi-core servers; an instruction decode
   cache for 2x interpreted speed (for client-side VMs).
9. **Snapshots:** save a booted machine's RAM so power-on can resume instantly,
   and suspend computers whose owner hasn't touched them for a while.
10. **Installer polish:** password prompt on first boot of an installed system,
    `brickinstall` as a dialog, progress output in `brick`.
11. **Workshop:** likes/ratings, "my packages" view, unpublish from the GUI, package
    screenshots (text previews).
12. **More software:** an `edit` text editor that's friendlier than vi, games
    (2048, tetris), a `man`-style help system.

## Decisions waiting on the owner

- Which monetization ideas to build, and what stays free (see Monetization ideas).

- Moderation choices in `docs/MODERATION.md` (screen sharing, package contents, raw
  network traffic like `talk`/`webserver`).
- Game name / OS name (currently "Brick Linux", `Config.OS_NAME`).
- ~~Whether VMs should run on the server or on each player's client.~~ Settled by
  one-player servers: the VM stays on the server, which is dedicated to that player.
- Memory: 32 MB RAM per running computer (`Config.RAM_MB`).
