require('dotenv').config();

const AcceleratorVault = artifacts.require('AcceleratorVault');
const HodlerVault = artifacts.require('HodlerVault');
const Eye = artifacts.require('Eye');
const Scarcity = artifacts.require('Scarcity');
const UniswapFactory = artifacts.require('UniswapFactory');

const { 
  UNISWAP_FACTORY, 
  UNISWAP_ROUTER,
  WETH_KOVAN,
  UNISWAP_PAIR
} = process.env;

module.exports = async (deployer, network, accounts) => {
  const stakeDuration = 4;
  const donationShare = 0;
  const purchaseFee = 10;

  const placeholder = accounts[2];

  if (network === 'development') {
    return;
  }

  await deployer.deploy(AcceleratorVault);
  const acceleratorVault = await AcceleratorVault.deployed();
  pausePromise('AcceleratorVault');

  await deployer.deploy(HodlerVault);
  const hodlerVault = await HodlerVault.deployed();
  pausePromise('HodlerVault');

  await deployer.deploy(Eye);
  const eyeToken = await Eye.deployed();
  pausePromise('Eye');

  await deployer.deploy(Scarcity);
  const scarcityToken = await Scarcity.deployed();
  pausePromise('Scarcity');

  if (network === 'kovan') {
    const uniswapFactory = await UniswapFactory.at(UNISWAP_FACTORY);
    await uniswapFactory.createPair(WETH_KOVAN, osmToken.address);
    pausePromise('Create pair');

    uniswapPair = await uniswapFactory.getPair.call(WETH_KOVAN, osmToken.address);
    await deployer.deploy(PriceOracle, uniswapPair, osmToken.address, WETH_KOVAN);
    
    await acceleratorVault.seed(
      stakeDuration, 
      placeholder, 
      uniswapPair, 
      UNISWAP_ROUTER, 
      hodlerVault.address,
      donationShare,
      purchaseFee
    );

    await hodlerVault.seed(
      stakeDuration,
      placeholder,
      uniswapPair,
      UNISWAP_ROUTER
    );
  }
  
}

function pausePromise(message, durationInSeconds = 2) {
	return new Promise(function (resolve, error) {
		setTimeout(() => {
			console.log(message);
			return resolve();
		}, durationInSeconds * 1000);
	});
}