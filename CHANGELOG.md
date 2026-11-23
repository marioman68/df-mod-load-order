# Changelog

## 1.3 – Hidden from the mod list, mod descriptions, clearer layout

- Mod Load Order no longer shows up in the mod list. DFHack loads it automatically, so there's nothing to add – subscribing is enough.
- If you already added it to your active list, it's left there (it's harmless either way).
- The Mod info tab now shows each mod's author and full description (read from its info.txt, so descriptions containing a colon are no longer cut short).
- Easier to read: section headers in every tab now have gold divider lines and yellow names.
- "All good" results (no problems, no conflicts, nothing to suggest) are now bright green with a check mark.

## 1.2 – Smaller panel

- The panel on the Mods screen is now about half as wide, so it fits better on smaller screens and lower resolutions.
- Simpler status line: shows "Load order OK" in green, or the problems in one line (e.g. "2 order, 1 missing, 1 conflict") in yellow or red.
- The panel now has the three main actions: Fix all, Undo and Details.
- Fix order and Remove conflicts are still available in the Problems tab of the Details window (Fix all also does both).

## 1.1 – New Workshop image

- New preview artwork for the Workshop page.
- No changes to the tool itself.

## 1.0 – Initial release

First release of Mod Load Order, a DFHack tool for the Create world → Mods screen.

- **Fix load order** – reorders your mods to satisfy every "must be before / after" rule, moving as few mods as possible and leaving vanilla mods in place.
- **Remove conflicts** – all conflicting mods in one checklist with suggested removals pre-ticked; one confirmation removes them.
- **Missing mod alerts** – warns when a mod needs another one that isn't active, and can copy Workshop search links for mods you don't have.
- **Hidden conflicts** – scans the mods' files for things two mods both define: duplicate objects (DF reports these as errors) and graphics overlaps (not game-breaking – the mod loaded first decides the look), each with a link to move just that mod.
- **Suggestions** – order suggestions for mods with no load-order rules, based on what their files change. Never applied automatically.
- **Newer versions** – spots active mods with a newer version installed and switches to them.
- **Mod info** – pick any mod to see its rules and which mods depend on it.
- **Create world warning** – warns if you click Create world while problems remain (click again to go ahead).
- **Undo** for every change, and **Save preset** to update your DFHack Mod Manager preset so the fixed list loads next time.

Requires DFHack. No need to enable it in your mod list – subscribing is enough.
