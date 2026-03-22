/**
 * upgrade.ts
 *
 * Upgrades a UUPS proxy to a new implementation contract.
 *
 * Usage:
 *   CONTRACT=DAO NEW_IMPL=DAOV2 npm run upgrade:localhost
 *   CONTRACT=EncryptedGovernanceToken npm run upgrade:sepolia
 *
 * Environment variables:
 *   CONTRACT        - Name of the deployed proxy contract (required)
 *   NEW_IMPL        - Name of the new implementation contract (defaults to CONTRACT)
 *   PROXY_ADDRESS   - Override proxy address (defaults to hardhat-deploy artifact)
 */

import { ethers, deployments } from "hardhat";

async function main() {
  const contractName = process.env.CONTRACT;
  if (!contractName) {
    console.error("Set CONTRACT environment variable (e.g. CONTRACT=DAO)");
    process.exit(1);
  }

  const newImplName = process.env.NEW_IMPL || contractName;
  const [deployer] = await ethers.getSigners();
  console.log(`Upgrader:        ${deployer.address}`);
  console.log(`Contract:        ${contractName}`);
  console.log(`New impl:        ${newImplName}`);

  // Resolve proxy address
  let proxyAddress = process.env.PROXY_ADDRESS;
  if (!proxyAddress) {
    const deployment = await deployments.get(contractName);
    proxyAddress = deployment.address;
  }
  console.log(`Proxy address:   ${proxyAddress}`);

  // Deploy new implementation
  const NewImpl = await ethers.getContractFactory(newImplName);
  const newImpl = await NewImpl.deploy();
  await newImpl.waitForDeployment();
  const newImplAddress = await newImpl.getAddress();
  console.log(`New impl address: ${newImplAddress}`);

  // Get proxy contract and read current version
  const proxy = await ethers.getContractAt(contractName, proxyAddress);
  let versionBefore: string | undefined;
  try {
    versionBefore = String(await proxy.version());
    console.log(`Version before:  ${versionBefore}`);
  } catch {
    console.log("Version before:  (no version() function)");
  }

  // Perform upgrade
  console.log("\nUpgrading...");
  const tx = await proxy.upgradeToAndCall(newImplAddress, "0x");
  await tx.wait();
  console.log(`Upgrade tx:      ${tx.hash}`);

  // Verify upgrade
  const upgraded = await ethers.getContractAt(newImplName, proxyAddress);
  try {
    const versionAfter = String(await upgraded.version());
    console.log(`Version after:   ${versionAfter}`);
  } catch {
    console.log("Version after:   (no version() function)");
  }

  console.log("\nUpgrade complete.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
