// SPDX-License-Identifier: MIT
pragma solidity 0.7.1;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./facades/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

contract AcceleratorVault is Ownable {
    /** Emitted when purchaseLP() is called to track ETH amounts */
    event EthereumDeposited(
        address from,
        address to,
        uint amount,
        uint percentageAmount
    );

    /** Emitted when purchaseLP() is called and LP tokens minted */
    event LPQueued(
        address holder,
        uint amount,
        uint eth,
        uint scxToken,
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
        address holder;
        uint amount;
        uint timestamp;
        bool claimed;
    }

    struct AcceleratorVaultConfig {
        IERC20 scxToken;
        IERC20 eyeToken;
        IUniswapV2Router02 uniswapRouter;
        IUniswapV2Pair tokenPair;
        address feeHodler;
        uint32 stakeDuration;
        uint8 donationShare; //0-100
        uint8 purchaseFee; //0-100
    }

    bool public forceUnlock;
    bool private locked;

    modifier lock {
        require(!locked, "AcceleratorVault: reentrancy violation");
        locked = true;
        _;
        locked = false;
    }

    AcceleratorVaultConfig public config;

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

    function getStakeDuration() public view returns (uint) {
        return forceUnlock ? 0 : config.stakeDuration;
    }

    // Could not be canceled if activated
    function enableLPForceUnlock() public onlyOwner {
        forceUnlock = true;
    }

    function setFeeHodlerAddress(address feeHodler) public onlyOwner {
        require(
            feeHodler != address(0),
            "AcceleratorVault: eth receiver is zero address"
        );

        config.feeHodler = feeHodler;
    }

    function setParameters(uint32 duration, uint8 donationShare, uint8 purchaseFee)
        public
        onlyOwner
    {
        require(
            donationShare <= 100,
            "AcceleratorVault: donation share % between 0 and 100"
        );
        require(
            purchaseFee <= 100,
            "AcceleratorVault: purchase fee share % between 0 and 100"
        );

        config.stakeDuration = duration * 1 days;
        config.donationShare = donationShare;
        config.purchaseFee = purchaseFee;
    }

    function purchaseLPFor(address beneficiary, uint amount) public lock {
        require(amount > 0, "AcceleratorVault: ETH required to mint SCX / EYE LP");
        require(config.scxToken.balanceOf(msg.sender) >= amount, "AcceleratorVault: Not enough SCX tokens");
        require(config.scxToken.allowance(msg.sender, address(this)) >= amount, "AcceleratorVault: Not enough SCX tokens allowance");

        uint feeValue = (config.purchaseFee * amount) / 100;
        uint exchangeValue = amount - feeValue;

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
            "AcceleratorVault: insufficient EYE tokens in AcceleratorVault"
        );

        // IWETH(config.weth).deposit{ value: exchangeValue }();
        address tokenPairAddress = address(config.tokenPair);
        config.eyeToken.transfer(tokenPairAddress, exchangeValue);
        config.scxToken.transferFrom(
            msg.sender,
            tokenPairAddress,
            eyeRequired
        );
        //ETH receiver is hodler vault here
        config.scxToken.transfer(config.feeHodler, feeValue);

        uint liquidityCreated = config.tokenPair.mint(address(this));

        lockedLP[beneficiary].push(
            LPbatch({
                holder: beneficiary,
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

        emit EthereumDeposited(msg.sender, config.feeHodler, exchangeValue, feeValue);
    }

    //send SCX to match with EYE tokens in AcceleratorVault
    function purchaseLP(uint amount) public {
        purchaseLPFor(msg.sender, amount);
    }

    function claimLP() public {
        uint next = queueCounter[msg.sender];
        require(
            next < lockedLP[msg.sender].length,
            "AcceleratorVault: nothing to claim."
        );
        LPbatch storage batch = lockedLP[msg.sender][next];
        require(
            block.timestamp - batch.timestamp > getStakeDuration(),
            "AcceleratorVault: LP still locked."
        );
        next++;
        queueCounter[msg.sender] = next;
        uint donation = (config.donationShare * batch.amount) / 100;
        batch.claimed = true;
        emit LPClaimed(msg.sender, batch.amount, block.timestamp, donation, batch.claimed);
        require(
            config.tokenPair.transfer(address(0), donation),
            "AcceleratorVault: donation transfer failed in LP claim."
        );
        require(
            config.tokenPair.transfer(batch.holder, batch.amount - donation),
            "AcceleratorVault: transfer failed in LP claim."
        );
    }

    function lockedLPLength(address holder) public view returns (uint) {
        return lockedLP[holder].length;
    }

    function getLockedLP(address holder, uint position)
        public
        view
        returns (
            address,
            uint,
            uint,
            bool
        )
    {
        LPbatch memory batch = lockedLP[holder][position];
        return (batch.holder, batch.amount, batch.timestamp, batch.claimed);
    }
}
