# Snow

A tiny macOS menu-bar app that makes it snow on your desktop. Windows behave like houses: snow piles up
on their title bars, sticks to their walls, slides off when you move them, and drifts up at the bottom
of the screen. Tilt your MacBook and the snow follows gravity. When it gets too deep, call the snowplows.

One Swift file, no dependencies, no Xcode project.

## Features

- **Falling snow** over the desktop, with flakes of different sizes (smaller ones are dimmer and slower,
  so they read as farther away).
- **Windows are houses**
  - snow settles on the top edge of every window and slides off the sides at the angle of repose;
  - it never falls in front of an app: flakes that hit a side wall stop and slide down it, and some of
    them stay plastered to the wall, slowly creeping down and dropping off over time;
  - about 30% of the snow falls *behind* the windows, so the ground under a window gets a thinner layer
    than open ground;
  - snow on a window hidden by another one is clipped exactly at the edge of the window in front;
  - move or resize a window and its snow falls off (and lands back on it if you only nudged it); close it
    and the snow drops to the ground;
  - snow is kept for windows on another Space or minimized, and comes back with them.
- **Ground drifts** at the bottom of the screen, which pile up against the screen edges.
- **Gravity from the laptop's tilt** (Apple Silicon MacBooks): flakes fall at an angle, settled snow slides
  downhill, and once the slope beats friction a whole roof of snow slides off as a slab and is thrown off
  the edge.
- **Blizzard**: 15 seconds of heavy snow with random gusts. Windows shelter the air behind them, and wind
  blows snow in from the side of the screen it comes from.
- **Snowplows**: a convoy of trucks (one per ~32 pt layer of snow, up to 10) drives across the bottom of the
  screen. Each one scrapes one layer, rides on the packed snow it leaves, tilts on slopes, and pushes a heap
  that slumps forward like real snow; what doesn't fit is thrown over the blade.
- **Multiple displays**: snow on the main screen only, or on all screens. External monitors don't tilt.

## Requirements

- macOS on Apple Silicon (developed and tested on an M-series MacBook running macOS 27).
- Swift toolchain (Xcode or the Command Line Tools) — `swiftc` is all the build needs.
- Tilt needs the built-in accelerometer of Apple Silicon MacBooks. On other Macs the app works the same,
  with snow falling straight down.

## Build and run

```sh
./build.sh          # compiles Snow.swift into Snow.app and ad-hoc signs it
open Snow.app
```

The app has no Dock icon: look for the snowflake in the menu bar.

To check the snow physics (piles, avalanches, slab slides):

```sh
Snow.app/Contents/MacOS/Snow --selftest
```

## Menu

The menu is in Italian:

| Item                   | What it does                                                         |
|------------------------|----------------------------------------------------------------------|
| *Nevicata* slider      | Snowfall intensity; all the way left stops it                        |
| Tormenta di neve (⌘T)  | Starts a 15 s blizzard with random gusts                             |
| Chiama lo spazzaneve (⌘P) | Sends the snowplow convoy                                         |
| Tutti gli schermi      | Snow on every display instead of the main one only (remembered)      |
| Inverti inclinazione   | Flips the tilt direction if the snow slides the wrong way            |
| Esci (⌘Q)              | Quits and switches the accelerometer back off                        |

## How it works

- **Overlay**: one transparent, click-through, borderless window per screen, just above the Dock, on all
  Spaces. Everything is drawn with Core Graphics at 30 fps.
- **Windows**: the app polls `CGWindowListCopyWindowInfo` about 10 times a second for the bounds of
  on-screen windows. It only reads their position and size, so no Screen Recording permission is needed.
- **Settled snow** is a heightmap with 2 pt columns: one for the ground and one per window roof. Each flake
  adds its own volume when it lands, and a simple angle-of-repose relaxation lets piles slump, slide with
  the tilt, and spill over roof edges.
- **Slab slides** use static and kinetic friction, so snow holds on gentle slopes and slides off as a whole
  layer on steep ones.
- **Accelerometer**: Apple Silicon MacBooks expose the motion sensor as a vendor HID device
  (`AppleSPUHIDDriver`, usage page `0xFF00`, usage `3`). The app enables only that sensor at 50 Hz, reads its
  sideways axis, and switches it off again on quit. This is undocumented hardware access and might change
  with future macOS versions.

## Tuning

The values that define the feel of the snow are marked in the source with `ponytail:` comments:

| What                         | Where to look                          |
|------------------------------|----------------------------------------|
| How fast snow piles up       | `0.6 = fluffiness` in `Pile.add`       |
| Friction of sliding slabs    | `μ static 0.4` in `Pile.slide`         |
| Fall speed of heavy clumps   | `1400 pt/s²` in `SnowView.step`        |
| Blizzard duration            | `startStorm()`                         |
| Share of snow behind windows | `30% of the snow falls behind windows` |
| How long snow clings to walls| `~15 s average grip`                   |

## Known limitations

- Tilt was tuned by feel; if the snow slides the wrong way, use *Inverti inclinazione*.
- A maximized window acts as a roof for the whole screen, so almost no snow is visible behind it.
- Snow is drawn on the CPU: around 10–15% of a core with normal snowfall on one screen, more during a
  blizzard or with several displays.
- The snowplows and the ground drifts are drawn above the Dock.
