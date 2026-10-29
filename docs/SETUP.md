# Setting it up in Roblox Studio

## 1. Get the code into Studio (Rojo)

The project is a [Rojo](https://rojo.space) project (`default.project.json`):

| Folder | Becomes |
| --- | --- |
| `src/shared` | `ReplicatedStorage.LinuxVM` (emulator, terminal, config) |
| `src/server` | `ServerScriptService.LinuxServer` (Script + modules) |
| `src/client` | `StarterPlayer.StarterPlayerScripts.LinuxClient` (LocalScript + modules) |
| `src/images` | `ServerStorage.LinuxImages` (the Linux kernel images) |

Either:

- **Live sync:** install the Rojo Studio plugin and the `rojo` CLI, run `rojo serve` in
  the repo, and press *Connect* in the plugin, or
- **One-off build:** `rojo build -o linux.rbxlx`, then open that file and copy your
  desk into it (or copy the four folders above into your own place).

## 2. Turn on DataStores

Disks (players' installed systems) and the Community Workshop are saved in DataStores.

- *Game Settings → Security → Enable Studio Access to API Services* (for Studio testing).
- The place must be published for DataStores to work at all.

Without DataStores everything still runs, but nothing is saved: you'll see a warning in
the output, and players get a "saving is unavailable" notice.

## 3. Build a computer desk

Any **Model** tagged **`LinuxComputer`** becomes a computer. Use the Tag Editor
(*View → Tag Editor* or the *Tags* section of the Properties window) to add the tag.

Inside the model:

| Name | Type | Required | What it does |
| --- | --- | --- | --- |
| `Screen` | BasePart | **yes** | The monitor. The terminal is drawn on its **Front** face. |
| `Seat` (any name) | Seat | no | The player sits here while using the computer. |
| `PowerButton` | BasePart | no | Clicking it turns the computer on/off (only for whoever is using it). |
| `Key_<KeyCode>` | BasePart | no | Clickable keys on a physical keyboard model, see below. |

The game adds a **"Use computer"** ProximityPrompt (key **E**) to the Screen part.

### Screen tips

- If your monitor faces another way, set a string attribute **`ScreenFace`** on the
  desk model to `Back`, `Left`, `Right`, `Top` or `Bottom`.
- The terminal is 80×25 characters. A screen face around **16:10** (e.g. 4 × 2.5 studs)
  fills nicely; other shapes get letterboxed.
- The screen glows (it ignores lighting), so a dark bezel around it looks good.

### Physical keyboard keys (optional)

Name parts `Key_` + a Roblox `KeyCode` name: `Key_Escape`, `Key_Tab`, `Key_A`,
`Key_Return`, `Key_Space`, `Key_Up`, `Key_F1`... Two special names latch a modifier
for the next key: `Key_Ctrl`, `Key_Alt`. Clicking a key while using that desk sends it,
which is how players reach keys Roblox keeps for itself, like **Esc**. The same keys are
always on the on-screen keyboard too.

## 4. Community Workshop kiosks (optional)

Any part or model tagged **`WorkshopKiosk`** gets a "Browse" prompt that opens the
Workshop. There is also a 📦 button in the top-left corner for everyone.

## 5. Settings

Everything tweakable is in `src/shared/Config.luau`: RAM and disk size, how much server
CPU the computers may use per frame, whether other players can see your screen,
DataStore names, workshop limits, network settings.

## How players use it

1. Walk up to a desk and press **E**. The camera moves to the screen and your keyboard
   now types into the computer (movement is paused). The on-screen bar has Esc, Tab,
   Ctrl/Alt latches, arrows, F-keys and the computer's buttons.
2. Press **⏻ Power**. The firmware (BrickBIOS) counts down and boots Linux.
3. The first time, you're in the **live installer**: run `install-guide` and install
   Brick Linux to your disk Arch-style. (The only shortcut will be the paid
   auto-install button in your game's GUI; see docs/ROADMAP.md.)
4. After a reboot your installed system starts, and it's saved with your account.
5. `brick search`, `brick install <pkg>`, `brick publish <dir>`: packages from and to
   the Community Workshop. `ping <username>`, `talk`, `browse`: the in-game network.
6. **⏏ Leave** (or walking away) returns control to your character. Your computer keeps
   running while you're in the server, so things like web servers stay up.

## First-run checklist (Studio)

The game logic was developed and tested outside Roblox (see `tools/lune/sim.luau`,
which runs the real server and client scripts against a validated mock of Roblox).
On the first Play in Studio, check:

1. **Output** shows no red errors from `LinuxServer` / `LinuxClient`. A yellow warning
   about DataStores is expected unless API access is enabled.
2. Walk to the desk: a **"Use computer"** prompt appears; press **E**.
3. The camera moves to the screen and the on-screen keyboard bar appears at the bottom.
4. Click **⏻ Power**: the BrickBIOS screen counts down, then Linux boots (about 5 s).
5. Type `ls` and Enter. Try **Esc** from the bar, and **🔍 Zoom** for a big 2D view.
6. Run `brick search` and `brick install cowsay`, then `cowsay hi`.
7. Click **⏏ Leave**: your character can move again.

If something fails, the Output window's first error is the most useful thing to send back.

## Performance notes

- One busy computer takes up to `Config.MAX_COMPUTER_BUDGET` (8 ms) of server time per
  frame; all computers together take at most `Config.FRAME_BUDGET` (10 ms).
- An idle computer costs ~1–2% of a core (less with the tickless kernel).
- Each running computer holds `Config.RAM_MB` (32 MB) of server memory.
