require('dotenv').config();

const AcceleratorVault = artifacts.require('AcceleratorVault');
const HodlerVault = artifacts.require('HodlerVault');
const UniswapFactory = artifacts.require('UniswapFactory');
const Eye = artifacts.require('ERC20Mock');
const Scarcity = artifacts.require('ERC20Mock');

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
  const totalSupply = '10000000000000000000000000';

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

  await deployer.deploy(Eye, 'Behodler.io', 'EYE', totalSupply);
  const eyeToken = await Eye.deployed();
  pausePromise('Eye');

  await deployer.deploy(Scarcity, 'Scarcity', 'SCX', totalSupply);
  const scxToken = await Scarcity.deployed();
  pausePromise('Scarcity');

  if (network === 'kovan') {
    const uniswapFactory = await UniswapFactory.at(UNISWAP_FACTORY);
    await uniswapFactory.createPair(eyeToken.address, scxToken.address);
    pausePromise('Create pair');

    uniswapPair = await uniswapFactory.getPair.call(eyeToken.address, scxToken.address);
    
    await acceleratorVault.seed(
      stakeDuration, 
      scxToken.address,
      eyeToken.address, 
      uniswapPair, 
      UNISWAP_ROUTER, 
      hodlerVault.address,
      donationShare,
      purchaseFee
    );

    await hodlerVault.seed(
      stakeDuration,
      scxToken.address,
      eyeToken.address,
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