import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import type { DAO, EncryptedGovernanceToken, EncryptedTokenVoting } from "../types";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("EncryptedTokenVoting", function () {
  let dao: DAO;
  let token: EncryptedGovernanceToken;
  let voting: EncryptedTokenVoting;
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;

  const VOTING_DURATION = 7 * 24 * 60 * 60;
  const QUORUM_PCT = 20;
  const SUPPORT_PCT = 50;
  const MIN_PROPOSER_BALANCE = 100;

  beforeEach(async function () {
    [owner, alice] = await ethers.getSigners();

    const DAO = await ethers.getContractFactory("DAO");
    dao = (await DAO.deploy(owner.address, ethers.ZeroAddress)) as unknown as DAO;
    await dao.waitForDeployment();

    const Token = await ethers.getContractFactory("EncryptedGovernanceToken");
    token = (await Token.deploy(
      "Gov Token",
      "GOV",
      ethers.ZeroAddress,
    )) as unknown as EncryptedGovernanceToken;
    await token.waitForDeployment();

    const Voting = await ethers.getContractFactory("EncryptedTokenVoting");
    voting = (await Voting.deploy(
      await dao.getAddress(),
      await token.getAddress(),
      VOTING_DURATION,
      QUORUM_PCT,
      SUPPORT_PCT,
      MIN_PROPOSER_BALANCE,
      ethers.ZeroAddress,
    )) as unknown as EncryptedTokenVoting;
    await voting.waitForDeployment();

    const votingAddress = await voting.getAddress();
    await token.setSnapshotCreator(votingAddress, true);

    const daoAddress = await dao.getAddress();
    const EXECUTE_PERMISSION_ID = await dao.EXECUTE_PERMISSION_ID();
    await dao.grant(daoAddress, votingAddress, EXECUTE_PERMISSION_ID);
  });

  describe("Deployment", function () {
    it("should set immutable references correctly", async function () {
      expect(await voting.dao()).to.equal(await dao.getAddress());
      expect(await voting.governanceToken()).to.equal(await token.getAddress());
    });

    it("should set governance parameters", async function () {
      expect(await voting.votingDuration()).to.equal(VOTING_DURATION);
      expect(await voting.minQuorumPct()).to.equal(QUORUM_PCT);
      expect(await voting.minSupportPct()).to.equal(SUPPORT_PCT);
      expect(await voting.minProposerBalance()).to.equal(MIN_PROPOSER_BALANCE);
    });

    it("should start with zero proposals", async function () {
      expect(await voting.proposalCount()).to.equal(0);
    });

    it("should have correct MAX_CALLDATA_CHUNKS", async function () {
      expect(await voting.MAX_CALLDATA_CHUNKS()).to.equal(24);
    });

    it("should revert with invalid DAO address", async function () {
      const Voting = await ethers.getContractFactory("EncryptedTokenVoting");
      await expect(
        Voting.deploy(
          ethers.ZeroAddress,
          await token.getAddress(),
          VOTING_DURATION,
          QUORUM_PCT,
          SUPPORT_PCT,
          MIN_PROPOSER_BALANCE,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Invalid DAO");
    });

    it("should revert with invalid token address", async function () {
      const Voting = await ethers.getContractFactory("EncryptedTokenVoting");
      await expect(
        Voting.deploy(
          await dao.getAddress(),
          ethers.ZeroAddress,
          VOTING_DURATION,
          QUORUM_PCT,
          SUPPORT_PCT,
          MIN_PROPOSER_BALANCE,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Invalid token");
    });

    it("should revert with zero voting duration", async function () {
      const Voting = await ethers.getContractFactory("EncryptedTokenVoting");
      await expect(
        Voting.deploy(
          await dao.getAddress(),
          await token.getAddress(),
          0,
          QUORUM_PCT,
          SUPPORT_PCT,
          MIN_PROPOSER_BALANCE,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Invalid voting duration");
    });

    it("should revert with invalid quorum percentage", async function () {
      const Voting = await ethers.getContractFactory("EncryptedTokenVoting");
      await expect(
        Voting.deploy(
          await dao.getAddress(),
          await token.getAddress(),
          VOTING_DURATION,
          0,
          SUPPORT_PCT,
          MIN_PROPOSER_BALANCE,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Invalid quorum");

      await expect(
        Voting.deploy(
          await dao.getAddress(),
          await token.getAddress(),
          VOTING_DURATION,
          101,
          SUPPORT_PCT,
          MIN_PROPOSER_BALANCE,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Invalid quorum");
    });
  });

  describe("View Functions", function () {
    it("should revert state() on invalid proposal", async function () {
      await expect(voting.state(0)).to.be.revertedWith("Invalid proposal");
      await expect(voting.state(999)).to.be.revertedWith("Invalid proposal");
    });

    it("should revert getProposalInfo on invalid proposal", async function () {
      await expect(voting.getProposalInfo(0)).to.be.revertedWith("Invalid proposal");
    });

    it("should revert getRevealedChunks on invalid proposal", async function () {
      await expect(voting.getRevealedChunks(0)).to.be.revertedWith("Invalid proposal");
    });

    it("should return false for hasVoted on non-voters", async function () {
      expect(await voting.hasVoted(1, alice.address)).to.be.false;
    });
  });

  describe("Cancellation", function () {
    it("should revert cancel on non-existent proposal", async function () {
      await expect(voting.cancel(1, ethers.randomBytes(32))).to.be.revertedWith("Invalid proposal");
    });
  });

  describe("FHE Integration (requires fhEVM mock)", function () {
    beforeEach(function () {
      if (!fhevm.isMock) this.skip();
    });

    it("should allow minting tokens for voting members", async function () {
      await token.mint(alice.address, 1000);
      expect(await token.totalSupply()).to.equal(1000);
    });

    // Full proposal lifecycle tests (createProposal → vote → finalize → reveal → execute)
    // require encrypted input creation via fhevm.createEncryptedInput().
    // See test/EncryptedTokenVotingSepolia.ts for full integration tests.
  });
});
