# The Graveyard

**Live at [edonchain.art/tools/the-graveyard](https://edonchain.art/tools/the-graveyard/)** · Tool 01 by Ed OnChain

**Fully on-chain Zombie szn.** Provably fair giveaways of Zombies On Base tokens to holders, on Base.

## v2: two presses (current)

`src/GraveyardRaffleV2.sol`. No snapshot file, no Merkle tree.

1. **Start (owner, one press):** `startGiveaway(prizeTokenId, closesAt)` with ETH for the Chainlink fee. The prize Zombie is pulled into the contract (approve the raffle once with `setApprovalForAll`).
2. **Draw (automatic at the close, or anyone as a backup):** `draw(id)` pays Chainlink VRF v2.5 from the deposit and refunds the unused part to the owner. Chainlink's callback picks a random Zombie (`keccak256(randomWord, attempt) % totalSupply`) and sends the prize to its current holder **in the same transaction**, so nobody can react between the random number and the payout. Zombies held by the owner or by the contract are skipped.

**Automatic draw:** the contract implements Chainlink Automation (`checkUpkeep` / `performUpkeep`). `checkUpkeep` returns the newest closed, undrawn giveaway; `performUpkeep` draws it, paid entirely from its deposit (it never spends anyone else's ETH). Register it as a **Custom Logic** upkeep at automation.chain.link on Base (gas limit 500,000; fund with LINK on Base). `draw(id)` stays available to anyone as a backup.

If no eligible holder is found in the callback's 8 attempts, or the transfer fails, anyone calls `continuePayout(id)`. The owner can cancel before the draw (prize and deposit returned), or 7 days after a draw that Chainlink never answered. Randomness is never re-requested.

## v1: snapshot + Merkle proof (giveaway #0)

`src/GraveyardRaffle.sol`, deployed at `0x5DBf…1bFc`, kept as a read-only record.

- **Prize custody:** the prize Zombie is locked in the `GraveyardRaffle` contract. It can only go to the winner. If the giveaway is cancelled before a draw is requested, it goes back to the owner.
- **Tickets:** one ticket per Zombie held at the snapshot. Wallets with any Zombie listed on OpenSea at snapshot time are excluded, and so is the collection owner wallet.
- **Randomness:** [Chainlink VRF v2.5](https://docs.chain.link/vrf) (direct funding, paid in ETH). Anyone can request the draw and anyone can settle it.
- **Verifiable:** the full ticket list is published next to the site, in `tools/the-graveyard/snapshots/` of the [edonchain.art repo](https://github.com/edonchain-art/edonchain.art), and its Merkle root is committed onchain before the draw. The winning ticket is fixed as soon as Chainlink's number arrives, and the contract pays the holder recorded in the snapshot after checking the Merkle proof.

| | Address (Base) |
|---|---|
| Zombies On Base | `0xa2d33352e3e2b4fe1b8af7387c375828197bcd9b` |
| Chainlink VRF v2.5 wrapper | `0xb0407dbe851f8318bd31404A49e658143C982F23` |
| GraveyardRaffle v1 | [`0x5DBfB702cD34bCaf41f442A8123477556FFc1bFc`](https://basescan.org/address/0x5DBfB702cD34bCaf41f442A8123477556FFc1bFc) (deployed 2026-10-24, owner `0x9C97…5acf`) |
| GraveyardRaffleV2 | [`0x908CE1511e021Fb3Fd4eaE350E57BaD8114724b8`](https://basescan.org/address/0x908CE1511e021Fb3Fd4eaE350E57BaD8114724b8#code) (deployed 2026-10-24, owner `0x9C97…5acf`, verified on Basescan and Sourcify) |

## Repo layout

```
src/GraveyardRaffleV2.sol   raffle v2 (current: onchain draw, prepaid fee)
src/GraveyardRaffle.sol     raffle v1 (giveaway #0)
test/                       unit tests (mock VRF) + Base mainnet fork test
snapshot/                   snapshot builder (holders + OpenSea listings + Merkle tree)
site/                       redirect from the old GitHub Pages URL to edonchain.art
tools/deploy.html           local page to deploy GraveyardRaffleV2 from your wallet
```

## Running a v1 giveaway (historical)

1. **Deploy (once).** Run `forge build`, serve the repo root locally (`python -m http.server 8120`), and open `http://localhost:8120/tools/deploy.html`. Deploy from the owner wallet, then put the address in `tools/the-graveyard/config.js` in the edonchain.art repo and push.
2. **Start.** On the site, connect the owner wallet. In **Admin → Start a giveaway**, enter the prize token ID and close time. This sends the prize into the contract.
3. **Snapshot (after it closes).** Copy `snapshot/.env.example` to `snapshot/.env` and add your OpenSea API key. Then:
   ```bash
   cd snapshot && npm install && node snapshot.mjs --giveaway 0 --raffle <RAFFLE_ADDRESS>
   ```
   This writes `tools/the-graveyard/snapshots/giveaway-0.json` in the edonchain.art repo, which should be cloned next to this one (or set `SITE_DIR`). Commit and push it there so holders can check the list.
4. **Commit.** In **Admin → Commit the snapshot**, load the file and commit. The Merkle root and ticket count go onchain.
5. **Draw.** Anyone presses **Request Chainlink VRF draw**. The fee is a few cents on Base, and any excess is refunded.
6. **Settle.** Once Chainlink answers, anyone presses **Reveal winner & send prize**. Without the site, `node snapshot/proof.mjs <file> <drawnIndex>` prints the `settle()` arguments.

## Test runs on Base Sepolia

`test/TestZombies.sol` is a stand-in collection for live tests with real Chainlink VRF on Base Sepolia
(wrapper `0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed`). Snapshot it with
`node snapshot.mjs --network base-sepolia --collection <TestZombies> --raffle <raffle> --giveaway 0 --listings-file fixtures/testnet-listings.json`,
and view it on the site with `?network=base-sepolia&raffle=<raffle>&zombies=<TestZombies>`. The site shows a "Test mode" banner.

v2 live test (2026-10-24): GraveyardRaffleV2 `0xAEaD984db2efa27DDca6E865779D76D27a83c09a` on Base Sepolia. Two giveaways ran
start → draw with no ETH sent at the draw; Chainlink answered in about 5 seconds and the prize was delivered in the
same callback each time.

v1 live test, after the security fixes (2026-10-23): raffle `0x43f2f0903db60248eA5b6FeD9E82970a347EC192`,
TestZombies `0xEF63D36d348577c9bdf3d5ce13cAf048c19926aC`. Chainlink VRF fulfilled in about 6 seconds, the prize was
settled to the winning snapshot holder, a second draw request was rejected, and a mistakenly sent Zombie was rescued
while rescuing the live prize was refused.

## Security review

An internal review on 2026-10-23 found and fixed: a front-running attack on the old "must still hold" rule (anyone could buy the drawn Zombie and win instead), a prize lock if the ticket count didn't match the list, ownership renouncing, Zombies stuck after a plain `transferFrom`, re-requesting randomness, and unrestricted snapshot links on the site. `test/Audit.t.sol` replays each attack. This was a self-review, not an independent audit.

## Development

```bash
forge test            # unit tests + Base fork test
```

## Website

The site lives in the [edonchain.art repo](https://github.com/edonchain-art/edonchain.art) under `tools/the-graveyard/`, listed as Tool 01 on [edonchain.art/tools](https://edonchain.art/tools/). It is static and reads everything from Base.
