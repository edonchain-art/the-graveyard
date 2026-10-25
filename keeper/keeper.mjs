// The Graveyard keeper: draws closed giveaways on GraveyardRaffleV2 and finishes stuck payouts.
//
// It only calls the raffle's public functions (performUpkeep, continuePayout), which anyone may
// call. The Chainlink fee comes from each giveaway's deposit, so the keeper wallet only pays gas.
//
// Env:
//   RAFFLE              raffle address (default: mainnet GraveyardRaffleV2)
//   RPC_URL             JSON-RPC endpoint (default: https://mainnet.base.org)
//   CHAIN               "base" (default) or "base-sepolia"
//   KEEPER_PRIVATE_KEY  gas-only wallet key; without it the keeper only reports (dry run)
import { createPublicClient, createWalletClient, http, parseAbi, formatEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base, baseSepolia } from "viem/chains";

const chain = process.env.CHAIN === "base-sepolia" ? baseSepolia : base;
const RAFFLE = process.env.RAFFLE || "0x908CE1511e021Fb3Fd4eaE350E57BaD8114724b8";
const rpc = process.env.RPC_URL || chain.rpcUrls.default.http[0];

const abi = parseAbi([
  "struct Giveaway { uint256 prizeTokenId; uint64 openedAt; uint64 closesAt; uint64 requestedAt; uint64 completedAt; uint8 status; uint32 ticketCount; uint32 attempts; uint256 feeDeposit; uint256 feePaid; uint256 requestId; uint256 randomWord; address winner; uint256 winningTokenId; }",
  "function checkUpkeep(bytes) view returns (bool upkeepNeeded, bytes performData)",
  "function performUpkeep(bytes performData)",
  "function continuePayout(uint256 id)",
  "function giveawayCount() view returns (uint256)",
  "function getGiveaway(uint256 id) view returns (Giveaway)",
]);
const DRAWN = 3; // GraveyardRaffleV2.Status.Drawn

const pub = createPublicClient({ chain, transport: http(rpc) });
const key = process.env.KEEPER_PRIVATE_KEY;
const account = key ? privateKeyToAccount(key.startsWith("0x") ? key : `0x${key}`) : null;
const wallet = account ? createWalletClient({ account, chain, transport: http(rpc) }) : null;

const log = (...a) => console.log(new Date().toISOString(), ...a);

async function send(functionName, args, label) {
  if (!wallet) {
    log(`[dry run] would call ${label}`);
    return;
  }
  // Simulate first: if it would revert (e.g. already drawn, deposit too small), nothing is sent.
  const { request } = await pub.simulateContract({ account, address: RAFFLE, abi, functionName, args });
  const hash = await wallet.writeContract(request);
  log(`${label}: sent ${hash}`);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  log(`${label}: ${receipt.status} in block ${receipt.blockNumber}, gas ${receipt.gasUsed}`);
  if (receipt.status !== "success") process.exitCode = 1;
}

async function main() {
  log(`raffle ${RAFFLE} on ${chain.name}${account ? ` · keeper ${account.address}` : " · dry run (no key)"}`);
  if (account) {
    const bal = await pub.getBalance({ address: account.address });
    log(`keeper balance ${formatEther(bal)} ETH`);
    if (bal < 20_000_000_000_000n) log("WARNING: keeper balance is low (< 0.00002 ETH). Top it up.");
  }

  // 1. Draw every closed giveaway (one per performUpkeep).
  for (let i = 0; i < 10; i++) {
    const [needed, performData] = await pub.readContract({ address: RAFFLE, abi, functionName: "checkUpkeep", args: ["0x"] });
    if (!needed) break;
    await send("performUpkeep", [performData], `draw giveaway ${BigInt(performData)}`);
    if (!wallet) break;
  }

  // 2. Finish any payout the Chainlink callback couldn't complete (rare).
  const n = Number(await pub.readContract({ address: RAFFLE, abi, functionName: "giveawayCount" }));
  for (let id = Math.max(0, n - 50); id < n; id++) {
    const g = await pub.readContract({ address: RAFFLE, abi, functionName: "getGiveaway", args: [BigInt(id)] });
    if (g.status === DRAWN) await send("continuePayout", [BigInt(id)], `finish payout ${id}`);
  }
  log("done");
}

main().catch((e) => {
  console.error(e.shortMessage || e.message || e);
  process.exit(1);
});
