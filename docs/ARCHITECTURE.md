# Architecture

```
  Player's keyboard / on-screen keys            Desk screen (SurfaceGui)
            │                                            ▲
            ▼  TerminalInput (bytes)                     │ TerminalOutput (bytes or snapshot)
 ┌──────────────────────────────── Roblox server ────────────────────────────────────┐
 │  ComputerService: one Computer per player, run every Heartbeat within a CPU budget │
 │                                                                                    │
 │  Computer ──► Firmware (BrickBIOS) ──► Machine (RISC-V VM) ──► Terminal (screen)   │
 │                                         │   │    │    │                            │
 │                     UART console ───────┘   │    │    └── virtio-net ──► NetworkService
 │                     virtio-blk (Disk) ──────┘    │            (switch + 10.0.0.1 gateway:
 │                          │                       │             ARP, ping, DNS)     │
 │                    DiskStore (DataStore)    HostLink mailbox ──► HostLinkCommands   │
 │                                                                  └► WorkshopService │
 │                                                                     (DataStore)     │
 └────────────────────────────────────────────────────────────────────────────────────┘
```

## The virtual machine (`src/shared/Emulator`)

| Module | What it is |
| --- | --- |
| `Cpu` | RV32IMA + Zicsr interpreter (machine and user mode, no MMU), following cnlohr's mini-rv32ima semantics. Registers are doubles holding unsigned 32-bit values; `bit32` and `buffer` do the work. Runs ~30 MIPS with native codegen (server), ~4 MIPS interpreted. |
| `Machine` | RAM (a `buffer`), memory map, device tree generation (`Fdt`), boot, and the run loop with guest time accounting (busy time follows instruction count, idle time follows the wall clock). |
| `Uart` | 8250/16550 console (polled by Linux). |
| `Plic` | Interrupt controller for the virtio devices. |
| `VirtioMmio` / `VirtioBlk` / `VirtioNet` | Standard virtio devices: Linux's own drivers give a real `/dev/vda` and `eth0`. |
| `Disk` | Sparse 4 KB-block disk (only written blocks use memory), compressed serialization. |
| `HostLink` | MMIO mailbox at `0x10001000`. The guest has no MMU, so user programs (`hostlink`) hand the device pointers to their own memory and the host copies data in and out directly. No kernel driver. |
| `ImageLoader` | Kernel images stored as LZ4 + base64 ModuleScripts. |

Memory map: UART `0x10000000`, host link `0x10001000`, virtio-blk `0x10002000` (irq 1),
virtio-net `0x10003000` (irq 2), PLIC `0x10400000`, CLINT `0x11000000`, syscon `0x11100000`,
RAM `0x80000000`.

## The guest OS (`linux/`)

Linux 6.8 (RV32 no-MMU) + busybox + uClibc, built by buildroot in GitHub Actions and
committed as `src/images/BrickLinux`. The initramfs is the live installer; `/init`
switches to an installed system on `/dev/vda1` if there is one. Brick Linux's own tools
(`brick`, `brickstrap`, `install-guide`) are shell scripts in
`linux/overlay`. See `linux/README.md`.

## Server (`src/server`)

| Module | What it does |
| --- | --- |
| `ComputerService` | Players ↔ computers ↔ desks, remotes, the per-frame CPU budget, output streaming, autosave. |
| `Computer` | One player's computer: VM + firmware + server-side Terminal. Streams raw console bytes, or a compact snapshot when output floods. |
| `Firmware` | BrickBIOS POST screen, countdown, boot menu (installed system / live installer / fallback kernel). |
| `DiskStore` | Disks in a DataStore: compressed, base64, chunked under 4 MB, two alternating slots so a failed save never corrupts the last good one. |
| `WorkshopService` | Packages: publish (validation, ownership, quota, TextService filtering), search, details, download. `OfficialPackages` are built in. |
| `HostLinkCommands` | What `hostlink` can ask for: `pkg.*` (workshop), `net.*` (who's online), `sys.*`. |
| `NetworkService` + `Net/Packet` | Ethernet switch between computers; gateway 10.0.0.1 answers ARP, ICMP echo, DNS (player names), and resets TCP. |

## Client (`src/client`)

| Module | What it does |
| --- | --- |
| `ComputerController` | Desk screens, client-side Terminals fed by the stream, focus mode (camera, keyboard capture, auto-repeat), physical key parts, zoomed 2D view. |
| `TerminalView` | Renders a Terminal with one RichText label per row (`<font>` colors, `<mark>` backgrounds) and a cursor. |
| `OnScreenKeyboard` | Keys Roblox reserves (Esc, F-keys...), sticky Ctrl/Alt, computer buttons, touch typing. |
| `WorkshopGui` | Browse/search the Community Workshop, install to your computer. |

## Why the VM runs on the server

Roblox servers run Luau with native code generation (about 30 MIPS here, enough to boot
Linux in a couple of seconds of CPU time). The server is also where the disk, the
workshop and the network naturally live, and it lets other players' computers stay
online. The emulator is engine-agnostic, so moving it to the client (or into Actors for
multi-core servers) is possible later; see the roadmap.

## Testing without Roblox

`tools/lune` runs the real modules under [Lune](https://lune-org.github.io/docs) with a
tiny `script`/`require` shim:

- `lune run tools/lune/test.luau`: unit tests in `tests/*.spec.luau`
- `lune run tools/lune/check.luau`: syntax-checks every Luau file
- `lune run tools/lune/world.luau tests/scenarios/<name>.txt`: boots several computers
  with the real services (workshop, network, host link) and scripts them
- `lune run tools/lune/boot.luau <Image>`: boot any image and watch the console
