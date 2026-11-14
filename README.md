<img src="logo.png" width="128" alt="Forever Item Tracker PLUS logo">

# Forever Item Tracker PLUS

A minimalist WoW Forever addon that does six things:

1. **Alt inventory on tooltips.** Hover any item to see how many each of your characters has, with an icon for where it is: bags, bank, mail or equipped. Hover your gold (the backpack button, or the coins at the bottom of your bags) to see every character's gold and a total. The game's vendor sell price is moved down next to the AH price, so the prices sit together.
2. **Auction house prices on tooltips.** While the auction house is open, Forever Item Tracker PLUS runs a full scan (at most once every 15 minutes, the server's limit), with a small progress bar above the auction house window. Stay at the auction house until it says the scan is complete. Tradeable items then show the lowest buyout per unit from the last scan and how long ago it ran. The age turns red after 12 hours.
3. **Bank restocking.** At the bank, the **Deposit** button (bag → bank, below the bank window) moves every item in your bags that the bank already has into the bank, and **Withdraw** (bank → bag) moves every item in your bank that your bags already have into your bags. To move just one item, Ctrl+click it: every stack of it goes to the other side.
4. **Sell all of an item.** At a vendor, Ctrl+right-click an item in your bags to sell every stack of it you're carrying. The total it sold for is printed in chat.
5. **Crafting cost and profit.** In your professions window, each recipe in the list shows what its reagents cost at the last auction house scan's prices (a grey +? means a reagent had no price). The selected recipe shows its profit after the AH's 5% cut, with the scan's age beside it; hover it for a breakdown per reagent. Reagents you can make yourself are priced by what their own reagents cost.
6. **Disenchant value.** Armor and weapons of uncommon quality and up show their average disenchant value under the AH price: the Classic disenchant chances for their item level, quality and type, with each material at its last AH scan price. Soulbound gear shows it too.

## Install

1. Download the latest `ForeverItemTrackerPlus-*.zip` from [Releases](https://github.com/ashishkhatri/foreverledger/releases).
2. Unzip it into `World of Warcraft\_forever_\Interface\AddOns\`, so you end up with `AddOns\ForeverItemTrackerPlus\ForeverItemTrackerPlus.toc`.
3. Restart the game (not just `/reload`) the first time, so the icons load.

Log into each character once, and open the bank and mailbox on it, so its items are recorded.

## Commands

Use `/fitp` or `/itemtracker`.

| Command | What it does |
| --- | --- |
| `/fitp scan` | Scan the auction house now (it must be open) |
| `/fitp auto` | Turn automatic scanning on or off |
| `/fitp gold` | Print every character's gold to chat |
| `/fitp deposit` | Move every bag item the bank already has into the bank (same as the Deposit button) |
| `/fitp withdraw` | Move every bank item your bags already have into your bags (same as the Withdraw button) |
| `/fitp bags` | List the bag containers being scanned |
| `/fitp forget Name[-Realm]` | Remove a character |

## Notes

- A full auction house scan can freeze the game for a few seconds on busy realms. Use `/fitp auto` to turn it off and scan by hand instead.
- Prices are stored per realm and faction, so a scan at a neutral auction house replaces your faction's prices.
- Mail sent to an alt is counted once you open that alt's mailbox.

## Releasing

Change the `## Version:` line in `ForeverItemTrackerPlus.toc` (for example to `1.2.0`) and push to `main`. The Release workflow tags that version, builds `ForeverItemTrackerPlus-v1.2.0.zip` and publishes it as a GitHub Release. If the `CF_API_KEY` repository secret is set, it also uploads the zip to [CurseForge](https://www.curseforge.com/) (project ID from `## X-Curse-Project-ID:` in the `.toc`), tagged with the newest WoW Forever game version. A version that's already been released is skipped. You can also run the workflow by hand from the Actions tab.

## License

MIT
