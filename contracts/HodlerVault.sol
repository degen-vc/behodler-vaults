// SPDX-License-Identifier: MIT
pragma solidity 0.7.1;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./facades/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

contract HodlerVault is Ownable {

    /** Emitted when purchaseLP() is called and LP tokens minted */
    event LPQueued(
        address hodler,
        uint amount,
        uint eth,
        uint eyeTokens,
        uint timeStamp
    );

    /** Emitted when claimLP() is called */
    event LPClaimed(
        address hodler,
        uint amount,
        uint timestamp,
        uint donation
    );

    struct LPbatch {
        uint amount;
        uint timestamp;
        bool claimed;
    }

    struct HodlerVaultConfig {
        IERC20 eyeToken;
        IERC20 scxToken;
        IUniswapV2Router02 uniswapRouter;
        IUniswapV2Pair tokenPair;
        uint32 stakeDuration;
        uint8 donationShare; //0-100
    }

    bool private locked;
    bool public forceUnlock;

    modifier lock {
        require(!locked, "HodlerVault: reentrancy violation");
        locked = true;
        _;
        locked = false;
    }

    HodlerVaultConfig public config;
    //Front end can loop through this and inspect if enough time has passed
    mapping(address => LPbatch[]) public lockedLP;
    mapping(address => uint) public queueCounter;

    receive() external payable {}

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

    function seed(
        uint32 duration,
        IERC20 scxToken,
        IERC20 eyeToken,
        address uniswapPair,
        address uniswapRouter
    ) public onlyOwner {
        config.eyeToken = eyeToken;
        config.scxToken = scxToken;
        config.uniswapRouter = IUniswapV2Router02(uniswapRouter);
        config.tokenPair = IUniswapV2Pair(uniswapPair);
        setParameters(duration, 0);
    }

    function setParameters(uint32 duration, uint8 donationShare)
        public
        onlyOwner
    {
        require(
            donationShare <= 100,
            "HodlerVault: donation share % between 0 and 100"
        );

        config.stakeDuration = duration * 1 days;
        config.donationShare = donationShare;
    }


    function purchaseLP(uint amount) public lock {
        require(amount > 0, "HodlerVault: OSM required to mint LP");
        require(config.eyeToken.balanceOf(msg.sender) >= amount, "HodlerVault: Not enough OSM tokens");
        require(config.eyeToken.allowance(msg.sender, address(this)) >= amount, "HodlerVault: Not enough OSM tokens allowance");

        (uint reserve1, uint reserve2, ) = config.tokenPair.getReserves();

        uint scxRequired;

        if (address(config.eyeToken) > address(config.scxToken)) {
            scxRequired = config.uniswapRouter.quote(
                amount,
                reserve2,
                reserve1
            );
        } else {
            scxRequired = config.uniswapRouter.quote(
                amount,
                reserve1,
                reserve2
            );
        }

        require(
            address(this).balance >= scxRequired,
            "HodlerVault: insufficient ETH on HodlerVault"
        );

        // IWETH(config.weth).deposit{ value: scxRequired }();
        address tokenPairAddress = address(config.tokenPair);
        config.scxToken.transfer(tokenPairAddress, scxRequired);
        config.eyeToken.transferFrom(
            msg.sender,
            tokenPairAddress,
            amount
        );

        uint liquidityCreated = config.tokenPair.mint(address(this));

        lockedLP[msg.sender].push(
            LPbatch({
                amount: liquidityCreated,
                timestamp: block.timestamp,
                claimed: false
            })
        );

        emit LPQueued(
            msg.sender,
            liquidityCreated,
            scxRequired,
            amount,
            block.timestamp
        );

    }

    //pops latest LP if older than period
    function claimLP() public {
        uint next = queueCounter[msg.sender];
        require(
            next < lockedLP[msg.sender].length,
            "HodlerVault: nothing to claim."
        );
        LPbatch storage batch = lockedLP[msg.sender][next];
        require(
            block.timestamp - batch.timestamp > getStakeDuration(),
            "HodlerVault: LP still locked."
        );
        next++;
        queueCounter[msg.sender] = next;
        uint donation = (config.donationShare * batch.amount) / 100;
        batch.claimed = true;
        emit LPClaimed(msg.sender, batch.amount, block.timestamp, donation);
        require(
            config.tokenPair.transfer(address(0), donation),
            "HodlerVault: donation transfer failed in LP claim."
        );
        require(
            config.tokenPair.transfer(msg.sender, batch.amount - donation),
            "HodlerVault: transfer failed in LP claim."
        );
    }

    // Could not be canceled if activated
    function enableLPForceUnlock() public onlyOwner {
        forceUnlock = true;
    }
}
