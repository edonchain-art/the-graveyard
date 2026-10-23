# The Graveyard

**Fully on-chain Zombie szn.** Provably fair giveaways of Zombies On Base tokens to holders, on Base.

- **Prize custody:** the prize Zombie is locked in the `GraveyardRaffle` contract. It can only go to the winner. If the giveaway is cancelled before a draw is requested, it goes back to the owner.
- **Tickets:** one ticket per Zombie held at the snapshot. Wallets with any Zombie listed on OpenSea at snapshot time are excluded, and so is the collection owner wallet.
- **Randomness:** [Chainlink VRF v2.5](https://docs.chain.link/vrf) (direct funding, paid in ETH). Anyone can request the draw and anyone can settle it.
- **Verifiable:** the full ticket list is published in `site/snapshots/`, and its Merkle root is committed onchain before the draw. The contract checks the winner's Merkle proof and that they still hold the ticket Zombie before paying.

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

## Development

```bash
forge test            # unit tests + Base fork test
```

## Custom domain

In GitHub, go to **Settings → Pages**: set the source to **GitHub Actions**, then add your domain under **Custom domain**. At your DNS provider, add a `CNAME` record pointing to `<github-user>.github.io` (or the apex `A` records GitHub lists).
