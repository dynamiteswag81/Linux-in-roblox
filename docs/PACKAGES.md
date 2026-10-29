# Making packages for the Community Workshop

A package is a folder with a manifest and the files to install. `brick publish` packs
it as a tar archive and uploads it, and then anyone can `brick install` it.

## Quick start

```sh
brick new hello2            # creates ./hello2 with a manifest and an example script
vi hello2/BRICK             # set the version and description
vi hello2/files/usr/bin/hello2
brick publish hello2
brick install hello2        # try it like everyone else will
```

## Layout

```
hello2/
├── BRICK          manifest (required)
├── files/         installed relative to / : files/usr/bin/x -> /usr/bin/x
├── README         optional (or README.md / README.txt), shown in the Workshop
└── install.sh     optional, runs after the files are copied (make it executable)
```

`BRICK` is `key=value` lines:

```
name=hello2
version=1.0
description=Says hello, but better
depends=cowsay fortune
```

| Key | Rules |
| --- | --- |
| `name` | 1-32 characters: `a-z 0-9 . _ + -`, starting with a letter or digit. Must match what you publish. Official package names are taken. |
| `version` | Up to 32 characters of `A-Z a-z 0-9 . _ + ~ -`. Change it whenever you publish an update: `brick upgrade` installs a package again when the version differs. |
| `description` | One line, up to 200 characters. |
| `depends` | Package names separated by spaces. They're installed first. |

## Limits

- An archive can be at most 1 MB (`Config.MAX_PACKAGE_BYTES`), and you can own at
  most 50 packages (`Config.MAX_PACKAGES_PER_PLAYER`). Wait 20 seconds between
  publishes.
- Only you can update or unpublish your packages (`brick unpublish <name>`).
- The name, description and README go through Roblox text filtering. A name the
  filter would change is rejected. Descriptions and READMEs are shown filtered.
- There's no compiler inside the computer. Packages are shell scripts (busybox `sh`,
  `awk`, `sed`...) plus any data files.

## Writing programs

- Scripts start with `#!/bin/sh` and need `chmod +x`.
- The shell is busybox `hush`. It has functions, `$(...)`, `case`, `read`, and
  arithmetic `$((...))`, but no arrays and no aliases.
- The terminal is a VT100/xterm subset, 80x25. Colors (`\033[1;32m`), cursor
  movement (`\033[row;colH`), hiding the cursor (`\033[?25l`) and the alternate screen
  (`\033[?1049h`) all work. See the `snake` package for a full-screen game that
  reads single keys with `stty -icanon -echo min 0 time 1` and `read -r -n 1`.
- `hostlink <command>` talks to the game: `hostlink help` lists the commands,
  e.g. `sys.whoami` (the player's username), `sys.time`, `net.who`, `msg.send`.
- Networking is ordinary Linux: `nc`, `wget`, `httpd`. Other players' computers are
  reachable by their username.

## What `brick install` does

1. Downloads the archive through the host link and unpacks it in `/tmp`.
2. Installs anything in `depends` that isn't installed yet.
3. Copies `files/` to `/` and records the file list in `/var/lib/brick/local/<name>/`.
4. Runs `install.sh` if there is one.

`brick remove` deletes the recorded files (not directories, not files your
`install.sh` created).
