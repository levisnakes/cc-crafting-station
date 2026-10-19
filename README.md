# CC Crafting Station

A Crafty Turtle that does the 3x3 crafting for Create 6 Factory Gauges, in place of mechanical crafters. The gauges do the ordering; each package carries its recipe; the turtle crafts and sends the results to storage. Build as many stations as you want: they're identical and share one address.

## One station

```
 [Frogport]                 Frogport address: your shared crafting address (e.g. MB-Crafty-In)
 [Packager] [Barrel]        Packager against the back of the turtle, Barrel on top of the turtle
            [Turtle]        a Crafty Turtle (turtle + crafting table)
```

- **Packager** touching the turtle (the turtle is its inventory). Only one Packager may touch each turtle.
- **Frogport** on the Packager, connected to your chain conveyor, address = the shared crafting address.
- **Barrel** on top of (or under) the turtle: the buffer it sorts ingredients in. Use barrels, not chests, so neighbouring stations don't merge into double chests.

Tile stations side by side: turtle next to turtle, Packager next to Packager, Barrel next to Barrel. Give every Frogport the same address.

## Install (on each turtle)

```
wget https://raw.githubusercontent.com/levisnakes/cc-crafting-station/main/crafting_station.lua startup.lua
```

Then `reboot`. It updates itself from GitHub (on start and every 15 minutes), keeping your settings.

## Gauges

On each Factory Gauge for a 3x3 crafting recipe: open **Recipe Settings**, turn on **Use Mechanical Crafting**, and set the address to the shared crafting address. Packages without a recipe are sent straight back to storage.

## Settings

At the top of the file, or in `/config.lua` (survives updates; can be shared by every computer):

- `OUT_ADDRESS` where results go (default `MB-Storage-In`)
- `QUIET_SECONDS` how long to wait after the last package before crafting everything at once
- `STATION_NAME` name in alerts (default: the turtle's label)
- `DISCORD_WEBHOOK`, `DISCORD_MENTION` ping when a station is stuck (not set up, buffer full, can't send, ingredients missing for 3+ min); a follow-up without a ping says when it's fixed

## On the turtle

Tabs **Status / Setup / Log** (click, or keys 1 2 3). **Send all back** (or S) sends everything in the turtle and barrel to storage; **Pause** (or P) stops crafting.

`probe.lua` is the setup test used while building this.
