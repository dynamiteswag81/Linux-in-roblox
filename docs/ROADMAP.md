# Roadmap

Living document: what works, what's next. Each work session updates it.

## Design constraints from the owner

- **One player per server.** Each server runs exactly one person's computer.
  Consequences:
  - The in-game internet can't stay inside one server: other players' computers
    are on other servers. Done: a cross-server relay (MessagingService for packets
    and messages, MemoryStore for the directory; each server gives other servers'
    computers local 10.1.x.y addresses, so no global address allocation). Budget:
    about 840 messages/min of up to 1 KB per one-player server, with up to about
    1 s of latency. That's enough for ping, `msg`, `talk` and small web pages, not
    for bulk transfers.
  - Offline players' computers aren't running, so their websites are down while
    they're away (the "web hosting" idea below could serve a published copy).
  - `msg` reaches other servers (done); a DataStore inbox for players who are
    offline is still to do.
  - The whole server CPU belongs to one VM: `MAX_COMPUTER_BUDGET` is now 10 ms per
    frame. Running it in an Actor is still an option.
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
  or typing. This is the only shortcut: the free `brickinstall` script was removed.
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
- **Brick Linux** (built by CI from `linux/`, the only image; the copied prebuilt
  MiniLinux is gone): live installer with busybox (vi, less, awk, tar, fdisk,
  mkfs.ext2, wget, nc, httpd...), `brick` package manager,
  `brickstrap`/`brick-chroot`/`genfstab`, `install-guide`, `msg`. Guest bugs found
  and fixed (patches in `linux/patches`): uClibc riscv32 64-bit syscall arguments
  (vi saved empty files), busybox's 4 KB stack, hush `$(...)` crashing in every
  login shell, httpd 404 on `/`, Ctrl-C and job control not working (login on
  `/dev/console`), installed root locked by buildroot.
- **Installer flash drive:** desk attribute `FlashDrive` /
  `ComputerService.insertFlashDrive`. The firmware boots the disk if it has a
  system, else the flash drive, else shows "No bootable device".
- **Terminal emulator** (VT100/xterm subset) with exact snapshots for late joiners and
  flood protection.
- **Firmware** (BrickBIOS) with POST screen and boot menu.
- **Server:** per-player computers, desks, CPU budgeting, streaming, disk saving
  (DataStore, two-slot), Community Workshop (publish/search/install/unpublish,
  filtering, ownership, quotas), 13 official starter packages, the **Workshop
  website** at `http://workshop/` (TCP + HTTP in Luau), filtered player messaging
  (`msg`).
- **Cross-server internet:** other servers' computers appear at 10.1.x.y; packets
  are batched into MessagingService messages with NAT and MSS clamping; a
  MemoryStore directory backs DNS and `net.who`; `msg` crosses servers.
- **Client:** desk screens, focus mode with keyboard capture, on-screen keyboard
  (Esc, F-keys...), physical `Key_*` parts, zoom view, Workshop browser.
- **Roblox simulation** (`tools/lune/sim.luau`): the real server and client scripts
  run against reflection-validated instances: prompt → no bootable device → flash
  drive in → boot → typing → workshop → leave, no errors.
- **End-to-end scenarios** (`tests/scenarios`, one simulated server per computer):
  packages, ping/web pages/`msg`/DNS between computers in different servers, vi,
  the full Arch-style install then booting and logging into it, the games, the
  workshop website.

### Not yet verified in Roblox Studio

Nobody has pressed Play in Studio yet. The simulation catches API misuse, but expect
small fixes on first run (see the checklist in docs/SETUP.md). The cross-server
network can only be exercised in live servers.

## Next up (in order)

1. **Monitor for desktop environments:** `simple-framebuffer` in guest RAM
   (kernel `CONFIG_FB` + `CONFIG_FB_SIMPLE`), virtio-input for keyboard + mouse
   (`CONFIG_VIRTIO_INPUT`, `CONFIG_INPUT_EVDEV`), a display-mode switch (terminal vs
   graphics), guest tools so shell scripts can draw (`brickdraw`) and read input
   (`brickinput`), server-side dirty-tile streaming (LZ4), client rendering with
   EditableImage and mouse capture on the monitor.
2. **Auto install** (paid, in-game GUI button): `ComputerService.autoInstall(player)`
   writes a ready-made system to the disk; the owner wires the button and the pass.
3. **Studio smoke test** with the owner, and fixes from it.
4. **Offline messages:** a DataStore inbox for `msg` to players who aren't online.
5. **Speed / scale:** run the VM in an Actor; an instruction decode cache for 2x
   interpreted speed.
6. **Snapshots:** save a booted machine's RAM so power-on can resume instantly.
7. **Installer polish:** password prompt on first boot of an installed system,
   progress output in `brick`.
8. **Workshop:** likes/ratings, "my packages" view, unpublish from the GUI, package
   screenshots (text previews).
9. **More software:** an `edit` text editor that's friendlier than vi, games
   (2048, tetris), a `man`-style help system.

## Decisions waiting on the owner

- Which monetization ideas to build, and what stays free (see Monetization ideas).

- Moderation choices in `docs/MODERATION.md` (screen sharing, package contents, raw
  network traffic like `talk`/`webserver`).
- Game name / OS name (currently "Brick Linux", `Config.OS_NAME`).
- ~~Whether VMs should run on the server or on each player's client.~~ Settled by
  one-player servers: the VM stays on the server, which is dedicated to that player.
- Memory: 32 MB RAM per running computer (`Config.RAM_MB`).
