<img src="logo.png" width="128" alt="Forever Item Tracker PLUS logo">

# Forever Item Tracker PLUS

A minimalist WoW Forever addon that does eight things:

1. **Alt inventory on tooltips.** Hover any item to see how many each of your characters has, with an icon for where it is: bags, bank, mail or equipped. Hover your gold (the backpack button, or the coins at the bottom of your bags) to see every character's gold and a total. The game's vendor sell price is moved down next to the AH price, so the prices sit together. For a stack in your bags or bank, the Vendor and AH prices are for the whole stack (the label shows the count, like "AH x20").
2. **Auction house prices on tooltips.** While the auction house is open, Forever Item Tracker PLUS runs a full scan automatically (at most once an hour), with a small progress bar above the auction house window. Stay at the auction house until it says the scan is complete. The **Full Scan** button under the auction house window scans on demand and counts down when the server needs you to wait (one full scan per 15 minutes); right-click it to turn automatic scans on or off. Posting auctions doesn't work while a scan runs, so the Post button is grayed out until the scan finishes, and automatic scans wait until you leave the Sell tab. Tradeable items then show the lowest buyout per unit from the last scan and how long ago it ran. The age turns red after 12 hours.
3. **Bank restocking.** At the bank, the **Deposit** button (bag → bank, below the bank window) moves every item in your bags that the bank already has into the bank, and **Withdraw** (bank → bag) moves every item in your bank that your bags already have into your bags. To move just one item, Ctrl+click it: every stack of it goes to the other side. Talking to a banker opens your bank straight away, without the dialogue (hold Shift to see the dialogue).
4. **Sell all of an item.** At a vendor, Ctrl+right-click an item in your bags to sell every stack of it you're carrying. The total it sold for is printed in chat. The coin button on your bags sorts them by value: the most valuable stacks first (count times the higher of the AH and vendor price).
5. **Crafting cost and profit.** In your professions window, each recipe in the list shows what its reagents cost at the last auction house scan's prices (a grey +? means a reagent had no price). The selected recipe shows its profit after the AH's 5% cut, with the scan's age beside it; hover it for a breakdown per reagent. Reagents you can make yourself are priced by what their own reagents cost.
6. **Disenchant value.** Armor and weapons of uncommon quality and up show their average disenchant value under the AH price: the Classic disenchant chances for their item level, quality and type, with each material at its last AH scan price. Soulbound gear shows it too.
7. **Waylaid Crates.** A crate's tooltip shows its cheapest fill at the last AH scan's prices (for example 20 x Peacebloom), or the crafting cost if you can make a fill item for less.
   **Craftsman's Writs** work the same way: the tooltip shows the item the writ asks for, its AH price, and what it costs to make yourself if you know the recipe.
   **Recipes** (patterns, plans, manuals and so on) show the cost to craft what they teach: a total at the last AH scan's prices, then one line per reagent (for example 2 x Silk Cloth). A reagent you can make yourself counts at whichever is cheaper.
8. **Ledger.** Every money transaction on every character. Click the coin button on the minimap (drag it to move it) to open it. It opens on the character you're playing and today, with one row per source (loot, quests, vendors, repairs, auction house, mail, trades, training, flights, guild bank) showing how many transactions and how much was earned, spent and net. Click a source to see its transactions like a spreadsheet: date, character, details (the item sold or bought, the quest, who the mail or trade was from, where you flew) and amount; click a column to sort, scroll to page through, and **< All sources** to go back. Pick another time range (yesterday, last 7 or 30 days, all time) from the dropdown, use the arrows to show another character or all of them, and **Copy as CSV** to paste what's shown into a real spreadsheet. The bottom line totals what's shown; hover it for earned and spent by source. Looted gold, including your share when others loot, is one row per character per day (for example "looted 37 times"). It keeps the last 10,000 transactions.

## Install

1. Download the latest `ForeverItemTrackerPlus-*.zip` from [Releases](https://github.com/ashishkhatri/foreverledger/releases).
2. Unzip it into `World of Warcraft\_forever_\Interface\AddOns\`, so you end up with `AddOns\ForeverItemTrackerPlus\ForeverItemTrackerPlus.toc`.
3. Restart the game (not just `/reload`) the first time, so the icons load.

Log into each character once, and open the bank and mailbox on it, so its items are recorded.

## Commands

Use `/fitp` or `/itemtracker`.

| Command | What it does |
| --- | --- |
| `/fitp ledger` | Open the ledger (same as the minimap button) |
| `/fitp scan` | Scan the auction house now (it must be open) |
| `/fitp auto` | Turn automatic scanning on or off |
| `/fitp gold` | Print every character's gold to chat |
| `/fitp deposit` | Move every bag item the bank already has into the bank (same as the Deposit button) |
| `/fitp withdraw` | Move every bank item your bags already have into your bags (same as the Withdraw button) |
| `/fitp bags` | List the bag containers being scanned |
| `/fitp forget Name[-Realm]` | Remove a character |

## Notes

- A full auction house scan can freeze the game for a few seconds on busy realms. Right-click the Full Scan button (or type `/fitp auto`) to turn it off and scan by hand instead.
- Prices are stored per realm and faction, so a scan at a neutral auction house replaces your faction's prices.
- Mail sent to an alt is counted once you open that alt's mailbox.

## Releasing

Change the `## Version:` line in `ForeverItemTrackerPlus.toc` (for example to `1.2.0`) and push to `main`. The Release workflow tags that version, builds `ForeverItemTrackerPlus-v1.2.0.zip` and publishes it as a GitHub Release. If the `CF_API_KEY` repository secret is set, it also uploads the zip to [CurseForge](https://www.curseforge.com/) (project ID from `## X-Curse-Project-ID:` in the `.toc`), tagged with the newest WoW Forever game version. A version that's already been released is skipped. You can also run the workflow by hand from the Actions tab.

## License

MIT
