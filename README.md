# The Graveyard

**Fully on-chain Zombie szn.** Provably fair giveaways of Zombies On Base tokens to holders, on Base.

- **Prize custody:** the prize Zombie is locked in the `GraveyardRaffle` contract. It can only go to the winner. If the giveaway is cancelled before a draw is requested, it goes back to the owner.
- **Tickets:** one ticket per Zombie held at the snapshot. Wallets with any Zombie listed on OpenSea at snapshot time are excluded, and so is the collection owner wallet.
- **Randomness:** [Chainlink VRF v2.5](https://docs.chain.link/vrf) (direct funding, paid in ETH). Anyone can request the draw and anyone can settle it.
- **Verifiable:** the full ticket list is published in `site/snapshots/`, and its Merkle root is committed onchain before the draw. The winning ticket is fixed as soon as Chainlink's number arrives, and the contract pays the holder recorded in the snapshot after checking the Merkle proof.

| | Address (Base) |
|---|---|
| Zombies On Base | `0xa2d33352e3e2b4fe1b8af7387c375828197bcd9b` |
| Chainlink VRF v2.5 wrapper | `0xb0407dbe851f8318bd31404A49e658143C982F23` |
| GraveyardRaffle | _set in `site/config.js` after deployment_ |

## Repo layout

```
src/GraveyardRaffle.sol     raffle contract
test/                       unit tests (mock VRF) + Base mainnet fork test
snapshot/                   snapshot builder (holders + OpenSea listings + Merkle tree)
site/                       The Graveyard website (static, deployed by GitHub Pages)
tools/deploy.html           local page to deploy the raffle from your wallet
```

## Running a giveaway

1. **Deploy (once).** Run `forge build`, serve the repo root locally (`python -m http.server 8120`), and open `http://localhost:8120/tools/deploy.html`. Deploy from the owner wallet, then put the address in `site/config.js` and push.
2. **Start.** On the site, connect the owner wallet. In **Admin → Start a giveaway**, enter the prize token ID and close time. This sends the prize into the contract.
3. **Snapshot (after it closes).** Copy `snapshot/.env.example` to `snapshot/.env` and add your OpenSea API key. Then:
   ```bash
   cd snapshot && npm install && node snapshot.mjs --giveaway 0 --raffle <RAFFLE_ADDRESS>
   ```
   This writes `site/snapshots/giveaway-0.json`. Commit and push it so holders can check the list.
4. **Commit.** In **Admin → Commit the snapshot**, load the file and commit. The Merkle root and ticket count go onchain.
5. **Draw.** Anyone presses **Request Chainlink VRF draw**. The fee is a few cents on Base, and any excess is refunded.
6. **Settle.** Once Chainlink answers, anyone presses **Reveal winner & send prize**. Without the site, `node snapshot/proof.mjs <file> <drawnIndex>` prints the `settle()` arguments.

## Test runs on Base Sepolia

`test/TestZombies.sol` is a stand-in collection for live tests with real Chainlink VRF on Base Sepolia
(wrapper `0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed`). Snapshot it with
`node snapshot.mjs --network base-sepolia --collection <TestZombies> --raffle <raffle> --giveaway 0 --listings-file fixtures/testnet-listings.json`,
and view it on the site with `?network=base-sepolia&raffle=<raffle>&zombies=<TestZombies>`. The site shows a "Test mode" banner.

Latest live test, after the security fixes (2026-10-23): raffle `0x43f2f0903db60248eA5b6FeD9E82970a347EC192`,
TestZombies `0xEF63D36d348577c9bdf3d5ce13cAf048c19926aC`. Chainlink VRF fulfilled in about 6 seconds, the prize was
settled to the winning snapshot holder, a second draw request was rejected, and a mistakenly sent Zombie was rescued
while rescuing the live prize was refused.

## Security review

An internal review on 2026-10-23 found and fixed: a front-running attack on the old "must still hold" rule (anyone could buy the drawn Zombie and win instead), a prize lock if the ticket count didn't match the list, ownership renouncing, Zombies stuck after a plain `transferFrom`, re-requesting randomness, and unrestricted snapshot links on the site. `test/Audit.t.sol` replays each attack. This was a self-review, not an independent audit.

## Development

```bash
forge test            # unit tests + Base fork test
```

## Custom domain

In GitHub, go to **Settings → Pages**: set the source to **GitHub Actions**, then add your domain under **Custom domain**. At your DNS provider, add a `CNAME` record pointing to `<github-user>.github.io` (or the apex `A` records GitHub lists).
