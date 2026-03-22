import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import type { DAO, EncryptedMultisig } from "../types";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("EncryptedMultisig", function () {
  let dao: DAO;
  let multisig: EncryptedMultisig;
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let carol: HardhatEthersSigner;
  let nonSigner: HardhatEthersSigner;

  const THRESHOLD = 2;
  const PROPOSAL_DURATION = 30 * 24 * 60 * 60;

  describe("Constructor validation (no FHE needed)", function () {
    beforeEach(async function () {
      [owner, alice, bob, carol, nonSigner] = await ethers.getSigners();
      const DAO = await ethers.getContractFactory("DAO");
      dao = (await DAO.deploy(owner.address, ethers.ZeroAddress)) as unknown as DAO;
      await dao.waitForDeployment();
    });

    it("should revert with zero address DAO", async function () {
      const Multisig = await ethers.getContractFactory("EncryptedMultisig");
      await expect(
        Multisig.deploy(
          ethers.ZeroAddress,
          [alice.address],
          1,
          PROPOSAL_DURATION,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Invalid DAO");
    });

    it("should revert with empty signers array", async function () {
      const Multisig = await ethers.getContractFactory("EncryptedMultisig");
      await expect(
        Multisig.deploy(
          await dao.getAddress(),
          [],
          1,
          PROPOSAL_DURATION,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Need at least one signer");
    });

    it("should revert with zero threshold", async function () {
      const Multisig = await ethers.getContractFactory("EncryptedMultisig");
      await expect(
        Multisig.deploy(
          await dao.getAddress(),
          [alice.address],
          0,
          PROPOSAL_DURATION,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Invalid threshold");
    });

    it("should revert with threshold exceeding signer count", async function () {
      const Multisig = await ethers.getContractFactory("EncryptedMultisig");
      await expect(
        Multisig.deploy(
          await dao.getAddress(),
          [alice.address],
          2,
          PROPOSAL_DURATION,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Invalid threshold");
    });

    it("should revert with zero duration", async function () {
      const Multisig = await ethers.getContractFactory("EncryptedMultisig");
      await expect(
        Multisig.deploy(
          await dao.getAddress(),
          [alice.address],
          1,
          0,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Invalid duration");
    });

    it("should revert with zero address signer", async function () {
      const Multisig = await ethers.getContractFactory("EncryptedMultisig");
      await expect(
        Multisig.deploy(
          await dao.getAddress(),
          [ethers.ZeroAddress],
          1,
          PROPOSAL_DURATION,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Zero address");
    });

    it("should revert with duplicate signers", async function () {
      const Multisig = await ethers.getContractFactory("EncryptedMultisig");
      await expect(
        Multisig.deploy(
          await dao.getAddress(),
          [alice.address, alice.address],
          1,
          PROPOSAL_DURATION,
          ethers.ZeroAddress,
        ),
      ).to.be.revertedWith("Duplicate signer");
    });
  });

  describe("Deployment (requires fhEVM mock)", function () {
    beforeEach(async function () {
      if (!fhevm.isMock) this.skip();

      [owner, alice, bob, carol, nonSigner] = await ethers.getSigners();

      const DAO = await ethers.getContractFactory("DAO");
      dao = (await DAO.deploy(owner.address, ethers.ZeroAddress)) as unknown as DAO;
      await dao.waitForDeployment();

      const Multisig = await ethers.getContractFactory("EncryptedMultisig");
      multisig = (await Multisig.deploy(
        await dao.getAddress(),
        [alice.address, bob.address, carol.address],
        THRESHOLD,
        PROPOSAL_DURATION,
        ethers.ZeroAddress,
      )) as unknown as EncryptedMultisig;
      await multisig.waitForDeployment();
    });

    it("should set DAO reference", async function () {
      expect(await multisig.dao()).to.equal(await dao.getAddress());
    });

    it("should set threshold", async function () {
      expect(await multisig.threshold()).to.equal(THRESHOLD);
    });

    it("should set proposal duration", async function () {
      expect(await multisig.proposalDuration()).to.equal(PROPOSAL_DURATION);
    });

    it("should set signer count", async function () {
      expect(await multisig.signerCount()).to.equal(3);
    });

    it("should start with zero proposals", async function () {
      expect(await multisig.proposalCount()).to.equal(0);
    });

    it("should revert addSigner if not called by DAO", async function () {
      await expect(multisig.connect(alice).addSigner(nonSigner.address)).to.be.revertedWith(
        "Only via DAO",
      );
    });

    it("should revert removeSigner if not called by DAO", async function () {
      await expect(multisig.connect(alice).removeSigner(bob.address)).to.be.revertedWith(
        "Only via DAO",
      );
    });

    it("should revert setThreshold if not called by DAO", async function () {
      await expect(multisig.connect(alice).setThreshold(1)).to.be.revertedWith("Only via DAO");
    });

    it("should revert state() on invalid proposal", async function () {
      await expect(multisig.state(0)).to.be.revertedWith("Invalid proposal");
    });

    it("should revert getProposalInfo on invalid proposal", async function () {
      await expect(multisig.getProposalInfo(0)).to.be.revertedWith("Invalid proposal");
    });

    it("should revert cancel on non-existent proposal", async function () {
      await expect(multisig.cancel(1, ethers.randomBytes(32))).to.be.revertedWith(
        "Invalid proposal",
      );
    });
  });
});
