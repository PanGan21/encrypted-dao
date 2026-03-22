import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  const trustedForwarder = process.env.TRUSTED_FORWARDER || hre.ethers.ZeroAddress;

  // ── 1. Deploy DAO ──────────────────────────────────────────────────

  const deployedDAO = await deploy("DAO", {
    from: deployer,
    args: [deployer, trustedForwarder],
    log: true,
  });
  console.log(`DAO contract: `, deployedDAO.address);

  // ── 2. Deploy Governance Token ─────────────────────────────────────

  const deployedToken = await deploy("EncryptedGovernanceToken", {
    from: deployer,
    args: ["Encrypted Gov Token", "eGOV", trustedForwarder],
    log: true,
  });
  console.log(`EncryptedGovernanceToken contract: `, deployedToken.address);

  // ── 3. Deploy Token Voting Plugin ──────────────────────────────────

  const votingDuration = 7 * 24 * 60 * 60; // 7 days
  const quorumPct = 20;
  const supportPct = 50;
  const minProposerBalance = 100;

  const deployedVoting = await deploy("EncryptedTokenVoting", {
    from: deployer,
    args: [
      deployedDAO.address,
      deployedToken.address,
      votingDuration,
      quorumPct,
      supportPct,
      minProposerBalance,
      trustedForwarder,
    ],
    log: true,
  });
  console.log(`EncryptedTokenVoting contract: `, deployedVoting.address);

  // ── 4. Post-deployment setup ───────────────────────────────────────

  const tokenContract = await hre.ethers.getContractAt(
    "EncryptedGovernanceToken",
    deployedToken.address,
  );
  const daoContract = await hre.ethers.getContractAt("DAO", deployedDAO.address);

  // Authorize voting plugin to create snapshots
  let tx = await tokenContract.setSnapshotCreator(deployedVoting.address, true);
  await tx.wait();
  console.log("Voting plugin authorized as snapshot creator");

  // Grant EXECUTE_PERMISSION to voting plugin
  const EXECUTE_PERMISSION_ID = await daoContract.EXECUTE_PERMISSION_ID();
  tx = await daoContract.grant(deployedDAO.address, deployedVoting.address, EXECUTE_PERMISSION_ID);
  await tx.wait();
  console.log("EXECUTE_PERMISSION granted to voting plugin");

  // ── 5. (Optional) Deploy Multisig ──────────────────────────────────

  if (process.env.DEPLOY_MULTISIG === "true") {
    const signers = process.env.MULTISIG_SIGNERS?.split(",") || [deployer];
    const threshold = Number(process.env.MULTISIG_THRESHOLD || "2");
    const duration = 30 * 24 * 60 * 60; // 30 days

    const deployedMultisig = await deploy("EncryptedMultisig", {
      from: deployer,
      args: [deployedDAO.address, signers, threshold, duration, trustedForwarder],
      log: true,
    });
    console.log(`EncryptedMultisig contract: `, deployedMultisig.address);

    tx = await daoContract.grant(
      deployedDAO.address,
      deployedMultisig.address,
      EXECUTE_PERMISSION_ID,
    );
    await tx.wait();
    console.log("EXECUTE_PERMISSION granted to multisig plugin");
  }

  console.log("");
  console.log("═══ Encrypted DAO Deployment Complete ═══");
  console.log(`  DAO:              ${deployedDAO.address}`);
  console.log(`  Governance Token: ${deployedToken.address}`);
  console.log(`  Token Voting:     ${deployedVoting.address}`);
  console.log(`  Trusted Forwarder: ${trustedForwarder}`);
  console.log("═════════════════════════════════════════");
};

export default func;
func.id = "deploy_encrypted_dao";
func.tags = ["EncryptedDAO"];
