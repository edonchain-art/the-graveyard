// Print the settle() arguments for a ticket index from a published snapshot file.
// Usage: node proof.mjs <snapshot.json> <index>
// Anyone can use this to verify (or settle) a draw without the website.
import { readFileSync } from "node:fs";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

const [file, indexArg] = process.argv.slice(2);
if (!file || indexArg === undefined) {
  console.error("usage: node proof.mjs <snapshot.json> <index>");
  process.exit(1);
}
const snap = JSON.parse(readFileSync(file, "utf8"));
const tree = StandardMerkleTree.load(snap.tree);
if (tree.root !== snap.merkleRoot) throw new Error("tree does not match merkleRoot");
const index = Number(indexArg);
const [i, holder, tokenId] = snap.tree.values[index].value;
if (Number(i) !== index) throw new Error("index mismatch");
console.log(JSON.stringify({ index, holder, tokenId, proof: tree.getProof(index) }));
