// SPDX-License-Identifier: MIT
pragma solidity 0.7.1;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./facades/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

contract ScarcityVault is Ownable {
  /** Emitted when purchaseLP() is called to track EYE amounts */
  event TokensTransferred(
      address from,
      address to,
      uint amount,
      uint percentageAmount
  );

  /** Emitted when purchaseLP() is called and LP tokens minted */
  event LPQueued(
      address holder,
      uint amount,
      uint scxTokenAmount,
      uint eyeTokenAmount,
      uint timestamp
  );

  /** Emitted when claimLP() is called */
  event LPClaimed(
      address holder,
      uint amount,
      uint timestamp,
      uint exitFee,
      bool claimed
  );

  struct LPbatch {
      uint amount;
      uint timestamp;
      bool claimed;
  }

  struct ScarcityVaultConfig {
      IERC20 scxToken;
      IERC20 eyeToken;
      IUniswapV2Router02 uniswapRouter;
      IUniswapV2Pair tokenPair;
      address feeHodler;
      uint32 stakeDuration;
      uint8 donationShare; //0-100
      uint8 purchaseFee; //0-100
  }

  address public treasury;

  bool public forceUnlock;
  bool private locked;

  modifier lock {
      require(!locked, "ScarcityVault: reentrancy violation");
      locked = true;
      _;
      locked = false;
  }

  ScarcityVaultConfig public config;

  mapping(address => LPbatch[]) public lockedLP;
  mapping(address => uint) public queueCounter;

  function seed(
      uint32 duration,
      IERC20 scxToken,
      IERC20 eyeToken,
      address uniswapPair,
      address uniswapRouter,
      address feeHodler,
      uint8 donationShare, // LP Token
      uint8 purchaseFee // ETH
  ) public onlyOwner {
      config.scxToken = scxToken;
      config.eyeToken = eyeToken;
      config.uniswapRouter = IUniswapV2Router02(uniswapRouter);
      config.tokenPair = IUniswapV2Pair(uniswapPair);
      setFeeHodlerAddress(feeHodler);
      setParameters(duration, donationShare, purchaseFee);
  }

  function setTreasury(address _treasury) public onlyOwner {
        require(
            _treasury != address(0),
            "ScarcityVault: treasury is zero address"
        );

        treasury = _treasury;
    }

  function setFeeHodlerAddress(address feeHodler) public onlyOwner {
      require(
          feeHodler != address(0),
          "ScarcityVault: fee receiver is zero address"
      );

      config.feeHodler = feeHodler;
  }

  function setParameters(uint32 duration, uint8 donationShare, uint8 purchaseFee)
      public
      onlyOwner
  {
      require(
          donationShare <= 100,
          "ScarcityVault: donation share % between 0 and 100"
      );
      require(
          purchaseFee <= 100,
          "ScarcityVault: purchase fee share % between 0 and 100"
      );

      config.stakeDuration = duration * 1 days;
      config.donationShare = donationShare;
      config.purchaseFee = purchaseFee;
  }

  function maxTokensToInvest() public view returns (uint) {
    uint totalSCX = config.scxToken.balanceOf(address(this));
    if (totalSCX == 0) {
        return 0;
    }

    uint eyeMaxAllowed;
    (uint reserve1, uint reserve2,) = config.tokenPair.getReserves();

    if (address(config.eyeToken) < address(config.scxToken)) {
        eyeMaxAllowed = config.uniswapRouter.quote(
            totalSCX,
            reserve2,
            reserve1
        );
    } else {
        eyeMaxAllowed = config.uniswapRouter.quote(
            totalSCX,
            reserve1,
            reserve2
        );
    }

    return eyeMaxAllowed;
  }

  function getLockedLP(address hodler, uint position)
      public
      view
      returns (
          address,
          uint,
          uint,
          bool
      )
  {
      LPbatch memory batch = lockedLP[hodler][position];
      return (hodler, batch.amount, batch.timestamp, batch.claimed);
  }

  function lockedLPLength(address hodler) public view returns (uint) {
      return lockedLP[hodler].length;
  }

  function getStakeDuration() public view returns (uint) {
      return forceUnlock ? 0 : config.stakeDuration;
  }

  function purchaseLPFor(address beneficiary, uint amount) public lock {
    require(amount > 0, "ScarcityVault: EYE required to mint LP");
    require(config.eyeToken.balanceOf(msg.sender) >= amount, "ScarcityVault: Not enough EYE tokens");
    require(config.eyeToken.allowance(msg.sender, address(this)) >= amount, "ScarcityVault: Not enough EYE tokens allowance");

    uint feeValue = (config.purchaseFee * amount) / 100;
    uint exchangeValue = amount - feeValue;

    (uint reserve1, uint reserve2, ) = config.tokenPair.getReserves();

    uint scxRequired;

    if (address(config.scxToken) < address(config.eyeToken)) {
        scxRequired = config.uniswapRouter.quote(
            exchangeValue,
            reserve2,
            reserve1
        );
    } else {
        scxRequired = config.uniswapRouter.quote(
            exchangeValue,
            reserve1,
            reserve2
        );
    }

    uint balance = IERC20(config.scxToken).balanceOf(address(this));
    require(
        balance >= scxRequired,
        "ScarcityVault: insufficient SCX tokens in ScarcityVault"
    );

    address tokenPairAddress = address(config.tokenPair);
    config.scxToken.transfer(tokenPairAddress, scxRequired);
    config.eyeToken.transferFrom(
        msg.sender,
        tokenPairAddress,
        exchangeValue
    );

    // EYE receiver is Eye vault here
    config.eyeToken.transferFrom(msg.sender, config.feeHodler, feeValue);

    uint liquidityCreated = config.tokenPair.mint(address(this));

    lockedLP[beneficiary].push(
        LPbatch({
            amount: liquidityCreated,
            timestamp: block.timestamp,
            claimed: false
        })
    );

    emit LPQueued(
        beneficiary,
        liquidityCreated,
        exchangeValue,
        scxRequired,
        block.timestamp
    );

    emit TokensTransferred(msg.sender, config.feeHodler, exchangeValue, feeValue);
  }

  //send EYE to match with SCX tokens in ScarcityVault
  function purchaseLP(uint amount) public {
      purchaseLPFor(msg.sender, amount);
  }

  function claimLP() public {
      uint next = queueCounter[msg.sender];
      require(
          next < lockedLP[msg.sender].length,
          "ScarcityVault: nothing to claim."
      );
      LPbatch storage batch = lockedLP[msg.sender][next];
      require(
          block.timestamp - batch.timestamp > getStakeDuration(),
          "ScarcityVault: LP still locked."
      );
      next++;
      queueCounter[msg.sender] = next;
      uint donation = (config.donationShare * batch.amount) / 100;
      batch.claimed = true;
      emit LPClaimed(msg.sender, batch.amount, block.timestamp, donation, batch.claimed);
      require(
          config.tokenPair.transfer(address(0), donation),
          "ScarcityVault: donation transfer failed in LP claim."
      );
      require(
          config.tokenPair.transfer(msg.sender, batch.amount - donation),
          "ScarcityVault: transfer failed in LP claim."
      );
  }

  // Could not be canceled if activated
  function enableLPForceUnlock() public onlyOwner {
      forceUnlock = true;
  }

  function moveToTreasury(uint amount) public onlyOwner {
        require(treasury != address(0),'ScarcityVault: treasury must be set');
        require(
            amount <= config.scxToken.balanceOf(address(this)),
            "ScarcityVault: SCX amount exceeds balance"
        );
        
        config.scxToken.transfer(treasury, amount);
    }
}