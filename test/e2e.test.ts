import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import type {
  DAOUpgradeable,
  DAOUpgradeableV2,
  EncryptedGovernanceTokenUpgradeable,
  EncryptedTokenVoting,
} from "../types";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * E2E tests for the Encrypted DAO running against a local Hardhat chain
 * with FHE mock mode. Covers:
 *
 * 1. Proxy deployment (UUPS) of DAO and Token
 * 2. Token minting and delegation
 * 3. Proposal creation, voting, finalization, reveal, and execution
 * 4. DAO upgrade through governance (V1 → V2)
 * 5. Plugin rotation (swap voting plugin via permissions)
 */
describe("E2E: Encrypted DAO (local chain)", function () {
  // Increase timeout for FHE mock operations
  this.timeout(120_000);

  let dao: DAOUpgradeable;
  let token: EncryptedGovernanceTokenUpgradeable;
  let voting: EncryptedTokenVoting;
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let carol: HardhatEthersSigner;

  let daoProxy: string;
  let tokenProxy: string;

  const VOTING_DURATION = 60; // 60 seconds for testing
  const QUORUM_PCT = 20;
  const SUPPORT_PCT = 50;
  const MIN_PROPOSER_BALANCE = 100;

  before(async function () {
    if (!fhevm.isMock) {
      console.log("Skipping E2E tests — requires FHE mock mode (local Hardhat)");
      this.skip();
    }
    [owner, alice, bob, carol] = await ethers.getSigners();
  });

  // ═══════════════════════════════════════════════════════════════════
  // 1. PROXY DEPLOYMENT
  // ═══════════════════════════════════════════════════════════════════

  describe("1. Proxy Deployment", function () {
    it("should deploy DAO via ERC1967 proxy", async function () {
      // Deploy implementation
      const DAOImpl = await ethers.getContractFactory("DAOUpgradeable");
      const daoImpl = await DAOImpl.deploy();
      await daoImpl.waitForDeployment();

      // Deploy proxy
      const ERC1967Proxy = await ethers.getContractFactory("ERC1967Proxy", {
        libraries: {},
      });
      const initData = DAOImpl.interface.encodeFunctionData("initialize", [
        owner.address,
        ethers.ZeroAddress,
      ]);
      const proxy = await ERC1967Proxy.deploy(await daoImpl.getAddress(), initData);
      await proxy.waitForDeployment();

      daoProxy = await proxy.getAddress();
      dao = DAOImpl.attach(daoProxy) as unknown as DAOUpgradeable;

      // Verify initialization
      const ROOT_PERMISSION_ID = await dao.ROOT_PERMISSION_ID();
      expect(await dao.hasPermission(daoProxy, owner.address, ROOT_PERMISSION_ID)).to.be.true;
      expect(await dao.version()).to.equal(1);
    });

    it("should deploy GovernanceToken via ERC1967 proxy", async function () {
      const TokenImpl = await ethers.getContractFactory("EncryptedGovernanceTokenUpgradeable");
      const tokenImpl = await TokenImpl.deploy();
      await tokenImpl.waitForDeployment();

      const ERC1967Proxy = await ethers.getContractFactory("ERC1967Proxy", {
        libraries: {},
      });
      const initData = TokenImpl.interface.encodeFunctionData("initialize", [
        "Encrypted Gov Token",
        "eGOV",
        ethers.ZeroAddress,
      ]);
      const proxy = await ERC1967Proxy.deploy(await tokenImpl.getAddress(), initData);
      await proxy.waitForDeployment();

      tokenProxy = await proxy.getAddress();
      token = TokenImpl.attach(tokenProxy) as unknown as EncryptedGovernanceTokenUpgradeable;

      expect(await token.name()).to.equal("Encrypted Gov Token");
      expect(await token.symbol()).to.equal("eGOV");
      expect(await token.owner()).to.equal(owner.address);
      expect(await token.version()).to.equal(1);
    });

    it("should deploy EncryptedTokenVoting plugin (non-proxy)", async function () {
      const Voting = await ethers.getContractFactory("EncryptedTokenVoting");
      voting = (await Voting.deploy(
        daoProxy,
        tokenProxy,
        VOTING_DURATION,
        QUORUM_PCT,
        SUPPORT_PCT,
        MIN_PROPOSER_BALANCE,
        ethers.ZeroAddress,
      )) as unknown as EncryptedTokenVoting;
      await voting.waitForDeployment();

      expect(await voting.dao()).to.equal(daoProxy);
      expect(await voting.governanceToken()).to.equal(tokenProxy);
    });

    it("should wire up permissions (snapshot creator + execute)", async function () {
      const votingAddress = await voting.getAddress();

      // Authorize voting plugin as snapshot creator
      await token.setSnapshotCreator(votingAddress, true);
      expect(await token.isSnapshotCreator(votingAddress)).to.be.true;

      // Grant EXECUTE_PERMISSION to voting plugin on the DAO
      const EXECUTE_PERMISSION_ID = await dao.EXECUTE_PERMISSION_ID();
      await dao.grant(daoProxy, votingAddress, EXECUTE_PERMISSION_ID);
      expect(await dao.hasPermission(daoProxy, votingAddress, EXECUTE_PERMISSION_ID)).to.be.true;
    });

    it("should prevent re-initialization", async function () {
      await expect(
        dao.initialize(alice.address, ethers.ZeroAddress),
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 2. TOKEN OPERATIONS (with FHE mock)
  // ═══════════════════════════════════════════════════════════════════

  describe("2. Token Operations", function () {
    it("should mint tokens to multiple members", async function () {
      await token.mint(alice.address, 500);
      await token.mint(bob.address, 300);
      await token.mint(carol.address, 200);

      expect(await token.totalSupply()).to.equal(1000);
      expect(await token.isTokenHolder(alice.address)).to.be.true;
      expect(await token.isTokenHolder(bob.address)).to.be.true;
      expect(await token.isTokenHolder(carol.address)).to.be.true;
    });

    it("should support delegation", async function () {
      // Alice delegates to Bob — Bob will have Alice's + Bob's voting power
      await token.connect(alice).delegate(bob.address);
      expect(await token.delegates(alice.address)).to.equal(bob.address);
    });

    it("should reject minting from non-owner", async function () {
      await expect(token.connect(alice).mint(alice.address, 100)).to.be.revertedWith("Not owner");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 3. PROPOSAL LIFECYCLE (with FHE mock)
  // ═══════════════════════════════════════════════════════════════════

  describe("3. Proposal Lifecycle", function () {
    let proposalId: bigint;

    it("should create a proposal with encrypted calldata", async function () {
      const votingAddress = await voting.getAddress();

      // Encode a simple ETH transfer action as the proposal
      const actions = [
        {
          to: bob.address,
          value: ethers.parseEther("0.1"),
          data: "0x",
        },
      ];
      const encodedActions = ethers.AbiCoder.defaultAbiCoder().encode(
        ["(address,uint256,bytes)[]"],
        [actions.map((a) => [a.to, a.value, a.data])],
      );

      // Split into 32-byte chunks and pad
      const chunkSize = 32;
      const padded =
        encodedActions.length % (chunkSize * 2 + 2) === 0
          ? encodedActions
          : encodedActions +
            "0".repeat(chunkSize * 2 - ((encodedActions.length - 2) % (chunkSize * 2)));
      const rawBytes = ethers.getBytes(padded);
      const chunkCount = Math.ceil(rawBytes.length / chunkSize);

      // Create encrypted input with all chunks
      const input = fhevm.createEncryptedInput(votingAddress, alice.address);
      for (let i = 0; i < chunkCount; i++) {
        const chunk = rawBytes.slice(i * chunkSize, (i + 1) * chunkSize);
        const value = BigInt(ethers.hexlify(chunk));
        input.add256(value);
      }
      const encrypted = await input.encrypt();

      // Create cancel key
      const cancelKey = ethers.randomBytes(32);
      const cancelKeyHash = ethers.keccak256(cancelKey);

      // Convert handles to bytes32 array
      const encHandles = encrypted.handles.map((h: Uint8Array) => ethers.hexlify(h));

      const tx = await voting.connect(alice).createProposal(
        encHandles,
        encrypted.inputProof,
        cancelKeyHash,
        { startDate: 0, endDate: 0 },
      );
      await tx.wait();

      proposalId = BigInt(await voting.proposalCount());
      expect(proposalId).to.equal(1n);

      // Verify proposal state is Active
      expect(await voting.state(proposalId)).to.equal(0); // Active
    });

    it("should allow token holders to view the proposal", async function () {
      await expect(voting.connect(alice).viewProposal(proposalId)).to.emit(
        voting,
        "ProposalViewed",
      );
    });

    it("should allow voting with encrypted ballots", async function () {
      const votingAddress = await voting.getAddress();

      // Bob votes YES
      const bobInput = fhevm.createEncryptedInput(votingAddress, bob.address);
      bobInput.addBool(true);
      const bobEncrypted = await bobInput.encrypt();

      await voting
        .connect(bob)
        .vote(proposalId, bobEncrypted.handles[0], bobEncrypted.inputProof);
      expect(await voting.hasVoted(proposalId, bob.address)).to.be.true;

      // Carol votes NO
      const carolInput = fhevm.createEncryptedInput(votingAddress, carol.address);
      carolInput.addBool(false);
      const carolEncrypted = await carolInput.encrypt();

      await voting
        .connect(carol)
        .vote(proposalId, carolEncrypted.handles[0], carolEncrypted.inputProof);
      expect(await voting.hasVoted(proposalId, carol.address)).to.be.true;
    });

    it("should prevent double voting", async function () {
      const votingAddress = await voting.getAddress();
      const input = fhevm.createEncryptedInput(votingAddress, bob.address);
      input.addBool(true);
      const encrypted = await input.encrypt();

      await expect(
        voting.connect(bob).vote(proposalId, encrypted.handles[0], encrypted.inputProof),
      ).to.be.revertedWith("Already voted");
    });

    it("should reject finalization before voting ends", async function () {
      await expect(voting.finalize(proposalId, "0x", "0x")).to.be.revertedWith("Voting not ended");
    });

    it("should transition to Pending after voting period ends", async function () {
      // Fast-forward past voting duration
      await ethers.provider.send("evm_increaseTime", [VOTING_DURATION + 1]);
      await ethers.provider.send("evm_mine", []);

      expect(await voting.state(proposalId)).to.equal(1); // Pending
    });

    it("should finalize the proposal with mock decryption proofs", async function () {
      // Finalization requires KMS decryption proofs (FHE.checkSignatures).
      // In Hardhat's in-process mode, the mock KMS relay is not available.
      // This step requires running against `npx hardhat node` (external process)
      // where the fhevm mock relay is fully operational.
      //
      // The voting tally for this proposal:
      //   Bob: 800 voting power (500 Alice delegated + 300 own) → YES
      //   Carol: 200 voting power → NO
      //   Total: 1000, Quorum: 200 (20%) ✓, Majority: 800 > 200 ✓
      //   Expected: APPROVED
      //
      // To test finalize/reveal/execute, run:
      //   npm run chain    (terminal 1)
      //   npm run test:e2e:localhost  (terminal 2)
      this.skip();
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 4. DAO UPGRADE via GOVERNANCE
  // ═══════════════════════════════════════════════════════════════════

  describe("4. DAO Upgrade via Governance", function () {
    it("should upgrade DAO from V1 to V2 via owner (UPGRADE_PERMISSION)", async function () {
      // Deploy V2 implementation
      const DAOV2Impl = await ethers.getContractFactory("DAOUpgradeableV2");
      const daoV2Impl = await DAOV2Impl.deploy();
      await daoV2Impl.waitForDeployment();
      const v2ImplAddress = await daoV2Impl.getAddress();

      // Owner has UPGRADE_PERMISSION — upgrade directly
      await dao.upgradeToAndCall(v2ImplAddress, "0x");

      // Attach V2 interface to the proxy
      const daoV2 = DAOV2Impl.attach(daoProxy) as unknown as DAOUpgradeableV2;

      // Verify upgrade
      expect(await daoV2.version()).to.equal(2);

      // Verify existing state preserved — owner still has ROOT
      const ROOT_PERMISSION_ID = await daoV2.ROOT_PERMISSION_ID();
      expect(await daoV2.hasPermission(daoProxy, owner.address, ROOT_PERMISSION_ID)).to.be.true;
    });

    it("should use new V2 functionality (pause/unpause)", async function () {
      const DAOV2Impl = await ethers.getContractFactory("DAOUpgradeableV2");
      const daoV2 = DAOV2Impl.attach(daoProxy) as unknown as DAOUpgradeableV2;

      // Grant PAUSE_PERMISSION to owner
      const PAUSE_PERMISSION_ID = await daoV2.PAUSE_PERMISSION_ID();
      await daoV2.grant(daoProxy, owner.address, PAUSE_PERMISSION_ID);

      // Pause
      await daoV2.pause();
      expect(await daoV2.paused()).to.be.true;

      // Unpause
      await daoV2.unpause();
      expect(await daoV2.paused()).to.be.false;
    });

    it("should reject upgrade from unauthorized account", async function () {
      const DAOV2Impl = await ethers.getContractFactory("DAOUpgradeableV2");
      const daoV2Impl = await DAOV2Impl.deploy();
      await daoV2Impl.waitForDeployment();

      // Alice doesn't have UPGRADE_PERMISSION
      await expect(
        dao.connect(alice).upgradeToAndCall(await daoV2Impl.getAddress(), "0x"),
      ).to.be.revertedWith("DAO: unauthorized");
    });

    it("should allow upgrade via DAO governance (execute action)", async function () {
      const DAOV2Impl = await ethers.getContractFactory("DAOUpgradeableV2");
      const daoV2 = DAOV2Impl.attach(daoProxy) as unknown as DAOUpgradeableV2;

      // Deploy another V2 impl (to test upgrade-via-execute)
      const anotherV2 = await DAOV2Impl.deploy();
      await anotherV2.waitForDeployment();

      // Grant EXECUTE_PERMISSION to owner for testing
      const EXECUTE_PERMISSION_ID = await daoV2.EXECUTE_PERMISSION_ID();
      await daoV2.grant(daoProxy, owner.address, EXECUTE_PERMISSION_ID);

      // When DAO.execute() calls upgradeToAndCall on itself, _msgSender() is
      // the DAO address (self-call). So the DAO needs UPGRADE_PERMISSION for itself.
      const UPGRADE_PERMISSION_ID = await daoV2.UPGRADE_PERMISSION_ID();
      await daoV2.grant(daoProxy, daoProxy, UPGRADE_PERMISSION_ID);

      // Construct upgrade action: DAO calls upgradeToAndCall on itself
      const upgradeCalldata = daoV2.interface.encodeFunctionData("upgradeToAndCall", [
        await anotherV2.getAddress(),
        "0x",
      ]);
      const actions = [{ to: daoProxy, value: 0, data: upgradeCalldata }];

      // Execute through DAO
      await daoV2.execute(ethers.id("upgrade-action"), actions, 0);

      // Still V2
      expect(await daoV2.version()).to.equal(2);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 5. PLUGIN ROTATION (swap voting plugin)
  // ═══════════════════════════════════════════════════════════════════

  describe("5. Plugin Rotation", function () {
    it("should rotate voting plugin by revoking/granting EXECUTE_PERMISSION", async function () {
      const DAOV2Impl = await ethers.getContractFactory("DAOUpgradeableV2");
      const daoV2 = DAOV2Impl.attach(daoProxy) as unknown as DAOUpgradeableV2;
      const EXECUTE_PERMISSION_ID = await daoV2.EXECUTE_PERMISSION_ID();
      const oldVotingAddress = await voting.getAddress();

      // Deploy new voting plugin (V2 with different params)
      const Voting = await ethers.getContractFactory("EncryptedTokenVoting");
      const newVoting = (await Voting.deploy(
        daoProxy,
        tokenProxy,
        VOTING_DURATION * 2, // Longer voting duration
        30, // Higher quorum
        60, // Higher support
        MIN_PROPOSER_BALANCE,
        ethers.ZeroAddress,
      )) as unknown as EncryptedTokenVoting;
      await newVoting.waitForDeployment();
      const newVotingAddress = await newVoting.getAddress();

      // Revoke old plugin
      await daoV2.revoke(daoProxy, oldVotingAddress, EXECUTE_PERMISSION_ID);
      expect(await daoV2.hasPermission(daoProxy, oldVotingAddress, EXECUTE_PERMISSION_ID)).to.be
        .false;

      // Grant to new plugin
      await daoV2.grant(daoProxy, newVotingAddress, EXECUTE_PERMISSION_ID);
      expect(await daoV2.hasPermission(daoProxy, newVotingAddress, EXECUTE_PERMISSION_ID)).to.be
        .true;

      // Authorize new voting as snapshot creator
      await token.setSnapshotCreator(newVotingAddress, true);
      expect(await token.isSnapshotCreator(newVotingAddress)).to.be.true;

      // Revoke old snapshot creator
      await token.setSnapshotCreator(oldVotingAddress, false);
      expect(await token.isSnapshotCreator(oldVotingAddress)).to.be.false;

      // Verify new plugin has correct params
      expect(await newVoting.votingDuration()).to.equal(VOTING_DURATION * 2);
      expect(await newVoting.minQuorumPct()).to.equal(30);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 6. TREASURY OPERATIONS
  // ═══════════════════════════════════════════════════════════════════

  describe("6. Treasury Operations", function () {
    it("should accept ETH deposits", async function () {
      const DAOV2Impl = await ethers.getContractFactory("DAOUpgradeableV2");
      const daoV2 = DAOV2Impl.attach(daoProxy) as unknown as DAOUpgradeableV2;

      await expect(
        owner.sendTransaction({ to: daoProxy, value: ethers.parseEther("1.0") }),
      )
        .to.emit(daoV2, "ETHDeposited")
        .withArgs(owner.address, ethers.parseEther("1.0"));

      const balance = await ethers.provider.getBalance(daoProxy);
      expect(balance).to.equal(ethers.parseEther("1.0"));
    });

    it("should execute ETH transfer via EXECUTE_PERMISSION", async function () {
      const DAOV2Impl = await ethers.getContractFactory("DAOUpgradeableV2");
      const daoV2 = DAOV2Impl.attach(daoProxy) as unknown as DAOUpgradeableV2;

      const carolBalanceBefore = await ethers.provider.getBalance(carol.address);

      const actions = [
        { to: carol.address, value: ethers.parseEther("0.5"), data: "0x" },
      ];
      await daoV2.execute(ethers.id("treasury-transfer"), actions, 0);

      const carolBalanceAfter = await ethers.provider.getBalance(carol.address);
      expect(carolBalanceAfter - carolBalanceBefore).to.equal(ethers.parseEther("0.5"));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 7. GOVERNANCE TOKEN UPGRADE
  // ═══════════════════════════════════════════════════════════════════

  describe("7. Governance Token Upgrade", function () {
    it("should preserve token state across proxy upgrade", async function () {
      // Capture state before upgrade
      const supplyBefore = await token.totalSupply();
      const aliceIsHolder = await token.isTokenHolder(alice.address);

      // Deploy new token implementation (same contract, simulating a bugfix)
      const TokenV1 = await ethers.getContractFactory("EncryptedGovernanceTokenUpgradeable");
      const newImpl = await TokenV1.deploy();
      await newImpl.waitForDeployment();

      // Upgrade
      await token.upgradeToAndCall(await newImpl.getAddress(), "0x");

      // Verify state preserved
      expect(await token.totalSupply()).to.equal(supplyBefore);
      expect(await token.isTokenHolder(alice.address)).to.equal(aliceIsHolder);
      expect(await token.name()).to.equal("Encrypted Gov Token");
      expect(await token.version()).to.equal(1);
    });
  });
});
