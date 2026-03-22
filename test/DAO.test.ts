import { expect } from "chai";
import { ethers } from "hardhat";
import type { DAO } from "../types";
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

describe("DAO", function () {
  let dao: DAO;
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;

  const EXECUTE_PERMISSION_ID = ethers.keccak256(ethers.toUtf8Bytes("EXECUTE_PERMISSION"));
  const ROOT_PERMISSION_ID = ethers.keccak256(ethers.toUtf8Bytes("ROOT_PERMISSION"));

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();
    const proxyAddr = await deployProxy("DAO", [owner.address, ethers.ZeroAddress]);
    const DAO = await ethers.getContractFactory("DAO");
    dao = DAO.attach(proxyAddr) as unknown as DAO;
  });

  describe("Deployment", function () {
    it("should set deployer as ROOT permission holder", async function () {
      const daoAddress = await dao.getAddress();
      const hasRoot = await dao.hasPermission(daoAddress, owner.address, ROOT_PERMISSION_ID);
      expect(hasRoot).to.be.true;
    });

    it("should revert with zero address owner", async function () {
      await expect(
        deployProxy("DAO", [ethers.ZeroAddress, ethers.ZeroAddress]),
      ).to.be.revertedWith("DAO: zero address owner");
    });

    it("should expose correct permission IDs", async function () {
      expect(await dao.EXECUTE_PERMISSION_ID()).to.equal(EXECUTE_PERMISSION_ID);
      expect(await dao.ROOT_PERMISSION_ID()).to.equal(ROOT_PERMISSION_ID);
    });
  });

  describe("Permissions", function () {
    it("should allow ROOT holder to grant permissions", async function () {
      const daoAddress = await dao.getAddress();
      await dao.grant(daoAddress, alice.address, EXECUTE_PERMISSION_ID);
      const hasExec = await dao.hasPermission(daoAddress, alice.address, EXECUTE_PERMISSION_ID);
      expect(hasExec).to.be.true;
    });

    it("should allow ROOT holder to revoke permissions", async function () {
      const daoAddress = await dao.getAddress();
      await dao.grant(daoAddress, alice.address, EXECUTE_PERMISSION_ID);
      await dao.revoke(daoAddress, alice.address, EXECUTE_PERMISSION_ID);
      const hasExec = await dao.hasPermission(daoAddress, alice.address, EXECUTE_PERMISSION_ID);
      expect(hasExec).to.be.false;
    });

    it("should revert if non-ROOT tries to grant", async function () {
      const daoAddress = await dao.getAddress();
      await expect(
        dao.connect(alice).grant(daoAddress, bob.address, EXECUTE_PERMISSION_ID),
      ).to.be.revertedWith("DAO: unauthorized");
    });

    it("should emit PermissionChanged event", async function () {
      const daoAddress = await dao.getAddress();
      await expect(dao.grant(daoAddress, alice.address, EXECUTE_PERMISSION_ID))
        .to.emit(dao, "PermissionChanged")
        .withArgs(EXECUTE_PERMISSION_ID);
    });

    it("should not emit event on redundant grant", async function () {
      const daoAddress = await dao.getAddress();
      await dao.grant(daoAddress, alice.address, EXECUTE_PERMISSION_ID);
      await expect(dao.grant(daoAddress, alice.address, EXECUTE_PERMISSION_ID)).to.not.emit(
        dao,
        "PermissionChanged",
      );
    });
  });

  describe("Execute", function () {
    it("should revert if caller lacks EXECUTE_PERMISSION", async function () {
      await expect(dao.connect(alice).execute(ethers.ZeroHash, [], 0)).to.be.revertedWith(
        "DAO: unauthorized",
      );
    });

    it("should revert with empty actions array", async function () {
      const daoAddress = await dao.getAddress();
      await dao.grant(daoAddress, alice.address, EXECUTE_PERMISSION_ID);
      await expect(dao.connect(alice).execute(ethers.ZeroHash, [], 0)).to.be.revertedWith(
        "DAO: no actions",
      );
    });

    it("should execute a simple ETH transfer action", async function () {
      const daoAddress = await dao.getAddress();
      await dao.grant(daoAddress, owner.address, EXECUTE_PERMISSION_ID);

      await owner.sendTransaction({ to: daoAddress, value: ethers.parseEther("1.0") });

      const bobBalanceBefore = await ethers.provider.getBalance(bob.address);

      const actions = [{ to: bob.address, value: ethers.parseEther("0.5"), data: "0x" }];
      await dao.execute(ethers.id("test"), actions, 0);

      const bobBalanceAfter = await ethers.provider.getBalance(bob.address);
      expect(bobBalanceAfter - bobBalanceBefore).to.equal(ethers.parseEther("0.5"));
    });

    it("should emit Executed event", async function () {
      const daoAddress = await dao.getAddress();
      await dao.grant(daoAddress, owner.address, EXECUTE_PERMISSION_ID);

      await owner.sendTransaction({ to: daoAddress, value: ethers.parseEther("0.1") });

      const actions = [{ to: bob.address, value: ethers.parseEther("0.01"), data: "0x" }];
      await expect(dao.execute(ethers.id("test"), actions, 0)).to.emit(dao, "Executed");
    });
  });

  describe("ETH Deposits", function () {
    it("should accept ETH via receive()", async function () {
      const daoAddress = await dao.getAddress();
      await expect(owner.sendTransaction({ to: daoAddress, value: ethers.parseEther("1.0") }))
        .to.emit(dao, "ETHDeposited")
        .withArgs(owner.address, ethers.parseEther("1.0"));
    });

    it("should accept ETH via fallback()", async function () {
      const daoAddress = await dao.getAddress();
      await expect(
        owner.sendTransaction({
          to: daoAddress,
          value: ethers.parseEther("0.5"),
          data: "0x1234",
        }),
      )
        .to.emit(dao, "ETHDeposited")
        .withArgs(owner.address, ethers.parseEther("0.5"));
    });
  });
});
