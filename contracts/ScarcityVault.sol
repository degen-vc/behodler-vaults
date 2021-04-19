// SPDX-License-Identifier: MIT
pragma solidity 0.7.1;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./facades/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract ScarcityVault is Ownable {
    using SafeMath for uint256;

    /** Emitted when purchaseLP() is called to track EYE amounts */
    event TokensTransferred(
        address from,
        address to,
        uint256 amount,
        uint256 percentageAmount
    );

    /** Emitted when purchaseLP() is called and LP tokens minted */
    event LPQueued(
        address holder,
        uint256 amount,
        uint256 scxTokenAmount,
        uint256 eyeTokenAmount,
        uint256 timestamp
    );

    /** Emitted when claimLP() is called */
    event LPClaimed(
        address holder,
        uint256 amount,
        uint256 timestamp,
        uint256 exitFee,
        bool claimed
    );

    struct LPbatch {
        uint256 amount;
        uint256 timestamp;
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
    mapping(address => uint256) public queueCounter;

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

    function setTreasury(address _treasury) external onlyOwner {
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

    function setParameters(
        uint32 duration,
        uint8 donationShare,
        uint8 purchaseFee
    ) public onlyOwner {
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

    function maxTokensToInvest() external view returns (uint256) {
        uint256 totalSCX = config.scxToken.balanceOf(address(this));
        if (totalSCX == 0) {
            return 0;
        }

        uint256 eyeMaxAllowed;
        (uint256 reserve1, uint256 reserve2, ) = config.tokenPair.getReserves();
        //eye<scx
        eyeMaxAllowed = config.uniswapRouter.quote(
            totalSCX,
            reserve2,
            reserve1
        );

        return eyeMaxAllowed;
    }

    function getLockedLP(address hodler, uint256 position)
        external
        view
        returns (
            address,
            uint256,
            uint256,
            bool
        )
    {
        LPbatch memory batch = lockedLP[hodler][position];
        return (hodler, batch.amount, batch.timestamp, batch.claimed);
    }

    function lockedLPLength(address hodler) external view returns (uint256) {
        return lockedLP[hodler].length;
    }

    function getStakeDuration() public view returns (uint256) {
        return forceUnlock ? 0 : config.stakeDuration;
    }

    function purchaseLPFor(address beneficiary, uint256 amount) public lock {
        require(amount > 0, "ScarcityVault: EYE required to mint LP");
        require(
            config.eyeToken.balanceOf(msg.sender) >= amount,
            "ScarcityVault: Not enough EYE tokens"
        );
        require(
            config.eyeToken.allowance(msg.sender, address(this)) >= amount,
            "ScarcityVault: Not enough EYE tokens allowance"
        );

        uint256 feeValue = amount.mul(config.purchaseFee).div(100);
        uint256 exchangeValue = amount.sub(feeValue);

        (uint256 reserve1, uint256 reserve2, ) = config.tokenPair.getReserves();

        uint256 scxRequired;
        //eye<scx
        scxRequired = config.uniswapRouter.quote(
            exchangeValue,
            reserve1,
            reserve2
        );

        uint256 balance = IERC20(config.scxToken).balanceOf(address(this));
        require(
            balance >= scxRequired,
            "ScarcityVault: insufficient SCX tokens in ScarcityVault"
        );

        address tokenPairAddress = address(config.tokenPair);
        require(
            config.scxToken.transfer(tokenPairAddress, scxRequired),
            "ScarcityVault: insufficient SCX tokens in ScarcityVault"
        );
        require(
            config.eyeToken.transferFrom(
                msg.sender,
                tokenPairAddress,
                exchangeValue
            ),
            "ScarcityVault: Not enough EYE tokens"
        );

        // EYE receiver is Eye vault here
        config.eyeToken.transferFrom(msg.sender, config.feeHodler, feeValue);

        uint256 liquidityCreated = config.tokenPair.mint(address(this));

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

        emit TokensTransferred(
            msg.sender,
            config.feeHodler,
            exchangeValue,
            feeValue
        );
    }

    //send EYE to match with SCX tokens in ScarcityVault
    function purchaseLP(uint256 amount) external {
        purchaseLPFor(msg.sender, amount);
    }

    function claimLP() external {
        uint256 next = queueCounter[msg.sender];
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
        uint256 donation = batch.amount.mul(config.donationShare).div(100);
        batch.claimed = true;
        emit LPClaimed(
            msg.sender,
            batch.amount,
            block.timestamp,
            donation,
            batch.claimed
        );
        require(
            config.tokenPair.transfer(address(0), donation),
            "ScarcityVault: donation transfer failed in LP claim."
        );
        require(
            config.tokenPair.transfer(msg.sender, batch.amount.sub(donation)),
            "ScarcityVault: transfer failed in LP claim."
        );
    }

    // Could not be canceled if activated
    function enableLPForceUnlock() external onlyOwner {
        forceUnlock = true;
    }

    function moveToTreasury(uint256 amount) external onlyOwner {
        require(treasury != address(0), "ScarcityVault: treasury must be set");
        require(
            config.scxToken.transfer(treasury, amount),
            "ScarcityVault: SCX amount exceeds balance"
        );
    }
}
