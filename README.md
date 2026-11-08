# Forever Ledger

A minimalist WoW Forever addon that does two things:

1. **Alt inventory on tooltips.** Hover any item to see how many each of your characters has, with an icon for where it is: bags, bank, mail or equipped. Hover your gold (the backpack button, or the coins at the bottom of your bags) to see every character's gold and a total.
2. **Auction house prices on tooltips.** While the auction house is open, Forever Ledger runs a full scan (at most once every 15 minutes, the server's limit). Tradeable items then show the lowest buyout per unit from the last scan and how long ago it ran. The age turns red after 12 hours.

## Install

1. Download the latest `ForeverLedger-*.zip` from [Releases](https://github.com/ashishkhatri/foreverledger/releases).
2. Unzip it into `World of Warcraft\_forever_\Interface\AddOns\`, so you end up with `AddOns\ForeverLedger\ForeverLedger.toc`.
3. Restart the game (not just `/reload`) the first time, so the icons load.

Log into each character once, and open the bank and mailbox on it, so its items are recorded.

## Commands

| Command | What it does |
| --- | --- |
| `/ledger scan` | Scan the auction house now (it must be open) |
| `/ledger auto` | Turn automatic scanning on or off |
| `/ledger gold` | Print every character's gold to chat |
| `/ledger bags` | List the bag containers being scanned |
| `/ledger forget Name[-Realm]` | Remove a character |

## Notes

- A full auction house scan can freeze the game for a few seconds on busy realms. Use `/ledger auto` to turn it off and scan by hand instead.
- Prices are stored per realm and faction, so a scan at a neutral auction house replaces your faction's prices.
- Mail sent to an alt is counted once you open that alt's mailbox.

## Releasing

Change the `## Version:` line in `ForeverLedger.toc` (for example to `1.2.0`) and push to `main`. The release workflow tags that version, builds the zip with [BigWigs packager](https://github.com/BigWigsMods/packager) and attaches it to a GitHub Release. A version that's already been released is skipped. You can also run the workflow by hand from the Actions tab.

To also publish to CurseForge or Wago, add the project ID to `ForeverLedger.toc` (`## X-Curse-Project-ID:` / `## X-Wago-ID:`) and the matching API token as a repository secret (`CF_API_KEY` / `WAGO_API_TOKEN`).

## License

MIT
