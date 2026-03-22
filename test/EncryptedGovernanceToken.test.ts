import { expect } from "chai";
import { ethers, fhevm } from "hardhat";
import type { EncryptedGovernanceToken } from "../types";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

async function deployProxy(contractName: string, initArgs: unknown[]): Promise<string> {
  const Impl = await ethers.getContractFactory(contractName);
  const impl = await Impl.deploy();
  await impl.waitForDeployment();
  const initData = Impl.interface.encodeFunctionData("initialize", initArgs);
  const ERC1967Proxy = await ethers.getContractFactory("ERC1967Proxy", { libraries: {} });
  const proxy = await ERC1967Proxy.deploy(await impl.getAddress(), initData);
  await proxy.waitForDeployment();
  return await proxy.getAddress();
}

describe("EncryptedGovernanceToken", function () {
  let token: EncryptedGovernanceToken;
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let snapshotCreator: HardhatEthersSigner;

  beforeEach(async function () {
    [owner, alice, bob, snapshotCreator] = await ethers.getSigners();
    const proxyAddr = await deployProxy("EncryptedGovernanceToken", [
      "Encrypted Gov Token",
      "eGOV",
      ethers.ZeroAddress,
    ]);
    const Token = await ethers.getContractFactory("EncryptedGovernanceToken");
    token = Token.attach(proxyAddr) as unknown as EncryptedGovernanceToken;
  });

  describe("Deployment", function () {
    it("should set name and symbol correctly", async function () {
      expect(await token.name()).to.equal("Encrypted Gov Token");
      expect(await token.symbol()).to.equal("eGOV");
    });

    it("should set deployer as owner", async function () {
      expect(await token.owner()).to.equal(owner.address);
    });

    it("should have 18 decimals", async function () {
      expect(await token.decimals()).to.equal(18);
    });

    it("should start with zero total supply", async function () {
      expect(await token.totalSupply()).to.equal(0);
    });

    it("should start with zero snapshot ID", async function () {
      expect(await token.currentSnapshotId()).to.equal(0);
    });
  });

  describe("Minting access control", function () {
    it("should revert when minting to zero address", async function () {
      await expect(token.mint(ethers.ZeroAddress, 100)).to.be.revertedWith("Mint to zero address");
    });

    it("should revert when non-owner calls mint", async function () {
      await expect(token.connect(alice).mint(bob.address, 100)).to.be.revertedWith("Not owner");
    });
  });

  describe("Minting (requires fhEVM)", function () {
    beforeEach(function () {
      if (!fhevm.isMock) this.skip();
    });

    it("should increase totalSupply on mint", async function () {
      await token.mint(alice.address, 1000);
      expect(await token.totalSupply()).to.equal(1000);
    });

    it("should mark recipient as token holder", async function () {
      await token.mint(alice.address, 500);
      expect(await token.isTokenHolder(alice.address)).to.be.true;
    });

    it("should emit Mint event", async function () {
      await expect(token.mint(alice.address, 1000))
        .to.emit(token, "Mint")
        .withArgs(alice.address, 1000);
    });

    it("should accumulate totalSupply across multiple mints", async function () {
      await token.mint(alice.address, 1000);
      await token.mint(bob.address, 500);
      expect(await token.totalSupply()).to.equal(1500);
    });
  });

  describe("Token Holder Registry", function () {
    it("should return false for non-holder", async function () {
      expect(await token.isTokenHolder(alice.address)).to.be.false;
    });
  });

  describe("Snapshot Management", function () {
    it("should revert if non-authorized address tries to create snapshot", async function () {
      await expect(token.connect(alice).createSnapshot()).to.be.revertedWith(
        "Not authorized to snapshot",
      );
    });

    it("should allow authorized creator to create snapshot", async function () {
      await token.setSnapshotCreator(snapshotCreator.address, true);
      expect(await token.isSnapshotCreator(snapshotCreator.address)).to.be.true;

      await expect(token.connect(snapshotCreator).createSnapshot())
        .to.emit(token, "SnapshotCreated")
        .withArgs(1);

      expect(await token.currentSnapshotId()).to.equal(1);
    });

    it("should increment snapshot IDs", async function () {
      await token.setSnapshotCreator(snapshotCreator.address, true);
      await token.connect(snapshotCreator).createSnapshot();
      await token.connect(snapshotCreator).createSnapshot();
      expect(await token.currentSnapshotId()).to.equal(2);
    });

    it("should allow owner to revoke snapshot creator", async function () {
      await token.setSnapshotCreator(snapshotCreator.address, true);
      await token.setSnapshotCreator(snapshotCreator.address, false);
      expect(await token.isSnapshotCreator(snapshotCreator.address)).to.be.false;
    });

    it("should revert if non-owner calls setSnapshotCreator", async function () {
      await expect(
        token.connect(alice).setSnapshotCreator(snapshotCreator.address, true),
      ).to.be.revertedWith("Not owner");
    });
  });

  describe("Delegation (requires fhEVM)", function () {
    beforeEach(function () {
      if (!fhevm.isMock) this.skip();
    });

    it("should emit DelegateChanged event", async function () {
      await token.mint(alice.address, 1000);
      await expect(token.connect(alice).delegate(bob.address))
        .to.emit(token, "DelegateChanged")
        .withArgs(alice.address, alice.address, bob.address);
    });

    it("should update delegates mapping", async function () {
      await token.mint(alice.address, 1000);
      await token.connect(alice).delegate(bob.address);
      expect(await token.delegates(alice.address)).to.equal(bob.address);
    });

    it("should allow delegation to self (revoke delegation)", async function () {
      await token.mint(alice.address, 1000);
      await token.connect(alice).delegate(bob.address);
      await token.connect(alice).delegate(alice.address);
      expect(await token.delegates(alice.address)).to.equal(alice.address);
    });

    it("should treat address(0) delegation as self-delegation", async function () {
      await token.mint(alice.address, 1000);
      await token.connect(alice).delegate(bob.address);
      await token.connect(alice).delegate(ethers.ZeroAddress);
      expect(await token.delegates(alice.address)).to.equal(alice.address);
    });
  });
});
