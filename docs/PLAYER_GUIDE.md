# Player guide

Everything a player can do with their computer, from the first boot to publishing
software. (Written for players; feel free to reuse it in-game.)

## Using the computer

- Walk up to the desk and press **E**. Your keyboard now types into the computer and
  your character stays put. **⏏ Leave** (or walking away) gives you control back.
- Keys Roblox keeps for itself, like **Esc**, F-keys and Ctrl/Alt combinations, are on
  the on-screen keyboard bar (and on the desk's keyboard, if it has clickable keys).
  **Ctrl** and **Alt** on the bar latch for the next key: Ctrl then C sends Ctrl-C.
- **⏻ Power** turns the computer on and off. **↻ Reset** restarts it.
  **🔍 Zoom** shows the screen big and flat.

## Starting up

When the computer powers on, the firmware (BrickBIOS) checks its hardware and boots:

1. **the disk**, if Brick Linux is installed on it,
2. otherwise **the installer flash drive**, if one is plugged into the desk,
3. otherwise it says **No bootable device**. Plug in the flash drive and press a key.

Press **F2** or **Esc** during the countdown for the boot menu, e.g. to run the
installer again from the flash drive even though the disk has a system.

## Installing Brick Linux (the Arch way)

The flash drive starts a **live system**: everything works, but nothing is kept when
you turn the computer off. To keep your files, install Brick Linux onto the disk:

```sh
install-guide          # the full guide, on screen (q to quit)
fdisk /dev/vda         # o, n, p, 1, Enter, Enter, w  -> one partition, /dev/vda1
mkfs.ext2 /dev/vda1    # format it
mount /dev/vda1 /mnt
brickstrap /mnt        # copy the system onto the disk (add package names to include them)
echo mybox > /mnt/etc/hostname
brick-chroot /mnt passwd   # optional: a password for root
umount /mnt
reboot
```

Take the flash drive out whenever you like after this. The computer boots from the
disk from now on. Log in as `root` (no password unless you set one).

Your disk is saved with your Roblox account automatically: every couple of minutes
while you play, shortly after programs write to it (`sync`), when you turn the
computer off, and when you leave. Next time you play, it's all still there.

## Software: `brick` and the Community Workshop

| Command | What it does |
| --- | --- |
| `brick search [words]` | Find packages in the Community Workshop |
| `brick info <pkg>` | Details, files and readme |
| `brick install <pkg>...` | Download and install (dependencies too) |
| `brick remove <pkg>...` | Uninstall |
| `brick list` | What's installed |
| `brick upgrade` | Update everything to the newest versions |
| `brick new <name>` / `brick publish <dir>` | Make and share your own (see [PACKAGES.md](PACKAGES.md)) |
| `brick unpublish <pkg>` | Take one of your packages down |

Pacman-style flags work too: `brick -Ss`, `-S`, `-R`, `-Q`, `-Syu`.

The **📦 Workshop** button (and Workshop kiosks) lets you browse everything outside the
computer. "Install" types the `brick install` command for you.

Some official packages to start with: `cowsay`, `fortune`, `sl`, `matrix`, `lolcat`,
`banner`, `snake`, `guess`, `todo`, `webserver`, `browse`, `talk`.

## The in-game internet

Computers are connected to each other and to the Community Workshop, nothing else.
Every computer is named after its owner (lowercase username).

```sh
hostlink net.who            # who's online: name, address, owner
ping alice
browse workshop             # the Community Workshop as a website
brick install webserver     # host your own site from /www
browse alice                # visit someone's site
msg alice hi there          # message a player (filtered like chat); `msg` reads yours
```

Busybox network tools are all there: `wget`, `nc`, `telnet`, `httpd`, `ifconfig`, `ip`.

Each game server has one player, so other players' computers are in other servers.
They're still reachable by name (their addresses look like `10.1.x.y` from your
computer), but the link is slower than a real network: up to about a second of
delay and a few KB per second. Big downloads from other players will crawl. Computers
are only online while their owner is playing.

## Handy things

- `vi` is the text editor. `less` pages through files. `top` shows what's running.
- **Ctrl-C** stops a running program. `clear` (or Ctrl-L) clears the screen.
- `poweroff` and `reboot` shut down cleanly (and save your disk).
- `brickfetch` shows off your system.
