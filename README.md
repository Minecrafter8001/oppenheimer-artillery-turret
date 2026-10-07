this is my fork of Snerpes's [oppenheimer-artillery-turret](https://mods.factorio.com/mod/oppenheimer-artillery-turret) mod

i didn't like some of the changes that OP made so i thought id fork it, this is allowed under the MIT licence

## Blast terrain and reclamation

Blast-created ground uses this mod's own tile prototypes. Its temporary lava
cannot supply offshore pumps; natural lava remains unchanged. The glaze cools
completely, including the center of the crater.

On Nauvis, Zen Garden and Early Agriculture artificial grass can cover cooled
blast terrain, including crater floors and rims. Active lava and hot or warm
glaze cannot be covered. Other planets use separate tile variants and do not
gain these grass placement permissions. Turret foundation paving is unchanged.

Existing terrain is not migrated. The new tile variants and reclamation
permissions apply when the mod paints terrain after this update.

## Focused tests

Run `npx --yes --package fengari-node-cli fengari tests/terrain.lua` for the
mocked Factorio regression suite. Actual pump placement, construction robots,
and visual transitions should also be checked in-game.
