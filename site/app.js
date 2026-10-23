import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  parseAbi,
  encodeAbiParameters,
  encodeFunctionData,
  decodeFunctionResult,
  formatEther,
  getAddress,
  isAddress,
} from "https://esm.sh/viem@2.21.54";
import { StandardMerkleTree } from "https://esm.sh/@openzeppelin/merkle-tree@1.0.8";
import { CONFIG } from "./config.js";

const STATUS = ["None", "Open", "Committed", "Drawing", "Drawn", "Completed", "Cancelled"];
const S = Object.fromEntries(STATUS.map((s, i) => [s, i]));

const raffleAbi = parseAbi([
  "struct Giveaway { uint256 prizeTokenId; uint64 openedAt; uint64 closesAt; uint64 requestedAt; uint64 completedAt; uint8 status; uint32 entrantCount; bytes32 entrantsRoot; string entrantsURI; uint256 requestId; uint256 randomWord; address winner; uint256 winningTokenId; uint32 winningIndex; }",
  "function owner() view returns (address)",
  "function giveawayCount() view returns (uint256)",
  "function getGiveaway(uint256 id) view returns (Giveaway)",
  "function drawnIndex(uint256 id) view returns (uint32)",
  "function drawPrice() view returns (uint256)",
  "function commitEntrants(uint256 id, bytes32 root, uint32 entrantCount, string entrantsURI)",
  "function requestDraw(uint256 id) payable returns (uint256)",
  "function settle(uint256 id, uint32 index, address holder, uint256 zombieTokenId, bytes32[] proof)",
  "function cancel(uint256 id)",
]);
const zombiesAbi = parseAbi([
  "function tokenURI(uint256) view returns (string)",
  "function balanceOf(address) view returns (uint256)",
  "function safeTransferFrom(address from, address to, uint256 tokenId, bytes data)",
]);

const chain = {
  id: CONFIG.chainId,
  name: CONFIG.chainName,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [CONFIG.rpc] } },
  blockExplorers: { default: { name: "Basescan", url: CONFIG.explorer } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
};
const pub = createPublicClient({ chain, transport: http(CONFIG.rpc) });
const $ = (id) => document.getElementById(id);
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const addrLink = (a) => `<a href="${CONFIG.explorer}/address/${a}" target="_blank" rel="noopener">${short(a)}</a>`;
const txLink = (h) => `<a href="${CONFIG.explorer}/tx/${h}" target="_blank" rel="noopener">${short(h)}</a>`;
const fmtDate = (s) => new Date(Number(s) * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

let account = null;
let wallet = null;
let raffleOwner = null;
let giveaways = [];
const metaCache = new Map();
const snapCache = new Map();

const raffleRead = (functionName, args = []) =>
  pub.readContract({ address: CONFIG.RAFFLE, abi: raffleAbi, functionName, args });

function say(el, msg, cls = "") {
  el.className = "note " + cls;
  el.innerHTML = msg;
}
function errText(e) {
  return esc(e?.shortMessage || e?.details || e?.message || String(e));
}

// ---------------------------------------------------------------- data

async function tokenMeta(tokenId) {
  const key = String(tokenId);
  if (metaCache.has(key)) return metaCache.get(key);
  const p = (async () => {
    try {
      const uri = await pub.readContract({ address: CONFIG.ZOMBIES, abi: zombiesAbi, functionName: "tokenURI", args: [BigInt(tokenId)] });
      const json = uri.startsWith("data:application/json")
        ? JSON.parse(uri.startsWith("data:application/json;base64,") ? atob(uri.split(",")[1]) : decodeURIComponent(uri.split(",")[1]))
        : await fetch(uri).then((r) => r.json());
      return { name: json.name || `Zombie ${tokenId}`, image: json.image || "", onchain: String(json.image || "").startsWith("data:") };
    } catch {
      return { name: `Zombie ${tokenId}`, image: "", onchain: false };
    }
  })();
  metaCache.set(key, p);
  return p;
}

/** Snapshot links must be https or a path on this site (never javascript:, data:, etc). */
function snapshotUrl(uri) {
  let u;
  try {
    u = new URL(uri, location.href);
  } catch {
    return null;
  }
  return u.protocol === "https:" || u.origin === location.origin ? u : null;
}

/** Rebuild the Merkle tree from a snapshot file and check it is internally consistent. */
function checkSnapshot(snap) {
  const tree = StandardMerkleTree.load(snap.tree);
  if (tree.root !== snap.merkleRoot) throw new Error("Snapshot tree does not match its Merkle root.");
  const values = snap.tree.values;
  if (values.length !== Number(snap.entrantCount)) throw new Error(`Snapshot has ${values.length} tickets but says ${snap.entrantCount}.`);
  values.forEach((v, i) => {
    if (Number(v.value[0]) !== i) throw new Error(`Ticket ${i} is out of order.`);
  });
  return tree;
}

async function loadSnapshot(uri) {
  if (!uri) return null;
  if (snapCache.has(uri)) return snapCache.get(uri);
  const url = snapshotUrl(uri);
  if (!url) throw new Error("Snapshot link is not an https URL.");
  const p = fetch(url, { cache: "no-store" }).then((r) => {
    if (!r.ok) throw new Error(`Snapshot not found (${r.status})`);
    return r.json();
  });
  snapCache.set(uri, p);
  return p;
}

async function loadGiveaways() {
  const n = Number(await raffleRead("giveawayCount"));
  const list = await Promise.all(Array.from({ length: n }, (_, i) => raffleRead("getGiveaway", [BigInt(i)])));
  giveaways = list.map((g, id) => ({ ...g, id }));
  return giveaways;
}

// ---------------------------------------------------------------- render

function statusChip(g) {
  const now = Date.now() / 1000;
  if (g.status === S.Open && now < Number(g.closesAt)) return `<span class="chip live">Open</span>`;
  if (g.status === S.Open) return `<span class="chip warn">Closed · snapshot pending</span>`;
  if (g.status === S.Committed) return `<span class="chip warn">Snapshot committed</span>`;
  if (g.status === S.Drawing) return `<span class="chip warn">Waiting for Chainlink VRF</span>`;
  if (g.status === S.Drawn) return `<span class="chip warn">Random number in · ready to settle</span>`;
  if (g.status === S.Completed) return `<span class="chip done">Completed</span>`;
  return `<span class="chip">Cancelled</span>`;
}

function timeline(g) {
  const st = g.status;
  const step = (label, done, now, when = "") =>
    `<li class="${done ? "done" : now ? "now" : ""}">${label}${when ? `<span class="when">${when}</span>` : ""}</li>`;
  const closed = st !== S.Open || Date.now() / 1000 >= Number(g.closesAt);
  return `<ol class="timeline">
    ${step("Prize locked in the raffle contract", true, false, fmtDate(g.openedAt))}
    ${step("Entries close · OpenSea listings checked", closed, !closed, fmtDate(g.closesAt))}
    ${step("Snapshot committed onchain", st >= S.Committed && st !== S.Cancelled, closed && st === S.Open,
      st >= S.Committed && st !== S.Cancelled ? `${g.entrantCount} tickets` : "")}
    ${step("Chainlink VRF random number", st >= S.Drawn && st !== S.Cancelled, st === S.Committed || st === S.Drawing,
      st >= S.Drawing && st !== S.Cancelled ? `Requested ${fmtDate(g.requestedAt)}` : "")}
    ${step("Prize sent to the winner", st === S.Completed, st === S.Drawn, st === S.Completed ? fmtDate(g.completedAt) : "")}
  </ol>`;
}

let countdownTimer = null;
function startCountdown(closesAt) {
  clearInterval(countdownTimer);
  const el = $("countdown");
  if (!el) return;
  const tick = () => {
    const left = Number(closesAt) - Math.floor(Date.now() / 1000);
    if (left <= 0) {
      el.textContent = "Entries closed";
      clearInterval(countdownTimer);
      return;
    }
    const d = Math.floor(left / 86400), h = Math.floor((left % 86400) / 3600), m = Math.floor((left % 3600) / 60), s = left % 60;
    el.textContent = `${d ? d + "d " : ""}${String(h).padStart(2, "0")}h ${String(m).padStart(2, "0")}m ${String(s).padStart(2, "0")}s`;
  };
  tick();
  countdownTimer = setInterval(tick, 1000);
}

async function renderCurrent() {
  const body = $("currentBody");
  if (!CONFIG.RAFFLE) {
    body.innerHTML = `<div class="card"><p class="pixel small">The Graveyard is waking up…</p><p class="muted">The raffle contract hasn't been deployed yet. Check back soon.</p></div>`;
    return;
  }
  const live = [...giveaways].reverse().find((g) => g.status !== S.Cancelled) || giveaways[giveaways.length - 1];
  if (!live) {
    body.innerHTML = `<div class="card"><p class="pixel small">No giveaway yet</p><p class="muted">The first fully onchain Zombie is coming. Hold your Zombies and keep them unlisted.</p></div>`;
    return;
  }
  const meta = await tokenMeta(live.prizeTokenId);
  const snap = live.entrantsURI ? await loadSnapshot(live.entrantsURI).catch(() => null) : null;
  const rootOk = snap && snap.merkleRoot?.toLowerCase() === live.entrantsRoot.toLowerCase();

  let winnerHtml = "";
  if (live.status === S.Completed) {
    winnerHtml = `<div class="winner"><div class="pixel">Winner</div>
      <div>${addrLink(live.winner)} won with Zombie #${live.winningTokenId} (ticket #${live.winningIndex} of ${live.entrantCount}).</div></div>`;
  }
  const canDraw = live.status === S.Committed;
  const canSettle = live.status === S.Drawn;

  body.innerHTML = `
    <div class="prize">
      ${meta.image ? `<img src="${esc(meta.image)}" alt="${esc(meta.name)}">` : `<div class="card">No image</div>`}
      ${meta.onchain ? `<span class="badge">Fully onchain</span>` : ""}
      <div class="prize-name">${esc(meta.name)}</div>
      ${CONFIG.testnet ? "" : `<a class="small" href="${CONFIG.opensea}${live.prizeTokenId}" target="_blank" rel="noopener">View on OpenSea</a>`}
    </div>
    <div>
      <div class="status-head"><h3>Giveaway #${live.id}</h3>${statusChip(live)}</div>
      ${live.status === S.Open ? `<div class="countdown" id="countdown"></div>` : ""}
      ${winnerHtml}
      ${timeline(live)}
      <dl class="kv">
        ${live.status >= S.Committed && live.status !== S.Cancelled ? `
          <dt>Tickets</dt><dd>${live.entrantCount}${snap ? ` from ${snap.stats.eligibleWallets} wallets` : ""}</dd>
          ${snap ? `<dt>Excluded</dt><dd>${snap.excluded.length} wallets (${snap.excluded.filter((e) => e.reasons.includes("listed on OpenSea")).length} with OpenSea listings)</dd>` : ""}
          <dt>Snapshot</dt><dd>${snap ? `block ${snap.snapshot.block} · <a href="${esc(snapshotUrl(live.entrantsURI))}" target="_blank" rel="noopener">full list</a>` : esc(live.entrantsURI)}</dd>
          <dt>Merkle root</dt><dd><code>${live.entrantsRoot}</code> ${snap ? (rootOk ? "✓ matches the published list" : "⚠ does not match the published list") : ""}</dd>` : ""}
        ${live.status >= S.Drawing && live.status !== S.Cancelled ? `<dt>VRF request</dt><dd><code>${String(live.requestId).slice(0, 18)}…</code></dd>` : ""}
        ${live.status >= S.Drawn && live.status !== S.Cancelled ? `<dt>Random word</dt><dd><code>${String(live.randomWord).slice(0, 24)}…</code></dd>` : ""}
      </dl>
      <div class="actions">
        ${canDraw ? `<button class="btn big" id="drawBtn">Request Chainlink VRF draw</button>` : ""}
        ${canSettle ? `<button class="btn big" id="settleBtn">Reveal winner &amp; send prize</button>` : ""}
      </div>
      ${canDraw || canSettle ? `<p class="muted small">Anyone can press this. You pay the gas${canDraw ? " plus the Chainlink fee, a few cents on Base" : ""}.</p>` : ""}
      <div class="note" id="actionOut"></div>
    </div>`;
  if (live.status === S.Open) startCountdown(live.closesAt);
  if (canDraw) $("drawBtn").onclick = () => requestDraw(live);
  if (canSettle) $("settleBtn").onclick = () => settle(live);
}

async function renderLog() {
  const el = $("logBody");
  const done = giveaways.filter((g) => g.status !== S.None).reverse();
  if (!CONFIG.RAFFLE || done.length === 0) {
    el.innerHTML = `<p class="muted">No Zombies have risen from the Graveyard yet.</p>`;
    return;
  }
  const cards = await Promise.all(done.map(async (g) => {
    const meta = await tokenMeta(g.prizeTokenId);
    const result = g.status === S.Completed
      ? `<div class="line"><span>Winner</span><b>${addrLink(g.winner)}</b></div>
         <div class="line"><span>Winning ticket</span><b>Zombie #${g.winningTokenId}</b></div>
         <div class="line"><span>Date</span><b>${new Date(Number(g.completedAt) * 1000).toLocaleDateString()}</b></div>`
      : `<div class="line"><span>Status</span><b>${STATUS[g.status]}</b></div>`;
    return `<div class="grave">
      ${meta.image ? `<img src="${esc(meta.image)}" alt="${esc(meta.name)}" loading="lazy">` : ""}
      <div class="body">
        <div class="title">#${g.id} · ${esc(meta.name)}</div>
        ${result}
        ${g.entrantCount ? `<div class="line"><span>Tickets</span><b>${g.entrantCount}</b></div>` : ""}
      </div></div>`;
  }));
  el.innerHTML = cards.join("");
}

function renderHeroStats() {
  const completed = giveaways.filter((g) => g.status === S.Completed);
  const tickets = completed.reduce((a, g) => a + Number(g.entrantCount), 0);
  $("heroStats").innerHTML = `
    <span class="pill"><b>${completed.length}</b> Zombies given back</span>
    <span class="pill"><b>${tickets}</b> tickets drawn from</span>
    <span class="pill">Randomness: <b>Chainlink VRF v2.5</b></span>`;
  $("contracts").innerHTML = `Raffle contract: ${CONFIG.RAFFLE ? addrLink(CONFIG.RAFFLE) : "not deployed yet"} · Zombies On Base: ${addrLink(CONFIG.ZOMBIES)}`;
}

async function refresh() {
  try {
    if (CONFIG.RAFFLE) {
      await loadGiveaways();
      raffleOwner = await raffleRead("owner");
    }
    renderHeroStats();
    await Promise.all([renderCurrent(), renderLog()]);
    $("admin").hidden = !(account && raffleOwner && account.toLowerCase() === raffleOwner.toLowerCase());
  } catch (e) {
    $("currentBody").innerHTML = `<div class="card"><p class="note err">Could not read from Base: ${errText(e)}</p></div>`;
  }
}

// ---------------------------------------------------------------- wallet

async function connect() {
  if (!window.ethereum) {
    alert("No wallet found. Open this page in a browser with MetaMask or another wallet installed.");
    return;
  }
  [account] = await window.ethereum.request({ method: "eth_requestAccounts" });
  account = getAddress(account);
  const id = await window.ethereum.request({ method: "eth_chainId" });
  if (parseInt(id, 16) !== CONFIG.chainId) {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x" + CONFIG.chainId.toString(16) }] });
  }
  wallet = createWalletClient({ account, chain, transport: custom(window.ethereum) });
  $("connect").textContent = short(account);
  await refresh();
}

async function send(out, request) {
  if (!wallet) await connect();
  if (!wallet) return null;
  say(out, "Simulating…", "warn");
  const { result, request: req } = await pub.simulateContract({ account, ...request });
  say(out, "Confirm in your wallet…", "warn");
  const hash = await wallet.writeContract(req);
  say(out, `Sent ${txLink(hash)} · waiting for confirmation…`, "warn");
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("Transaction reverted");
  return { hash, result };
}

// ---------------------------------------------------------------- actions

async function requestDraw(g) {
  const out = $("actionOut");
  try {
    // The VRF fee depends on the transaction gas price: quote at 2x today's price, overpay, get refunded.
    const gasPrice = (await pub.getGasPrice()) * 2n;
    const raw = await pub.call({ to: CONFIG.RAFFLE, data: encodeFunctionData({ abi: raffleAbi, functionName: "drawPrice" }), gasPrice });
    const quote = decodeFunctionResult({ abi: raffleAbi, functionName: "drawPrice", data: raw.data });
    const value = quote * 2n + 1n;
    const r = await send(out, { address: CONFIG.RAFFLE, abi: raffleAbi, functionName: "requestDraw", args: [BigInt(g.id)], value });
    if (r) say(out, `Draw requested ${txLink(r.hash)} (fee ≈ ${formatEther(quote)} ETH, excess refunded). Chainlink usually answers within a minute or two.`, "ok");
    pollUntilChanged(g.id, g.status);
  } catch (e) {
    say(out, errText(e), "err");
  }
}

async function settle(g) {
  const out = $("actionOut");
  try {
    const snap = await loadSnapshot(g.entrantsURI);
    if (snap.merkleRoot.toLowerCase() !== g.entrantsRoot.toLowerCase()) throw new Error("Published snapshot does not match the committed Merkle root.");
    const tree = checkSnapshot(snap);
    const index = Number(await raffleRead("drawnIndex", [BigInt(g.id)]));
    const [, holder, tokenId] = snap.tree.values[index].value;
    say(out, `Winning ticket #${index}: Zombie #${tokenId} held by ${short(holder)}…`, "warn");
    const r = await send(out, {
      address: CONFIG.RAFFLE, abi: raffleAbi, functionName: "settle",
      args: [BigInt(g.id), index, holder, BigInt(tokenId), tree.getProof(index)],
    });
    if (r) say(out, `🧟 Zombie sent to ${addrLink(holder)} ${txLink(r.hash)}`, "ok");
  } catch (e) {
    say(out, errText(e), "err");
  }
  await refresh();
}

function pollUntilChanged(id, status) {
  let n = 0;
  const t = setInterval(async () => {
    n++;
    const g = await raffleRead("getGiveaway", [BigInt(id)]).catch(() => null);
    if ((g && g.status !== status && g.status !== S.Drawing) || n > 60) {
      clearInterval(t);
      refresh();
    }
  }, 5000);
}

// ---------------------------------------------------------------- eligibility check

$("checkForm").onsubmit = async (ev) => {
  ev.preventDefault();
  const out = $("checkOut");
  const a = $("checkAddr").value.trim();
  if (!isAddress(a)) return say(out, "Enter a valid wallet address.", "err");
  const addr = getAddress(a);
  const latest = [...giveaways].reverse().find((g) => g.entrantsURI);
  try {
    if (latest) {
      const snap = await loadSnapshot(latest.entrantsURI);
      const tickets = snap.tree.values.filter((v) => v.value[1].toLowerCase() === addr.toLowerCase());
      const ex = snap.excluded.find((e) => e.wallet.toLowerCase() === addr.toLowerCase());
      if (tickets.length) return say(out, `✓ In giveaway #${latest.id} with ${tickets.length} ticket${tickets.length > 1 ? "s" : ""}: Zombie ${tickets.map((t) => "#" + t.value[2]).join(", ")}.`, "ok");
      if (ex) return say(out, `Not in giveaway #${latest.id}: ${ex.reasons.join(", ")}${ex.listedTokenIds.length ? ` (listed: #${ex.listedTokenIds.join(", #")})` : ""}.`, "err");
      return say(out, `Not in giveaway #${latest.id}: no Zombies held at the snapshot.`, "err");
    }
    const bal = await pub.readContract({ address: CONFIG.ZOMBIES, abi: zombiesAbi, functionName: "balanceOf", args: [addr] });
    say(out, bal > 0n
      ? `Holds ${bal} Zombie${bal > 1n ? "s" : ""} right now. Keep them unlisted on OpenSea until the snapshot.`
      : "No Zombies in this wallet right now.", bal > 0n ? "ok" : "err");
  } catch (e) {
    say(out, errText(e), "err");
  }
};

// ---------------------------------------------------------------- admin

let pendingSnap = null;
$("aStart").onclick = async () => {
  const out = $("aStartOut");
  try {
    const prize = BigInt($("aPrize").value.trim());
    const closes = Math.floor(new Date($("aCloses").value).getTime() / 1000);
    if (!closes || closes <= Date.now() / 1000) throw new Error("Pick a close time in the future.");
    if (!confirm(`Lock Zombie #${prize} in the raffle contract until ${new Date(closes * 1000).toLocaleString()}?`)) return;
    const data = encodeAbiParameters([{ type: "uint64" }], [BigInt(closes)]);
    const r = await send(out, {
      address: CONFIG.ZOMBIES, abi: zombiesAbi, functionName: "safeTransferFrom",
      args: [account, CONFIG.RAFFLE, prize, data],
    });
    if (r) say(out, `Giveaway started ${txLink(r.hash)}`, "ok");
    await refresh();
  } catch (e) {
    say(out, errText(e), "err");
  }
};

$("aFile").onchange = async () => {
  const info = $("aFileInfo");
  try {
    pendingSnap = null;
    $("aCommit").disabled = true;
    const snap = JSON.parse(await $("aFile").files[0].text());
    checkSnapshot(snap);
    pendingSnap = snap;
    const s = pendingSnap.stats;
    $("aCid").value = pendingSnap.giveawayId;
    if (!$("aUri").value) $("aUri").value = `snapshots/giveaway-${pendingSnap.giveawayId}.json`;
    const raffleOk = pendingSnap.raffle.toLowerCase() === CONFIG.RAFFLE.toLowerCase();
    say(info, `Block ${pendingSnap.snapshot.block} · ${s.tickets} tickets · ${s.eligibleWallets} wallets · ${s.excludedWallets} excluded\nRoot ${pendingSnap.merkleRoot}${raffleOk ? "" : "\n⚠ Snapshot was made for a different raffle address"}`, raffleOk ? "" : "err");
    $("aCommit").disabled = !raffleOk;
  } catch (e) {
    say(info, errText(e), "err");
  }
};

$("aCommit").onclick = async () => {
  const out = $("aCommitOut");
  try {
    const uri = $("aUri").value.trim();
    const url = snapshotUrl(uri);
    if (!url) throw new Error("Use an https URL or a path on this site.");
    // The list must be live before committing: without it nobody can prove the winner and settle.
    const published = await fetch(url, { cache: "no-store" }).then((r) => (r.ok ? r.json() : null)).catch(() => null);
    if (!published) throw new Error(`Publish the snapshot first: nothing found at ${url}`);
    checkSnapshot(published);
    if (published.merkleRoot !== pendingSnap.merkleRoot || published.entrantCount !== pendingSnap.entrantCount) {
      throw new Error("The published file differs from the one you loaded.");
    }
    const r = await send(out, {
      address: CONFIG.RAFFLE, abi: raffleAbi, functionName: "commitEntrants",
      args: [BigInt($("aCid").value), pendingSnap.merkleRoot, pendingSnap.entrantCount, uri],
    });
    if (r) say(out, `Snapshot committed ${txLink(r.hash)}`, "ok");
    await refresh();
  } catch (e) {
    say(out, errText(e), "err");
  }
};

$("aCancel").onclick = async () => {
  const out = $("aCancelOut");
  const id = BigInt($("aXid").value);
  if (!confirm(`Cancel giveaway #${id} and return the prize to your wallet?`)) return;
  try {
    const r = await send(out, { address: CONFIG.RAFFLE, abi: raffleAbi, functionName: "cancel", args: [id] });
    if (r) say(out, `Cancelled ${txLink(r.hash)}`, "ok");
    await refresh();
  } catch (e) {
    say(out, errText(e), "err");
  }
};

// ---------------------------------------------------------------- boot

if (CONFIG.testnet) {
  const bar = document.createElement("div");
  bar.className = "testnet-bar";
  bar.textContent = `Test mode · ${CONFIG.chainName} · not real Zombies`;
  document.body.prepend(bar);
}

$("connect").onclick = () => connect().catch((e) => alert(e.message));
if (window.ethereum) {
  window.ethereum.on?.("accountsChanged", () => location.reload());
  window.ethereum.on?.("chainChanged", () => location.reload());
}
refresh();
setInterval(refresh, 60_000);
