# Linux in Roblox

Real Linux, running on a RISC-V CPU emulated in Luau, inside a Roblox game.

Walk up to a computer, press E, power it on, and you get a real Linux 6.8 kernel and a
busybox userland: `vi`, `awk`, `less`, `top`, `fdisk`, `wget`... Plug in the installer
flash drive, boot the **live installer**, and install **Brick Linux** onto your
computer's disk yourself, Arch-style (`fdisk`, `mkfs.ext2`, `brickstrap`). Your
installed system is saved with your account.

- **Community Workshop:** publish your own programs with `brick publish`, browse
  everyone's in the Workshop GUI, install them with `brick install`.
- **In-game internet:** players' computers and the Community Workshop are networked.
  `ping alice`, host a website with the `webserver` package, `browse bob`, `talk`
  to each other. (Each server has one player; the cross-server relay is next on the
  roadmap.)
- **A physical desk:** the terminal is drawn on a screen part in the world. Your
  keyboard types into it, and keys Roblox keeps for itself (like Esc) are on an
  on-screen keyboard or clickable keyboard parts.

## Quick start

1. Sync into Studio with [Rojo](https://rojo.space) (`rojo serve`), or `rojo build -o linux.rbxlx`.
2. Make a Model tagged `LinuxComputer` with a part named `Screen`.
3. Enable Studio API access (for DataStores), press Play, walk up to the desk, press E.
4. Power on, then set the desk's `FlashDrive` attribute to true to boot the installer.
   Your game's flash drive item does that for players.

Details: [docs/SETUP.md](docs/SETUP.md).

## Docs

- [docs/SETUP.md](docs/SETUP.md): Studio setup, building the desk, the flash drive hook, saving, settings
- [docs/PLAYER_GUIDE.md](docs/PLAYER_GUIDE.md): using the computer, installing, packages, network
- [docs/PACKAGES.md](docs/PACKAGES.md): making and publishing Workshop packages
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how it works
- [docs/ROADMAP.md](docs/ROADMAP.md): status and what's next
- [docs/MODERATION.md](docs/MODERATION.md): text filtering decisions
- [linux/README.md](linux/README.md): the guest OS and how it's built

## Development

The emulator and server logic run outside Roblox under [Lune](https://lune-org.github.io/docs):

```sh
lune run tools/lune/test.luau                                       # unit tests
lune run tools/lune/check.luau                                      # syntax check everything
lune run tools/lune/world.luau tests/scenarios/packages-and-network.txt   # end-to-end
```

## What's written for this project, and what isn't

Written here, from scratch:

- the RISC-V emulator (`src/shared/Emulator`): CPU, UART, PLIC, CLINT timer, virtio
  disk and network, the host link, the device tree generator;
- the terminal emulator, firmware, server (computers, saving, the Community Workshop,
  the in-game network with its gateway, DNS and TCP/HTTP server), and the client;
- Brick Linux's own parts (`linux/overlay`, `linux/src`): `/init`, the `brick`
  package manager, `brickstrap` and the install tools, `hostlink`, the official
  packages, and the build/test tooling.

Not written here: the operating system's building blocks are upstream open source,
compiled from source by CI (`linux/build.sh`) with our configs and patches:
Linux 6.8 (GPL-2.0), busybox 1.36 (GPL-2.0), uClibc-ng (LGPL-2.1), through buildroot.
Bugs we hit in them are fixed with patches in `linux/patches/`.

## Credits

- CPU semantics, the RV32 no-MMU buildroot fork and base Linux configs:
  [cnlohr/mini-rv32ima](https://github.com/cnlohr/mini-rv32ima) (MIT).
- Linux, busybox (GPL-2.0) and uClibc-ng (LGPL-2.1) are built from upstream sources by
  `linux/build.sh`.
