# Node Ledger

Remembers every mining, herb, fishing and treasure node you come across in WoW Forever and Retail and rings
it on the minimap and world map:

| Ring   | Node             |
|--------|------------------|
| Brown  | Mining           |
| Green  | Herb             |
| Purple | Treasure         |
| Blue   | Fishing pool     |
| Gold inner ring | the spawn point has spawned as more than one node (Mithril / Truesilver) |

## How nodes are found

- **Gathering**: herbing, mining, opening a chest or looting a treasure records the node where you stand,
  with everything that came out of it (and any coin).
- **Fishing pools**: fishing loot from a pool, placed where the bobber lands (about 17 yards ahead).
- **Minimap hover**: hovering a tracked blip on the minimap records the node under the cursor. The client
  draws tracking blips itself and gives addons no list of them, so a blip is only recorded once you hover
  it. Zooming the minimap in makes a hover more accurate.
- **Treasure vignettes** (Retail): recorded with their exact position as soon as they appear.

Every sighting within the merge radius (15 yards by default) of a node of the same kind is the same spawn
point. Its position is a weighted average of every sighting, with gathers and vignettes weighted above
hovers.

## Sharing with your guild and friends

Everything you find is shared, and so is everything they find:

- **Guild**: sent on the guild addon channel.
- **Friends**: whispered to online character friends who aren't in your guild, and sent over Battle.net to
  Battle.net friends playing the same game.

Finds are sent in batches every 10 seconds, at most one message a second. Gathers carry their haul, so
your friends' averages include yours. Received finds are merged like your own, never passed on, and only
taken from the guild channel and people on your friends lists, rate-limited per sender. Retail and Forever
don't mix, because their map IDs mean different places.

## Tooltips

Hover a ring (on the minimap or world map) or a minimap blip to see:

- what the point spawns as, e.g. `Mithril Deposit 82% (14)`, `Truesilver Deposit 18% (3)`
- how many times it's been gathered and when it was last seen
- the average haul of each spawn, `here / all`: this node beside every node of that name, plus how often
  each item drops

## Commands

```
/nodes stats                    node counts, here and everywhere
/nodes toggle <kind>            show or hide mine, herb, fish or treasure
/nodes size <pixels>            minimap ring size
/nodes merge <yards>            how close two sightings must be to count as one node
/nodes worldmap                 show or hide world map rings
/nodes forget                   remove the nearest node within 30 yards
/nodes wipemap confirm          remove every node on this map
/nodes share                    show what is shared
/nodes share on|off             turn sharing (send and receive) on or off
/nodes share guild|friends      toggle sending to the guild or friends
/nodes share receive            toggle taking others' finds
/nodes debug                    toggle debug messages
```

## Development

```
luacheck .
busted
```
