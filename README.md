# Linux in Roblox

Real Linux, running on a RISC-V CPU emulated in Luau, inside a Roblox game.

Walk up to a computer, press E, power it on, and you get a real Linux 6.8 kernel and a
busybox userland: `vi`, `awk`, `less`, `top`, `fdisk`, `wget`... You start in a
**live installer** and install **Brick Linux** onto your computer's disk yourself,
Arch-style (`fdisk`, `mkfs.ext2`, `brickstrap`), and your installed system is saved
with your account.

- **Community Workshop:** publish your own programs with `brick publish`, browse
  everyone's in the Workshop GUI, install them with `brick install`.
- **In-game internet:** every running computer is on a shared network. `ping alice`,
  host a website with the `webserver` package, `browse bob`, `talk` to each other.
- **A physical desk:** the terminal is drawn on a screen part in the world. Your
  keyboard types into it, and keys Roblox keeps for itself (like Esc) are on an
  on-screen keyboard or clickable keyboard parts.

## Quick start

1. Sync into Studio with [Rojo](https://rojo.space) (`rojo serve`), or `rojo build -o linux.rbxlx`.
2. Make a Model tagged `LinuxComputer` with a part named `Screen`.
3. Enable Studio API access (for DataStores), press Play, walk up to the desk, press E.

Details: [docs/SETUP.md](docs/SETUP.md).

## Docs

- [docs/SETUP.md](docs/SETUP.md): Studio setup, building the desk, settings
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

## Credits

- CPU semantics and base Linux configs: [cnlohr/mini-rv32ima](https://github.com/cnlohr/mini-rv32ima) (MIT).
- Linux, busybox (GPL-2.0) and uClibc-ng (LGPL-2.1) are built from upstream sources by
  `linux/build.sh`.
