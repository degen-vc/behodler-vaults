// SPDX-License-Identifier: MIT
pragma solidity 0.7.1;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./facades/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import '@openzeppelin/contracts/math/SafeMath.sol';

contract EyeVault is Ownable {
    using SafeMath for uint;

    /** Emitted when purchaseLP() is called to track SCX amounts */
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

    struct EyeVaultConfig {
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
        require(!locked, "EyeVault: reentrancy violation");
        locked = true;
        _;
        locked = false;
    }

    EyeVaultConfig public config;

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
    ) external onlyOwner {
        config.scxToken = scxToken;
        config.eyeToken = eyeToken;
        config.uniswapRouter = IUniswapV2Router02(uniswapRouter);
        config.tokenPair = IUniswapV2Pair(uniswapPair);
        setFeeHodlerAddress(feeHodler);
        setParameters(duration, donationShare, purchaseFee);
    }

    function maxTokensToInvest() external view returns (uint) {
    uint totalEYE = config.eyeToken.balanceOf(address(this));
    if (totalEYE == 0) {
        return 0;
    }

    uint scxMaxAllowed;
    (uint reserve1, uint reserve2,) = config.tokenPair.getReserves();

    if (address(config.scxToken) < address(config.eyeToken)) {
        scxMaxAllowed = config.uniswapRouter.quote(
            totalEYE,
            reserve2,
            reserve1
        );
    } else {
        scxMaxAllowed = config.uniswapRouter.quote(
            totalEYE,
            reserve1,
            reserve2
        );
    }

    return scxMaxAllowed;
  }

    function getLockedLP(address holder, uint position)
        external
        view
        returns (
            address,
            uint,
            uint,
            bool
        )
    {
        LPbatch memory batch = lockedLP[holder][position];
        return (holder, batch.amount, batch.timestamp, batch.claimed);
    }

    function lockedLPLength(address holder) external view returns (uint) {
        return lockedLP[holder].length;
    }

    function getStakeDuration() public view returns (uint) {
        return forceUnlock ? 0 : config.stakeDuration;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(
            _treasury != address(0),
            "EyeVault: treasury is zero address"
        );

        treasury = _treasury;
    }

    function setFeeHodlerAddress(address feeHodler) public onlyOwner {
        require(
            feeHodler != address(0),
            "EyeVault: fee receiver is zero address"
        );

        config.feeHodler = feeHodler;
    }

    function setParameters(uint32 duration, uint8 donationShare, uint8 purchaseFee)
        public
        onlyOwner
    {
        require(
            donationShare <= 100,
            "EyeVault: donation share % between 0 and 100"
        );
        require(
            purchaseFee <= 100,
            "EyeVault: purchase fee share % between 0 and 100"
        );

        config.stakeDuration = duration * 1 days;
        config.donationShare = donationShare;
        config.purchaseFee = purchaseFee;
    }

    function purchaseLPFor(address beneficiary, uint amount) public lock {
        require(amount > 0, "EyeVault: SCX required to mint LP");
        require(config.scxToken.balanceOf(msg.sender) >= amount, "EyeVault: Not enough SCX tokens");
        require(config.scxToken.allowance(msg.sender, address(this)) >= amount, "EyeVault: Not enough SCX tokens allowance");

        uint feeValue = amount.mul(config.purchaseFee).div(100);
        uint exchangeValue = amount.sub(feeValue);

        (uint reserve1, uint reserve2, ) = config.tokenPair.getReserves();

        uint eyeRequired;

        if (address(config.scxToken) < address(config.eyeToken)) {
            eyeRequired = config.uniswapRouter.quote(
                exchangeValue,
                reserve2,
                reserve1
            );
        } else {
            eyeRequired = config.uniswapRouter.quote(
                exchangeValue,
                reserve1,
                reserve2
            );
        }

        uint balance = IERC20(config.eyeToken).balanceOf(address(this));
        require(
            balance >= eyeRequired,
            "EyeVault: insufficient EYE tokens in EyeVault"
        );

        address tokenPairAddress = address(config.tokenPair);
        config.eyeToken.transfer(tokenPairAddress, eyeRequired);
        config.scxToken.transferFrom(
            msg.sender,
            tokenPairAddress,
            exchangeValue
        );
        // SCX receiver is a Scarcity vault here
        config.scxToken.transferFrom(msg.sender, config.feeHodler, feeValue);

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
            eyeRequired,
            block.timestamp
        );

        emit TokensTransferred(msg.sender, config.feeHodler, exchangeValue, feeValue);
    }

    //send SCX to match with EYE tokens in EyeVault
    function purchaseLP(uint amount) external {
        purchaseLPFor(msg.sender, amount);
    }

    function claimLP() external {
        uint next = queueCounter[msg.sender];
        require(
            next < lockedLP[msg.sender].length,
            "EyeVault: nothing to claim."
        );
        LPbatch storage batch = lockedLP[msg.sender][next];
        require(
            block.timestamp - batch.timestamp > getStakeDuration(),
            "EyeVault: LP still locked."
        );
        next++;
        queueCounter[msg.sender] = next;
        uint donation = batch.amount.mul(config.donationShare).div(100);
        batch.claimed = true;
        emit LPClaimed(msg.sender, batch.amount, block.timestamp, donation, batch.claimed);
        require(
            config.tokenPair.transfer(address(0), donation),
            "EyeVault: donation transfer failed in LP claim."
        );
        require(
            config.tokenPair.transfer(msg.sender, batch.amount.sub(donation)),
            "EyeVault: transfer failed in LP claim."
        );
    }

    // Could not be canceled if activated
    function enableLPForceUnlock() external onlyOwner {
        forceUnlock = true;
    }

    function moveToTreasury(uint amount) external onlyOwner {
        require(treasury != address(0),'EyeVault: treasury must be set');
        require(
            amount <= config.eyeToken.balanceOf(address(this)),
            "EyeVault: EYE amount exceeds balance"
        );
        
        config.eyeToken.transfer(treasury, amount);
    }
}
