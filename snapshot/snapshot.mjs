// The Graveyard: build the eligible ticket list for a giveaway.
//
// Rules (also written into the output file):
//   - One ticket per Zombies On Base token held at the snapshot block.
//   - A wallet with ANY Zombie actively listed on OpenSea at snapshot time is excluded entirely.
//   - The collection owner wallet and the raffle contract are excluded.
//
// Usage:
//   node snapshot.mjs --giveaway 0 --raffle 0xRaffle [--block 123] [--exclude 0xA,0xB]
//                     [--listings-file listings.json] [--out ../site/snapshots/giveaway-0.json]
//   Test runs on Base Sepolia: add --network base-sepolia --collection 0xTestZombies --listings-file f
//
// Output: a JSON file with the snapshot details, exclusions, Merkle root and the full
// OpenZeppelin StandardMerkleTree dump (anyone can rebuild the root from it).

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, getAddress, parseAbi, zeroAddress } from "viem";
import { base, baseSepolia } from "viem/chains";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

let ZOMBIES = getAddress("0xa2d33352e3e2b4fe1b8af7387c375828197bcd9b");
const OPENSEA = "https://api.opensea.io/api/v2";
const here = dirname(fileURLToPath(import.meta.url));

const zombiesAbi = parseAbi([
  "function owner() view returns (address)",
  "function totalSupply() view returns (uint256)",
  "function tokenByIndex(uint256) view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
]);

function loadEnv() {
  const file = join(here, ".env");
  if (!existsSync(file)) return;
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2];
  }
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith("--")) continue;
    const key = argv[i].slice(2);
    const val = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : "true";
    out[key] = val;
  }
  return out;
}

async function multicallAll(client, contracts, blockNumber, label) {
  const results = [];
  const size = 250;
  for (let i = 0; i < contracts.length; i += size) {
    const chunk = contracts.slice(i, i + size);
    const res = await client.multicall({ contracts: chunk, blockNumber, allowFailure: false });
    results.push(...res);
    process.stderr.write(`\r${label}: ${Math.min(i + size, contracts.length)}/${contracts.length}`);
  }
  process.stderr.write("\n");
  return results;
}

async function openseaListings(apiKey) {
  const headers = { "X-API-KEY": apiKey, accept: "application/json" };
  const contract = await fetch(`${OPENSEA}/chain/base/contract/${ZOMBIES}`, { headers }).then((r) => {
    if (!r.ok) throw new Error(`OpenSea contract lookup failed: HTTP ${r.status}`);
    return r.json();
  });
  const slug = contract.collection;
  const listings = [];
  let next = "";
  do {
    const url = `${OPENSEA}/listings/collection/${slug}/all?limit=100${next ? `&next=${encodeURIComponent(next)}` : ""}`;
    const r = await fetch(url, { headers });
    if (r.status === 429) {
      await new Promise((res) => setTimeout(res, 2000));
      continue;
    }
    if (!r.ok) throw new Error(`OpenSea listings failed: HTTP ${r.status} ${await r.text()}`);
    const page = await r.json();
    listings.push(...page.listings);
    next = page.next || "";
  } while (next);
  return { slug, listings };
}

/** Reduce raw OpenSea listings to [{ offerer, tokenId, orderHash }] for Zombies only. */
function zombieListings(listings) {
  const out = [];
  for (const l of listings) {
    if (l.status && l.status !== "ACTIVE") continue;
    const p = l.protocol_data?.parameters;
    if (!p) continue;
    for (const item of p.offer || []) {
      if (item.token?.toLowerCase() !== ZOMBIES.toLowerCase()) continue;
      out.push({ offerer: getAddress(p.offerer), tokenId: BigInt(item.identifierOrCriteria), orderHash: l.order_hash });
    }
  }
  return out;
}

async function main() {
  loadEnv();
  const args = parseArgs(process.argv.slice(2));
  if (args.giveaway === undefined || !args.raffle) {
    console.error("usage: node snapshot.mjs --giveaway <id> --raffle <address> [--block N] [--exclude a,b] [--listings-file f] [--out f]");
    process.exit(1);
  }
  const giveawayId = Number(args.giveaway);
  const raffle = getAddress(args.raffle);
  const testnet = args.network === "base-sepolia";
  const chain = testnet ? baseSepolia : base;
  if (args.collection) ZOMBIES = getAddress(args.collection);
  if (testnet && !args["listings-file"]) throw new Error("--network base-sepolia needs --listings-file (OpenSea has no testnet listings API here)");
  const rpc = testnet ? process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org" : process.env.BASE_RPC_URL || "https://mainnet.base.org";
  const client = createPublicClient({ chain, transport: http(rpc) });

  const blockNumber = args.block ? BigInt(args.block) : await client.getBlockNumber();
  const block = await client.getBlock({ blockNumber });
  console.error(`Snapshot block ${blockNumber} (${new Date(Number(block.timestamp) * 1000).toISOString()})`);

  // 1. Every Zombie and its holder at the snapshot block
  const read = (functionName, args) => ({ address: ZOMBIES, abi: zombiesAbi, functionName, args });
  const collectionOwner = await client.readContract({ ...read("owner"), blockNumber });
  const supply = await client.readContract({ ...read("totalSupply"), blockNumber });
  const tokenIds = await multicallAll(
    client,
    Array.from({ length: Number(supply) }, (_, i) => read("tokenByIndex", [BigInt(i)])),
    blockNumber,
    "tokenByIndex",
  );
  const owners = await multicallAll(client, tokenIds.map((id) => read("ownerOf", [id])), blockNumber, "ownerOf");
  const holdings = new Map(); // wallet -> tokenIds[]
  tokenIds.forEach((id, i) => {
    const w = getAddress(owners[i]);
    if (!holdings.has(w)) holdings.set(w, []);
    holdings.get(w).push(id);
  });

  // 2. Active OpenSea listings
  let slug = "zombies-on-base";
  let raw;
  if (args["listings-file"]) {
    raw = JSON.parse(readFileSync(args["listings-file"], "utf8"));
    console.error(`Using listings from ${args["listings-file"]} (test mode)`);
  } else {
    if (!process.env.OPENSEA_API_KEY) throw new Error("OPENSEA_API_KEY missing (snapshot/.env)");
    ({ slug, listings: raw } = await openseaListings(process.env.OPENSEA_API_KEY));
  }
  const listed = zombieListings(raw);
  const listedAt = new Date().toISOString();

  // 3. Exclusions
  const excluded = new Map(); // wallet -> { reasons, listedTokenIds }
  const exclude = (w, reason, tokenId) => {
    const key = getAddress(w);
    if (!excluded.has(key)) excluded.set(key, { reasons: new Set(), listedTokenIds: [] });
    excluded.get(key).reasons.add(reason);
    if (tokenId !== undefined) excluded.get(key).listedTokenIds.push(tokenId);
  };
  exclude(collectionOwner, "collection owner");
  exclude(raffle, "raffle contract");
  exclude(zeroAddress, "zero address");
  for (const w of (args.exclude || "").split(",").filter(Boolean)) exclude(w, "manual exclusion");
  let staleListings = 0;
  for (const { offerer, tokenId } of listed) {
    // Only count a listing if the offerer actually holds that Zombie at the snapshot.
    if ((holdings.get(offerer) || []).some((id) => id === tokenId)) exclude(offerer, "listed on OpenSea", tokenId);
    else staleListings++;
  }

  // 4. Tickets: one per Zombie held by an eligible wallet, ordered by token id
  const tickets = [];
  tokenIds.forEach((id, i) => {
    const w = getAddress(owners[i]);
    if (!excluded.has(w)) tickets.push({ holder: w, tokenId: id });
  });
  tickets.sort((a, b) => (a.tokenId < b.tokenId ? -1 : 1));
  const values = tickets.map((t, i) => [String(i), t.holder, String(t.tokenId)]);
  if (values.length === 0) throw new Error("No eligible tickets");
  const tree = StandardMerkleTree.of(values, ["uint256", "address", "uint256"]);

  const excludedList = [...excluded.entries()]
    .filter(([w]) => w !== zeroAddress)
    .map(([wallet, e]) => ({
      wallet,
      reasons: [...e.reasons],
      listedTokenIds: [...new Set(e.listedTokenIds.map(String))],
      heldTokenIds: (holdings.get(wallet) || []).map(String),
    }))
    .sort((a, b) => b.heldTokenIds.length - a.heldTokenIds.length);

  const out = {
    project: "The Graveyard",
    giveawayId,
    chainId: chain.id,
    raffle,
    collection: { address: ZOMBIES, openseaSlug: slug },
    rules: [
      "One ticket per Zombies On Base token held at the snapshot block.",
      "Wallets with any Zombie actively listed on OpenSea at snapshot time are excluded.",
      "The collection owner wallet and the raffle contract are excluded.",
      "Chainlink VRF picks ticket index = keccak256(abi.encode(randomWord, rerolls)) % entrantCount.",
      "If the drawn holder no longer owns that Zombie when the prize is settled, the ticket is void and the next index is drawn.",
    ],
    snapshot: {
      block: String(blockNumber),
      timestamp: Number(block.timestamp),
      openseaListingsFetchedAt: listedAt,
    },
    stats: {
      zombies: tokenIds.length,
      holders: holdings.size,
      activeZombieListings: listed.length,
      staleListingsIgnored: staleListings,
      excludedWallets: excludedList.length,
      eligibleWallets: new Set(tickets.map((t) => t.holder)).size,
      tickets: values.length,
    },
    merkleRoot: tree.root,
    entrantCount: values.length,
    excluded: excludedList,
    tree: tree.dump(),
  };

  const outFile = args.out || join(here, "..", "site", "snapshots", `giveaway-${giveawayId}.json`);
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, JSON.stringify(out, null, 1));
  console.log(JSON.stringify({ outFile, merkleRoot: tree.root, entrantCount: values.length, stats: out.stats }, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
