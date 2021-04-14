
const Ganache = require('./helpers/ganache');
const deployUniswap = require('./helpers/deployUniswap');
const { expectEvent, expectRevert, constants } = require("@openzeppelin/test-helpers");
const { web3 } = require('@openzeppelin/test-helpers/src/setup');

const MockToken = artifacts.require('ERC20Mock');
// const EyeToken = artifacts.require('Eye');
// const ScarcityToken = artifacts.require('Scarcity.sol');
const AcceleratorVault = artifacts.require('AcceleratorVault');
const IUniswapV2Pair = artifacts.require('IUniswapV2Pair');


contract('Accelerator vault', function(accounts) {
  const ganache = new Ganache(web3);
  afterEach('revert', ganache.revert);

  const bn = (input) => web3.utils.toBN(input);
  const assertBNequal = (bnOne, bnTwo) => assert.equal(bnOne.toString(), bnTwo.toString());

  const OWNER = accounts[0];
  const NOT_OWNER = accounts[1];
  const HODLER_VAULT_FAKE = accounts[2];
  const baseUnit = bn('1000000000000000000');
  const startTime = Math.floor(Date.now() / 1000);
  const stakeDuration = 1;
  const donationShare = 10;
  const purchaseFee = 10;

  let uniswapOracle;
  let uniswapPair;
  let uniswapFactory;
  let uniswapRouter;
  let weth;

  let eyeToken, scarcityToken;
  let acceleratorVault;

  before('setup others', async function() {
    const contracts = await deployUniswap(accounts);
    uniswapFactory = contracts.uniswapFactory;
    uniswapRouter = contracts.uniswapRouter;
    weth = contracts.weth;

    // deploy and setup main contracts
    eyeToken = await MockToken.new('Behodler.io', 'EYE', bn('10000000').mul(baseUnit));
    scarcityToken = await MockToken.new('Scarcity', 'SCX', bn('10000000').mul(baseUnit));
    acceleratorVault = await AcceleratorVault.new();

    await uniswapFactory.createPair(eyeToken.address, scarcityToken.address);
    uniswapPair = await uniswapFactory.getPair.call(eyeToken.address, scarcityToken.address);

    await acceleratorVault.seed(
      stakeDuration,
      scarcityToken.address,
      eyeToken.address,
      uniswapPair,
      uniswapRouter.address,
      HODLER_VAULT_FAKE,
      donationShare,
      purchaseFee
    );

    await ganache.snapshot();
  });

  describe('General tests', async () => {
    it('should set all values after AV setup', async () => {
      const config = await acceleratorVault.config();
      assert.equal(config.scxToken, scarcityToken.address);
      assert.equal(config.eyeToken, eyeToken.address);
      assert.equal(config.tokenPair, uniswapPair);
      assert.equal(config.uniswapRouter, uniswapRouter.address);
      assert.equal(config.feeHodler, HODLER_VAULT_FAKE);
      assertBNequal(config.stakeDuration, 86400);
      assertBNequal(config.donationShare, donationShare);
      assertBNequal(config.purchaseFee, purchaseFee);
    });

    it('should not set parameters from non-owner', async () => {
      await expectRevert(
        acceleratorVault.setParameters(stakeDuration, donationShare, purchaseFee, { from: NOT_OWNER }),
        'Ownable: caller is not the owner'
      );
    });

    it('should set new parameters', async () => {
      const newStakeDuration = 8;
      const newDonationShare = 20;
      const newPurchaseFee = 20;
      
      await acceleratorVault.setParameters(newStakeDuration, newDonationShare, newPurchaseFee);
      const { stakeDuration, donationShare, purchaseFee } = await acceleratorVault.config();

      assertBNequal(stakeDuration, 691200);
      assertBNequal(donationShare, newDonationShare);
      assertBNequal(purchaseFee, newPurchaseFee);
    });

    it('should not do a forced unlock from non-owner', async () => {
      await expectRevert(
        acceleratorVault.enableLPForceUnlock({ from: NOT_OWNER }),
        'Ownable: caller is not the owner'
      );
    });

    it('should do a forced unlock and set lock period to 0', async () => {
      await acceleratorVault.enableLPForceUnlock();
      const stakeDuration = await acceleratorVault.getStakeDuration();

      assert.isTrue(await acceleratorVault.forceUnlock());
      assertBNequal(stakeDuration, 0);
    });

    it('should not set hodler\'s address from non-owner', async () => {
      const NEW_HODLER = accounts[3];

      await expectRevert(
        acceleratorVault.setFeeHodlerAddress(NEW_HODLER, { from: NOT_OWNER }),
        'Ownable: caller is not the owner'
      );
    });

    it('should set hodler\'s address', async () => {
      const NEW_HODLER = accounts[3];
      await acceleratorVault.setFeeHodlerAddress(NEW_HODLER);
      const { feeHodler } = await acceleratorVault.config();

      assert.equal(feeHodler, NEW_HODLER);
    });
  });

  describe('PurchaseLP tests', async () => {
    it('should not purchase LP with 0 SCX', async () => {
      await expectRevert(
        acceleratorVault.purchaseLP(0),
        'AcceleratorVault: SCX required to mint LP'
      );
    });

    it('should not purchase LP with no EYE tokens in Vault', async () => {
      const liquidityEyeAmount = bn('10000').mul(baseUnit); // 10.000 tokens
      const liquidityScxAmount = bn('500').mul(baseUnit); // 500 SCX
      const purchaseValue = bn('10').mul(baseUnit); // 10 SCX

      await eyeToken.approve(uniswapRouter.address, liquidityEyeAmount);
      await scarcityToken.approve(uniswapRouter.address, liquidityScxAmount);
      await uniswapRouter.addLiquidity(
        eyeToken.address,
        scarcityToken.address,
        liquidityEyeAmount,
        liquidityScxAmount,
        0,
        0,
        NOT_OWNER,
        new Date().getTime() + 3000
      );

      await scarcityToken.approve(acceleratorVault.address, bn(-1));
      await expectRevert(
        acceleratorVault.purchaseLP(purchaseValue),
        'AcceleratorVault: insufficient EYE tokens in AcceleratorVault'
      );
    });

    it('should purchase LP for 1 ETH', async () => {
      const liquidityEyeAmount = bn('10000').mul(baseUnit); // 10.000 tokens
      const liquidityScxAmount = bn('500').mul(baseUnit); // 500 SCX
      const transferToAccelerator = bn('20000').mul(baseUnit); // 20.000 tokens
      const purchaseValue = bn('10').mul(baseUnit); // 10 SCX

      await eyeToken.approve(uniswapRouter.address, liquidityEyeAmount);
      await scarcityToken.approve(uniswapRouter.address, liquidityScxAmount);
      await uniswapRouter.addLiquidity(
        eyeToken.address,
        scarcityToken.address,
        liquidityEyeAmount,
        liquidityScxAmount,
        0,
        0,
        NOT_OWNER,
        new Date().getTime() + 3000
      );

      await eyeToken.transfer(acceleratorVault.address, transferToAccelerator);
      const vaultBalance = await eyeToken.balanceOf(acceleratorVault.address);
      assertBNequal(vaultBalance, transferToAccelerator);
      
      const hodlerBalanceBefore = bn(await scarcityToken.balanceOf(HODLER_VAULT_FAKE));
      await scarcityToken.approve(acceleratorVault.address, bn(-1));
      const purchaseLP = await acceleratorVault.purchaseLP(purchaseValue);
      const lockedLpLength = await acceleratorVault.lockedLPLength(OWNER);
      assertBNequal(lockedLpLength, 1);

      const lockedLP = await acceleratorVault.getLockedLP(OWNER, 0);
      const { amount, timestamp } = purchaseLP.logs[0].args;
      assert.equal(lockedLP[0], OWNER);
      assertBNequal(lockedLP[1], amount);
      assertBNequal(lockedLP[2], timestamp);

      const { feeHodler } = await acceleratorVault.config();
      const { to, percentageAmount } = purchaseLP.logs[1].args;
      const estimatedHodlerAmount = (purchaseValue * purchaseFee) / 100;
      const hodlerBalanceAfter = bn(await scarcityToken.balanceOf(HODLER_VAULT_FAKE));
      
      assert.equal(feeHodler, HODLER_VAULT_FAKE);
      assert.equal(feeHodler, to);
      assertBNequal(hodlerBalanceAfter.sub(hodlerBalanceBefore), estimatedHodlerAmount);
      assertBNequal(estimatedHodlerAmount, percentageAmount);

    });

    it('should not purchase LP with too much SCX', async () => {
      const liquidityEyeAmount = bn('10000').mul(baseUnit); // 10.000 tokens
      const liquidityScxAmount = bn('500').mul(baseUnit); // 500 SCX
      const transferToAccelerator = bn('20').mul(baseUnit); // 20 tokens
      const purchaseValue = bn('1000').mul(baseUnit); // 1000 SCX

      await eyeToken.approve(uniswapRouter.address, liquidityEyeAmount);
      await scarcityToken.approve(uniswapRouter.address, liquidityScxAmount);
      await uniswapRouter.addLiquidity(
        eyeToken.address,
        scarcityToken.address,
        liquidityEyeAmount,
        liquidityScxAmount,
        0,
        0,
        NOT_OWNER,
        new Date().getTime() + 3000
      );

      await eyeToken.transfer(acceleratorVault.address, transferToAccelerator);
      const vaultBalance = await eyeToken.balanceOf(acceleratorVault.address);
      assertBNequal(vaultBalance, transferToAccelerator);

      await scarcityToken.approve(acceleratorVault.address, bn(-1));
      await expectRevert(
        acceleratorVault.purchaseLP(purchaseValue),
        'AcceleratorVault: insufficient EYE tokens in AcceleratorVault'
      );
    });
  });

  describe('ClaimLP', async () => {
    it('should not be to claim if there is no locked LP', async () => {
      await expectRevert(
        acceleratorVault.claimLP(),
        'AcceleratorVault: nothing to claim.'
      );
    });

    it('should not be able to claim if LP is still locked', async () => {
      const liquidityEyeAmount = bn('10000').mul(baseUnit); // 10.000 tokens
      const liquidityScxAmount = bn('500').mul(baseUnit); // 500 SCX
      const transferToAccelerator = bn('20000').mul(baseUnit); // 20.000 tokens
      const purchaseValue = bn('10').mul(baseUnit); // 10 SCX

      await eyeToken.approve(uniswapRouter.address, liquidityEyeAmount);
      await scarcityToken.approve(uniswapRouter.address, liquidityScxAmount);
      await uniswapRouter.addLiquidity(
        eyeToken.address,
        scarcityToken.address,
        liquidityEyeAmount,
        liquidityScxAmount,
        0,
        0,
        NOT_OWNER,
        new Date().getTime() + 3000
      );

      await eyeToken.transfer(acceleratorVault.address, transferToAccelerator);
      await scarcityToken.approve(acceleratorVault.address, bn(-1));
      await acceleratorVault.purchaseLP(purchaseValue);

      await expectRevert(
        acceleratorVault.claimLP(),
        'AcceleratorVault: LP still locked.'
      );
    });

    it('should be able to claim 1 batch after 1 purchase', async () => {
      const liquidityEyeAmount = bn('10000').mul(baseUnit); // 10.000 tokens
      const liquidityScxAmount = bn('500').mul(baseUnit); // 500 SCX
      const transferToAccelerator = bn('20000').mul(baseUnit); // 20.000 tokens
      const purchaseValue = bn('10').mul(baseUnit); // 10 SCX
      const pair = await IUniswapV2Pair.at(uniswapPair);

      await eyeToken.approve(uniswapRouter.address, liquidityEyeAmount);
      await scarcityToken.approve(uniswapRouter.address, liquidityScxAmount);
      await uniswapRouter.addLiquidity(
        eyeToken.address,
        scarcityToken.address,
        liquidityEyeAmount,
        liquidityScxAmount,
        0,
        0,
        NOT_OWNER,
        new Date().getTime() + 3000
      );

      ganache.setTime(startTime);
      await eyeToken.transfer(acceleratorVault.address, transferToAccelerator);
      await scarcityToken.approve(acceleratorVault.address, bn(-1));
      await acceleratorVault.purchaseLP(purchaseValue);
      const lockedLP = await acceleratorVault.getLockedLP(OWNER, 0);
      const { donationShare } = await acceleratorVault.config();
      const stakeDuration = await acceleratorVault.getStakeDuration();
      const lpBalanceBefore = await pair.balanceOf(OWNER);

      ganache.setTime(bn(startTime).add(stakeDuration));
      const claimLP = await acceleratorVault.claimLP();
      const { holder, amount, exitFee, claimed } = claimLP.logs[0].args;
      const estimatedFeeAmount = lockedLP[1].mul(donationShare).div(bn('100'));
      const lpBalanceAfter = await pair.balanceOf(OWNER);
      
      assert.equal(holder, OWNER);
      assert.isTrue(claimed);
      assertBNequal(amount, lockedLP[1]);
      assertBNequal(exitFee, estimatedFeeAmount);
      assertBNequal(amount.sub(exitFee), lpBalanceAfter.sub(lpBalanceBefore));
    });

    it('should be able to claim 2 batches after 2 purchases and 1 3rd party purchase', async () => {
      const liquidityEyeAmount = bn('10000').mul(baseUnit); // 10.000 tokens
      const liquidityScxAmount = bn('500').mul(baseUnit); // 500 SCX
      const transferToAccelerator = bn('20000').mul(baseUnit); // 20.000 tokens
      const purchaseValue = bn('10').mul(baseUnit); // 10 SCX
      const pair = await IUniswapV2Pair.at(uniswapPair);

      await eyeToken.approve(uniswapRouter.address, liquidityEyeAmount);
      await scarcityToken.approve(uniswapRouter.address, liquidityScxAmount);
      await uniswapRouter.addLiquidity(
        eyeToken.address,
        scarcityToken.address,
        liquidityEyeAmount,
        liquidityScxAmount,
        0,
        0,
        NOT_OWNER,
        new Date().getTime() + 3000
      );

      ganache.setTime(startTime);
      await eyeToken.transfer(acceleratorVault.address, transferToAccelerator);
      await scarcityToken.approve(acceleratorVault.address, bn(-1));
      await acceleratorVault.purchaseLP(purchaseValue);
      await acceleratorVault.purchaseLP(purchaseValue);

      await scarcityToken.transfer(NOT_OWNER, purchaseValue);
      await scarcityToken.approve(acceleratorVault.address, bn(-1), { from: NOT_OWNER });
      await acceleratorVault.purchaseLP(purchaseValue, { from: NOT_OWNER });

      assertBNequal(await acceleratorVault.lockedLPLength(OWNER), 2);
      assertBNequal(await acceleratorVault.lockedLPLength(NOT_OWNER), 1);

      const lockedLP1 = await acceleratorVault.getLockedLP(OWNER, 0);
      const lockedLP2 = await acceleratorVault.getLockedLP(OWNER, 1);
      const lockedLP3 = await acceleratorVault.getLockedLP(NOT_OWNER, 0);
      const stakeDuration = await acceleratorVault.getStakeDuration();
      const lpBalanceBefore = await pair.balanceOf(OWNER);

      ganache.setTime(bn(startTime).add(stakeDuration));
      const claimLP1 = await acceleratorVault.claimLP();
      const { amount: amount1, exitFee: exitFee1 } = claimLP1.logs[0].args;
      
      const claimLP2 = await acceleratorVault.claimLP();
      const { amount: amount2, exitFee: exitFee2 } = claimLP2.logs[0].args;
      
      const expectedLpAmount = amount1.sub(exitFee1).add(amount2.sub(exitFee2));
      const lpBalanceAfter = await pair.balanceOf(OWNER);

      assertBNequal(lpBalanceAfter.sub(lpBalanceBefore), expectedLpAmount);
      assertBNequal(amount1, lockedLP1[1]);
      assertBNequal(amount2, lockedLP2[1]);

      // an attempt to claim nonexistent batch
      await expectRevert(
        acceleratorVault.claimLP(),
        'AcceleratorVault: nothing to claim.'
      );

      const lpBalanceBefore3 = await pair.balanceOf(NOT_OWNER);
      const claimLP3 = await acceleratorVault.claimLP({ from: NOT_OWNER });
      const { holder: holder3, amount: amount3, exitFee: exitFee3 } = claimLP3.logs[0].args;

      const expectedLpAmount3 = amount3.sub(exitFee3);
      const lpBalanceAfter3 = await pair.balanceOf(NOT_OWNER);

      assert.equal(holder3, NOT_OWNER);
      assertBNequal(amount3, lockedLP3[1]);
      assertBNequal(lpBalanceAfter3.sub(lpBalanceBefore3), expectedLpAmount3);
    });

    it('should be able to claim LP after force unlock', async () => {
      const liquidityEyeAmount = bn('10000').mul(baseUnit); // 10.000 tokens
      const liquidityScxAmount = bn('500').mul(baseUnit); // 500 SCX
      const transferToAccelerator = bn('20000').mul(baseUnit); // 20.000 tokens
      const purchaseValue = bn('10').mul(baseUnit); // 10 SCX
      const pair = await IUniswapV2Pair.at(uniswapPair);

      await eyeToken.approve(uniswapRouter.address, liquidityEyeAmount);
      await scarcityToken.approve(uniswapRouter.address, liquidityScxAmount);
      await uniswapRouter.addLiquidity(
        eyeToken.address,
        scarcityToken.address,
        liquidityEyeAmount,
        liquidityScxAmount,
        0,
        0,
        NOT_OWNER,
        new Date().getTime() + 3000
      );

      ganache.setTime(startTime);
      await eyeToken.transfer(acceleratorVault.address, transferToAccelerator);
      await scarcityToken.approve(acceleratorVault.address, bn(-1));
      
      await acceleratorVault.purchaseLP(purchaseValue);
      await acceleratorVault.purchaseLP(purchaseValue);

      const lockedLP1 = await acceleratorVault.getLockedLP(OWNER, 0);
      const lockedLP2 = await acceleratorVault.getLockedLP(OWNER, 1);
      
      await acceleratorVault.enableLPForceUnlock();
      const stakeDuration = await acceleratorVault.getStakeDuration();
      const lpBalanceBefore = await pair.balanceOf(OWNER);

      assert.isTrue(await acceleratorVault.forceUnlock());
      assertBNequal(stakeDuration, 0);

      ganache.setTime(bn(startTime).add(bn(5)));

      const claimLP1 = await acceleratorVault.claimLP();
      const { amount: amount1, exitFee: exitFee1 } = claimLP1.logs[0].args;
      assertBNequal(amount1, lockedLP1[1]);

      const claimLP2 = await acceleratorVault.claimLP();
      const { amount: amount2, exitFee: exitFee2 } = claimLP2.logs[0].args;
      assertBNequal(amount2, lockedLP2[1]);

      const expectedLpAmount = amount1.sub(exitFee1).add(amount2.sub(exitFee2));
      const lpBalanceAfter = await pair.balanceOf(OWNER);
      assertBNequal(lpBalanceAfter.sub(lpBalanceBefore), expectedLpAmount);
    });
  });
});
