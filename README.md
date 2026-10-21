# CC Crafting Station

A Crafty Turtle that does the 3x3 crafting for Create 6 Factory Gauges, in place of mechanical crafters. The gauges do the ordering; each package carries its recipe; the turtle crafts and sends the results to storage. Build as many stations as you want: they're identical and share one address.

## One station

```
 [Frogport IN]    [Turtle]    [Packager OUT]     IN Frogport on the turtle's front, OUT Packager on its back
 [Packager IN]    [Barrel]    (+ its Frogport)   IN Packager attached to the Barrel under the turtle
```

- **Crafty Turtle** (turtle + crafting table).
- **Barrel under the turtle.** Ingredients are unpacked into it.
- **Input Packager** attached to that Barrel (place it against the Barrel's side, in front of the turtle).
- **Input Frogport** on top of the input Packager, so it touches the turtle's front. The turtle keeps its address at `CRAFT_ADDRESS` (default `MB-Crafting-In`). Several stations on one address share the work through Create itself: the input Packager only unpacks when the barrel has room, so a busy station's Frogport fills up and the chain carries packages on to the next station. (`TAKE_TURNS = true` makes stations take orders one at a time instead; slower, because the chain needs ~5 s to notice address changes.)
- **Output Packager on the turtle's back**, with its own Frogport (any unused address, e.g. `MB-Crafting-Out`). Results leave addressed to `OUT_ADDRESS`.

Tile stations side by side, turtle next to turtle. Use barrels, not chests, so neighbours don't merge.

**Frogport reached through wired modems** (stations' modems touching, so they share one network): leave `INPUT_SIDE` alone. A turtle that has no Frogport on its front pairs by itself: the first time one of the network's Frogports catches a package and exactly those items land in this turtle's barrel, that Frogport is its own. The pairing is saved; **Re-pair** on the Setup tab forgets it. Set every input Frogport to the shared address once before pairing. Or skip pairing: put INPUT_SIDE = "Create_Frogport_3" (that station's number, shown in chat when you right-click its modem) in /station.lua on the turtle. That file is the turtle's own settings, loaded after /config.lua, and survives updates. The barrel and the output Packager still have to touch the turtle.

Older layout, still supported: input Packager directly on the turtle's front (unpacking into the turtle) with its Frogport on top. That layout can't share load between stations: the first station takes every package.

## Install (on each turtle)

```
wget https://raw.githubusercontent.com/levisnakes/cc-crafting-station/main/crafting_station.lua startup.lua
```

Then `reboot`. It updates itself from GitHub (on start and every 15 minutes), keeping your settings.

## Gauges

Each Factory Gauge for a 3x3 crafting recipe sends to the shared crafting address, using either:

- **Use Custom Arrangement** (Factory Controller mod), recommended: lay the ingredients out like a crafting table, with the amount per slot = crafts per order. Orders arrive as whole packages, even through a Repackager.
- **Use Mechanical Crafting** (Create): works too, but a Repackager splits these into one package per craft; the turtle collects them and still crafts them together.

Packages without a recipe or arrangement are sent straight back to storage.

## Settings

At the top of the file, or in `/config.lua` (survives updates; can be shared by every computer):

- `CRAFT_ADDRESS` the shared crafting address (default `MB-Crafting-In`); `BUSY_ADDRESS` the address while busy
- `OUT_ADDRESS` where results go (default `MB-Storage-In`)
- `INPUT_SIDE`, `OUTPUT_SIDE` which side of the turtle each Packager is on (default `front` and `back`)
- `MAX_QUEUE` (default 0 = off): packages a station lets wait in its Frogport while it is working; past that it goes busy for a moment and the extras go back onto the chain to other stations, but only while another station is open. Leave it off unless you need it: when no Frogport has the crafting address, Create sends packages for it to any catch-all (`*`) Frogport on the network
- `QUIET_SECONDS` how long to wait after the last package before crafting everything at once
- `STATION_NAME` name in alerts (default: the turtle's label)
- `DISCORD_WEBHOOK`, `DISCORD_MENTION` ping when a station is stuck (not set up, buffer full, can't send, ingredients missing for 3+ min); a follow-up without a ping says when it's fixed

## On the turtle

Tabs **Status / Setup / Log** (click, or keys 1 2 3). **Send all back** (or S) sends everything in the turtle and barrel to storage; **Pause** (or P) stops crafting.

`probe.lua` is the setup test used while building this.

## Reboot every station from one turtle

Install on any one station (it reaches the others through the modem network):

```
wget https://raw.githubusercontent.com/levisnakes/cc-crafting-station/main/rebootall.lua rebootall.lua
```

`rebootall` lists the turtles on the network and asks, then reboots them all and this one last (turtles that are off are turned on). `rebootall -y` skips the question; `rebootall others` leaves this turtle running.
