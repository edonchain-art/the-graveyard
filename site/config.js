// Site configuration. After deploying GraveyardRaffle on Base, put its address in RAFFLE.
// For local testing, override with query params: ?rpc=http://127.0.0.1:8546&raffle=0x...
export const CONFIG = {
  chainId: 8453,
  chainName: "Base",
  rpc: "https://mainnet.base.org",
  explorer: "https://basescan.org",
  RAFFLE: "", // GraveyardRaffle address on Base (set after deployment)
  ZOMBIES: "0xa2d33352e3e2b4fe1b8af7387c375828197bcd9b",
  opensea: "https://opensea.io/item/base/0xa2d33352e3e2b4fe1b8af7387c375828197bcd9b/",
};

const q = new URLSearchParams(location.search);
if (q.get("network") === "base-sepolia") {
  Object.assign(CONFIG, {
    chainId: 84532,
    chainName: "Base Sepolia",
    rpc: "https://sepolia.base.org",
    explorer: "https://sepolia.basescan.org",
    RAFFLE: "",
    ZOMBIES: "",
    testnet: true,
  });
}
if (q.get("zombies")) CONFIG.ZOMBIES = q.get("zombies");
if (q.get("rpc")) CONFIG.rpc = q.get("rpc");
if (q.get("raffle")) CONFIG.RAFFLE = q.get("raffle");
