# Text filtering and moderation

Roblox requires that text one player creates is filtered (`TextService`) before other
players see it. A computer you can type anything into touches that rule in a few
places. Here is what the game does today, and the choices that are yours to make.

## What's filtered now

- **Workshop package names, descriptions and READMEs** are run through
  `TextService:FilterStringAsync(...):GetNonChatStringForBroadcastAsync()` when published
  (`WorkshopService.publish`). A name that the filter changes is rejected; descriptions
  and READMEs are stored filtered. If filtering is down, publishing is refused rather
  than storing unfiltered text.

## What isn't filtered (decisions for you)

1. **Screens of other players' computers.** By default (`Config.SHOW_SCREENS_TO_OTHERS =
   false`) only the person using a computer sees its terminal; everyone else sees
   "In use by <name>". Turning sharing on would show unfiltered terminal text to
   others. Filtering a live terminal isn't practical, so leave it off unless Roblox
   policy says otherwise for your experience.
2. **Package file contents.** Scripts and text files inside workshop packages are not
   filtered: filtering would break code (`###` in a script), and the files are only
   seen when a player chooses to install and open them. Options if this matters:
   filter every text file at publish time (and accept broken scripts), or require
   packages to pass a review queue before they're listed.
3. **The in-game network.** Computers exchange raw network traffic (`talk`, `nc`,
   web pages from `webserver`). That is player-to-player text that isn't filtered. Options:
   leave it, filter the `talk` package's messages through a host-side chat bridge
   instead of raw `nc`, or restrict network features to friends.

None of these are blocking for testing in Studio, but they're worth deciding before a
public launch.
