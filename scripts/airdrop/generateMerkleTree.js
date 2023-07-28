const { MerkleTree } = require('merkletreejs');
const { ethers } = require('hardhat');
const fs = require('node:fs');
const path = require('node:path');
require('dotenv').config({ path: '../../.env' });

const airdropFile = path.resolve(__dirname, 'allocations.csv'); // {address},{amount}
const outputDirectory = path.resolve(__dirname, 'output');

if (!fs.existsSync(airdropFile)) throw new Error(`Cannot find airdrop file at ${airdropFile}`);

// Clear output proofs
if (fs.existsSync(outputDirectory)) fs.rmSync(outputDirectory, {recursive: true});
fs.mkdirSync(outputDirectory);

const lines = fs.readFileSync(airdropFile, 'utf-8').split('\n');
if (lines.length === 0) throw new Error(`No airdrop entries found in the csv`);

const leaves = lines
  .filter(line => line.trim().length > 0)
  .map(line => {
    const csvEntries = line.trim().split(',');
    if (csvEntries.length !== 2) throw new Error(`Improper data structure found in csv`);
    const address = csvEntries[0];
    const amount = csvEntries[1];
    if (!ethers.utils.isAddress(address)) {
      throw new Error(`Invalid address ${address}`);
    }
    return {address, amount};
  })
  .map(({address, amount}) => ethers.utils.solidityPack(['address', 'uint96'], [address, amount]));

const tree = new MerkleTree(leaves, ethers.utils.keccak256, { sort: true });
const root = tree.getHexRoot();

console.log(`Writing ${leaves.length} proofs ...`);

let n = 0;
for (const leaf of leaves) {
  console.log(`${leaf} (${++n}/${leaves.length})`);

  const address = ethers.utils.hexDataSlice(leaf, 0, 20);
  const amount = ethers.BigNumber.from(ethers.utils.hexDataSlice(leaf, 20)).toString();

  const proof = tree.getHexProof(leaf);
  const obj = {
    address: address,
    amount: amount,
    proof: proof,
    root: root,
  };
  const outputFile = path.resolve(outputDirectory, `${address.toLowerCase()}.json`);
  fs.writeFileSync(outputFile, JSON.stringify(obj) , 'utf-8');
}

console.log();
console.log(`Merkle Root: ${root}`);
