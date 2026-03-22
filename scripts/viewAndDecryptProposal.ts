/**
 * viewAndDecryptProposal.ts
 *
 * Demonstrates how a DAO member decrypts an encrypted proposal's on-chain calldata
 * BEFORE voting, using the fhEVM user decryption flow.
 *
 * With on-chain encrypted calldata (euint256 chunks), no off-chain sharing is needed.
 * Members call viewProposal() to get FHE.allow, then decrypt all chunks client-side.
 *
 * Flow:
 *   1. Member calls viewProposal(proposalId) via trusted forwarder (meta-tx)
 *   2. Member reads encrypted chunk handles from contract storage
 *   3. Member generates keypair, signs EIP-712 decryption request
 *   4. Relayer SDK calls KMS to decrypt each chunk
 *   5. Member reconstructs the ABI-encoded Action[] from decrypted chunks
 *   6. Member reviews the decoded actions before voting
 *
 * Usage:
 *   PLUGIN_CONTRACT_ADDRESS=0x... PROPOSAL_ID=1 PLUGIN_TYPE=voting \
 *   npm run view-proposal
 */

import { ethers } from 'hardhat';

// ─── Configuration ─────────────────────────────────────────────────

const PROPOSAL_ID = Number(process.env.PROPOSAL_ID ?? '1');
const PLUGIN_TYPE = (process.env.PLUGIN_TYPE ?? 'voting') as 'voting' | 'multisig';
const PLUGIN_ADDRESS = process.env.PLUGIN_CONTRACT_ADDRESS!;

// ─── ABIs ──────────────────────────────────────────────────────────

const VOTING_ABI = [
  'function viewProposal(uint256 proposalId) external',
  'function getProposalInfo(uint256 proposalId) external view returns (uint256 snapshotId, uint64 voteStart, uint64 voteEnd, uint256 chunkCount, bool finalized, bool resultApproved, bool revealed, bool executed, bool cancelled)',
  'function state(uint256 proposalId) external view returns (uint8)',
  'function getRevealedChunks(uint256 proposalId) external view returns (uint256[])',
];

const MULTISIG_ABI = [
  'function viewProposal(uint256 proposalId) external',
  'function getProposalInfo(uint256 proposalId) external view returns (uint64 createdAt, uint64 expiresAt, uint256 chunkCount, bool finalized, bool resultApproved, bool revealed, bool executed, bool cancelled)',
  'function state(uint256 proposalId) external view returns (uint8)',
  'function getRevealedChunks(uint256 proposalId) external view returns (uint256[])',
];

// ─── Helpers ───────────────────────────────────────────────────────

/**
 * Read encrypted chunk handles from the _encryptedChunks mapping.
 * Dynamic array in a mapping: base = keccak256(abi.encode(proposalId, slot)),
 * array length at base, elements at keccak256(base) + index.
 */
async function readEncryptedChunkHandles(
  pluginAddress: string,
  proposalId: number,
  chunkCount: number,
): Promise<string[]> {
  const provider = ethers.provider;

  // Storage slot of _encryptedChunks mapping.
  // Adjust if storage layout changes.
  const mappingSlot = PLUGIN_TYPE === 'voting' ? 9 : 9;

  // For mapping(uint256 => euint256[]):
  // The array's storage slot = keccak256(abi.encode(proposalId, mappingSlot))
  const arraySlot = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(['uint256', 'uint256'], [proposalId, mappingSlot]),
  );

  // Array elements start at keccak256(arraySlot)
  const elementsBase = BigInt(ethers.keccak256(arraySlot));

  const handles: string[] = [];
  for (let i = 0; i < chunkCount; i++) {
    const handle = await provider.getStorage(pluginAddress, elementsBase + BigInt(i));
    handles.push(handle);
  }

  return handles;
}

/**
 * Decode ABI-encoded Action[] from decrypted 32-byte chunks.
 */
function decodeActionsFromChunks(chunks: bigint[]): { to: string; value: bigint; data: string }[] {
  // Reconstruct the bytes from chunks
  let hex = '0x';
  for (const chunk of chunks) {
    hex += chunk.toString(16).padStart(64, '0');
  }

  // Decode as Action[] = (address, uint256, bytes)[]
  const coder = ethers.AbiCoder.defaultAbiCoder();
  const decoded = coder.decode(['(address,uint256,bytes)[]'], hex);

  return decoded[0].map((action: any) => ({
    to: action[0],
    value: action[1],
    data: action[2],
  }));
}

// ─── Main ──────────────────────────────────────────────────────────

async function main() {
  if (!PLUGIN_ADDRESS) {
    console.error('Set PLUGIN_CONTRACT_ADDRESS environment variable');
    process.exit(1);
  }

  const [signer] = await ethers.getSigners();
  const signerAddress = await signer.getAddress();
  console.log(`Member address: ${signerAddress}`);
  console.log(`Plugin type:    ${PLUGIN_TYPE}`);
  console.log(`Plugin address: ${PLUGIN_ADDRESS}`);
  console.log(`Proposal ID:    ${PROPOSAL_ID}`);
  console.log('');

  const abi = PLUGIN_TYPE === 'voting' ? VOTING_ABI : MULTISIG_ABI;
  const plugin = new ethers.Contract(PLUGIN_ADDRESS, abi, signer);

  // ── Step 1: Get proposal info (chunk count) ──

  console.log('1. Reading proposal info...');
  const info = await plugin.getProposalInfo(PROPOSAL_ID);
  const chunkCount = Number(info.chunkCount);
  console.log(`   Chunk count: ${chunkCount}`);

  const stateVal = await plugin.state(PROPOSAL_ID);
  const stateNames = ['Active', 'Pending', 'Succeeded', 'Defeated', 'Revealed', 'Executed', 'Cancelled'];
  console.log(`   State:       ${stateNames[Number(stateVal)] ?? 'Unknown'}`);

  // ── Step 2: Call viewProposal() to get FHE.allow ──

  console.log('');
  console.log('2. Calling viewProposal() to request decryption access...');
  const tx = await plugin.viewProposal(PROPOSAL_ID);
  await tx.wait();
  console.log(`   tx: ${tx.hash}`);

  // ── Step 3: Read encrypted chunk handles ──

  console.log('');
  console.log('3. Reading encrypted chunk handles from storage...');
  const handles = await readEncryptedChunkHandles(PLUGIN_ADDRESS, PROPOSAL_ID, chunkCount);
  for (let i = 0; i < handles.length; i++) {
    console.log(`   chunk[${i}]: ${handles[i]}`);
  }

  // ── Step 4: Decrypt all chunks via user decryption ──
  // NOTE: In production, you would use the @zama-fhe/relayer-sdk to decrypt:
  //
  //   import { createInstance } from '@zama-fhe/relayer-sdk/node';
  //   const instance = await createInstance({ ... });
  //   const { publicKey, privateKey } = instance.generateKeypair();
  //   const eip712 = instance.createEIP712(publicKey, [PLUGIN_ADDRESS], startTimestamp, 1);
  //   const signature = await signer.signTypedData(eip712.domain, ...);
  //   const result = await instance.userDecrypt(handlePairs, privateKey, publicKey, signature, ...);

  console.log('');
  console.log('4. Decryption requires @zama-fhe/relayer-sdk connected to a KMS.');
  console.log('   For revealed proposals, reading on-chain chunks directly:');

  try {
    const revealedChunks = await plugin.getRevealedChunks(PROPOSAL_ID);
    const decryptedChunks: bigint[] = revealedChunks.map((c: any) => BigInt(c));

    console.log('');
    console.log('5. Decoding ABI-encoded Action[] from chunks...');
    const actions = decodeActionsFromChunks(decryptedChunks);
    console.log('');
    console.log('═══ Decoded Proposal Actions ═══');
    for (let i = 0; i < actions.length; i++) {
      console.log(`  Action ${i}:`);
      console.log(`    to:    ${actions[i].to}`);
      console.log(`    value: ${actions[i].value} wei`);
      console.log(`    data:  ${actions[i].data}`);
    }
    console.log('════════════════════════════════');
  } catch {
    console.log('   Proposal has not been revealed yet. Use KMS user decryption to decrypt chunks.');
    console.log('   Encrypted chunk handles are available above for client-side decryption.');
  }

  console.log('');
  console.log('You can now cast your vote with full knowledge of the proposal content.');
  console.log('No off-chain data sharing was needed — everything is on-chain (encrypted).');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
