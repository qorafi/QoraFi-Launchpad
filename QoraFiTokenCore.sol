// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISecurityManager} from "../interfaces/SecurityInterfaces.sol";

// Minimal interfaces needed (no separate files)
interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/**
 * @title QoraFiTokenCore
 * @notice Core trading logic for QoraFi token with bonding curve
 */
contract QoraFiTokenCore is ERC20, ReentrancyGuard {
    
    // --- Security Manager ---
    ISecurityManager public immutable securityManager;
    
    // --- Enums and Structs ---
    enum TokenState { Active, Succeeded, Migrated }
    enum CurveType { ConstantProductV1 }
    
    struct BuyerInfo {
        uint256 ethContributed;
        uint256 tokensOwed;
        bool initialTokensClaimed;
        uint256 immediateTokensReceived;
        uint256 vestedTokensClaimed;
        bool refundClaimed;
    }
    
    struct ConstructorParams {
        string name;
        string symbol;
        address creator;
        address treasury;
        address dexTreasury;
        address uniV2Router;
        uint256 totalSupply;
        uint256 virtualTokenReserves;
        uint256 virtualCollateralReserves;
        uint256 feeBasisPoints;
        uint256 dexFeeBasisPoints;
        uint256 migrationFeeFixed;
        uint256 poolCreationFee;
        uint256 mcLowerLimit;
        uint256 mcUpperLimit;
        uint256 tokensMigrationThreshold;
        uint256 deadlineDuration;
        uint256 launchTime;
        address securityManager;
    }
    
    // --- Constants ---
    CurveType public constant curveType = CurveType.ConstantProductV1;
    uint256 public constant MAX_BPS = 10_000;
    uint256 internal constant VESTING_DURATION = 7 days;
    uint256 internal constant DAILY_VESTING_DURATION = 1 days;
    uint256 public constant DEADLINE_24H = 24 hours;
    uint256 public constant DEADLINE_48H = 48 hours;
    uint256 public constant DEADLINE_72H = 72 hours;

    // --- Core Token Parameters ---
    uint256 public initialTokenSupply;
    uint256 public virtualTokenReserves;
    uint256 public virtualCollateralReserves;
    uint256 public immutable virtualCollateralReservesInitial;

    // --- Fee Structure ---
    uint256 public immutable feeBPS;
    uint256 public immutable dexFeeBPS;

    // --- Market Cap Limits ---
    uint256 public immutable mcLowerLimit;
    uint256 public immutable mcUpperLimit;
    uint256 public immutable tokensMigrationThreshold;

    // --- Migration Fees ---
    uint256 public immutable fixedMigrationFee;
    uint256 public immutable poolCreationFee;

    // --- Key Addresses ---
    address public immutable creator;
    address public immutable pair;
    address public immutable treasury;
    address public immutable dexTreasury;
    address public immutable factory;

    // --- Trading Controls ---
    bool public tradingStopped;
    bool public sendingToPairNotAllowed = true;
    
    // --- Migration and Vesting State ---
    TokenState public currentState = TokenState.Active;
    uint256 public migrationTimestamp;
    uint256 public totalEthRaised;
    uint256 public launchDeadline;
    uint256 public immutable deadlineDuration;
    uint256 public immutable launchTime;
    bool public saleCancelled;

    // --- Uniswap Integration ---
    IUniswapV2Router02 public immutable uniswapV2Router;

    // --- Buyer Tracking ---
    mapping(address => BuyerInfo) internal _buyers;
    address[] public buyersList;

    // --- Events ---
    event TokensPurchased(address indexed buyer, uint256 ethAmount, uint256 tokenAmount, uint256 newMarketCap);
    event SaleSucceeded(uint256 finalMarketCap, uint256 totalEthRaised);
    event TokensMigrated(address indexed uniswapPair, uint256 liquidityTokens, uint256 liquidityEth);
    event StateChanged(TokenState indexed oldState, TokenState indexed newState);
    event SaleCancelled(uint256 timestamp, string reason);
    event LaunchScheduled(uint256 launchTime, uint256 deadline);
    event LaunchActivated(uint256 timestamp);

    // --- Custom Errors ---
    error SaleNotActive();
    error SaleNotSucceeded();
    error SlippageCheckFailed();
    error InvalidParameters();
    error AlreadyMigrated();
    error DeadlineExpired();
    error SaleCancelledError();
    error SaleNotCancelled();
    error InvalidState();
    error TradingStopped();
    error OnlyFactory();
    error InsufficientTokenReserves();
    error NotEnoughtETHToBuyTokens();
    error FailedToSendETH();
    error MarketcapThresholdReached();
    error SendingToPairIsNotAllowedBeforeMigration();
    error LaunchNotStarted();

    // --- Modifiers ---
    modifier buyChecks() {
        if (block.timestamp < launchTime) revert LaunchNotStarted();
        if (tradingStopped) revert TradingStopped();
        if (currentState != TokenState.Active) revert SaleNotActive();
        _;
        _checkMcLower();
        _checkMcUpperLimit();
    }

    modifier withSecurity(uint256 amount) {
        securityManager.preDepositCheck(msg.sender, amount);
        _;
        securityManager.postDepositUpdate(msg.sender, amount);
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier notCancelled() {
        if (saleCancelled) revert SaleCancelledError();
        _;
    }

    /**
     * @notice Constructor - Initialize QoraFi token with all parameters
     */
    constructor(ConstructorParams memory _params) ERC20(_params.name, _params.symbol) {
        _mint(address(this), _params.totalSupply);

        initialTokenSupply = _params.totalSupply;
        virtualCollateralReserves = _params.virtualCollateralReserves;
        virtualCollateralReservesInitial = _params.virtualCollateralReserves;
        virtualTokenReserves = _params.virtualTokenReserves;

        creator = _params.creator;
        feeBPS = _params.feeBasisPoints;
        dexFeeBPS = _params.dexFeeBasisPoints;
        treasury = _params.treasury;
        dexTreasury = _params.dexTreasury;
        fixedMigrationFee = _params.migrationFeeFixed;
        poolCreationFee = _params.poolCreationFee;
        mcLowerLimit = _params.mcLowerLimit;
        mcUpperLimit = _params.mcUpperLimit;
        tokensMigrationThreshold = _params.tokensMigrationThreshold;

        // Set launch time and deadline
        launchTime = _params.launchTime;
        deadlineDuration = _params.deadlineDuration;
        require(deadlineDuration == DEADLINE_24H || deadlineDuration == DEADLINE_48H || deadlineDuration == DEADLINE_72H, "Invalid deadline");
        require(_params.launchTime >= block.timestamp, "Launch time cannot be in the past");
        launchDeadline = _params.launchTime + deadlineDuration;

        uniswapV2Router = IUniswapV2Router02(_params.uniV2Router);
        factory = msg.sender;
        securityManager = ISecurityManager(_params.securityManager);
        
        // Pre-calculate pair address
        (address token0, address token1) = address(this) < uniswapV2Router.WETH()
            ? (address(this), uniswapV2Router.WETH())
            : (uniswapV2Router.WETH(), address(this));

        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(uniswapV2Router.factory()),
                            keccak256(abi.encodePacked(token0, token1)),
                            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
                        )
                    )
                )
            )
        );
        
        emit LaunchScheduled(_params.launchTime, launchDeadline);
    }

    // --- Trading Functions ---

    /**
     * @notice Buy exact amount of tokens for ETH
     */
    function buyExactOut(
        address _buyer,
        uint256 _tokenAmount,
        uint256 _maxCollateralAmount
    ) external payable onlyFactory buyChecks notCancelled 
      withSecurity(msg.value) 
      returns (uint256 collateralToPayWithFee, uint256 helioFee, uint256 dexFee) {
        _checkDeadline();
        
        if (balanceOf(address(this)) <= _tokenAmount) revert InsufficientTokenReserves();

        uint256 collateralToSpend = (_tokenAmount * virtualCollateralReserves) / (virtualTokenReserves - _tokenAmount);
        (helioFee, dexFee) = _calculateFee(collateralToSpend);
        collateralToPayWithFee = collateralToSpend + helioFee + dexFee;

        if (collateralToPayWithFee > _maxCollateralAmount) revert SlippageCheckFailed();
        
        _transferCollateral(treasury, helioFee);
        _transferCollateral(dexTreasury, dexFee);
        _updateBuyerInfo(_buyer, msg.value, _tokenAmount);

        virtualTokenReserves -= _tokenAmount;
        virtualCollateralReserves += collateralToSpend;
        totalEthRaised += collateralToSpend;

        uint256 refund;
        if (msg.value > collateralToPayWithFee) {
            refund = msg.value - collateralToPayWithFee;
            _transferCollateral(_buyer, refund);
        } else if (msg.value < collateralToPayWithFee) {
            revert NotEnoughtETHToBuyTokens();
        }

        emit TokensPurchased(_buyer, collateralToSpend, _tokenAmount, getMarketCap());
        
        if (getMarketCap() >= mcUpperLimit) {
            _transitionToSucceeded();
        }
    }

    /**
     * @notice Buy tokens with exact ETH amount
     */
    function buyExactIn(
        address _buyer,
        uint256 _amountOutMin
    ) external payable onlyFactory buyChecks notCancelled 
      withSecurity(msg.value) 
      returns (uint256 collateralToPayWithFee, uint256 helioFee, uint256 dexFee) {
        _checkDeadline();
        
        collateralToPayWithFee = msg.value;
        (helioFee, dexFee) = _calculateFee(collateralToPayWithFee);
        uint256 collateralToSpendMinusFee = collateralToPayWithFee - helioFee - dexFee;

        _transferCollateral(treasury, helioFee);
        _transferCollateral(dexTreasury, dexFee);

        uint256 tokensOut = (collateralToSpendMinusFee * virtualTokenReserves) /
            (virtualCollateralReserves + collateralToSpendMinusFee);

        if (tokensOut < _amountOutMin) revert SlippageCheckFailed();
        if (balanceOf(address(this)) <= tokensOut) revert InsufficientTokenReserves();

        _updateBuyerInfo(_buyer, msg.value, tokensOut);

        virtualTokenReserves -= tokensOut;
        virtualCollateralReserves += collateralToSpendMinusFee;
        totalEthRaised += collateralToSpendMinusFee;

        emit TokensPurchased(_buyer, collateralToSpendMinusFee, tokensOut, getMarketCap());
        
        if (getMarketCap() >= mcUpperLimit) {
            _transitionToSucceeded();
        }
    }

    /**
     * @notice Simple buy function for factory compatibility
     */
    function buy(address _buyer) external payable onlyFactory {
        this.buyExactIn{value: msg.value}(_buyer, 0);
    }

    // --- Deadline Functions ---

    /**
     * @notice Cancel sale manually (factory only)
     */
    function cancelSale() external onlyFactory {
        if (currentState == TokenState.Migrated) revert AlreadyMigrated();
        saleCancelled = true;
        emit SaleCancelled(block.timestamp, "Manual cancellation");
    }

    /**
     * @notice Check deadline and auto-cancel if expired
     */
    function _checkDeadline() internal {
        if (block.timestamp > launchDeadline && currentState != TokenState.Succeeded && currentState != TokenState.Migrated) {
            saleCancelled = true;
            emit SaleCancelled(block.timestamp, "Deadline expired");
            revert DeadlineExpired();
        }
    }
    
    /**
     * @notice Activate launch manually if not auto-activated
     */
    function activateLaunch() external {
        require(block.timestamp >= launchTime, "Launch time not reached");
        emit LaunchActivated(block.timestamp);
    }

    /**
     * @notice Manual deadline check
     */
    function checkAndCancelIfExpired() external {
        _checkDeadline();
    }

    // --- Migration Function ---
    
    function migrate() external onlyFactory returns (uint256 tokensToMigrate, uint256 tokensToBurn, uint256 collateralAmount) {
        if (currentState != TokenState.Succeeded) revert SaleNotSucceeded();
        if (saleCancelled) revert SaleCancelledError();
        
        sendingToPairNotAllowed = false;
        
        uint256 tokensRemaining = balanceOf(address(this));
        tokensToMigrate = tokensRemaining * 80 / 100; // 80% to LP
        tokensToBurn = tokensRemaining - tokensToMigrate;
        collateralAmount = address(this).balance - fixedMigrationFee - poolCreationFee;
        
        _burn(address(this), tokensToBurn);
        
        migrationTimestamp = block.timestamp;
        currentState = TokenState.Migrated;
        
        emit TokensMigrated(pair, tokensToMigrate, collateralAmount);
        emit StateChanged(TokenState.Succeeded, TokenState.Migrated);
    }

    // --- Internal Helper Functions ---

    function _updateBuyerInfo(address _buyer, uint256 _ethAmount, uint256 _tokenAmount) internal {
        BuyerInfo storage buyerInfo = _buyers[_buyer];
        if (buyerInfo.ethContributed == 0) {
            buyersList.push(_buyer);
        }
        buyerInfo.ethContributed += _ethAmount;
        buyerInfo.tokensOwed += _tokenAmount;
    }

    function _transitionToSucceeded() internal {
        TokenState oldState = currentState;
        currentState = TokenState.Succeeded;
        emit SaleSucceeded(getMarketCap(), totalEthRaised);
        emit StateChanged(oldState, TokenState.Succeeded);
    }

    function _calculateFee(uint256 _amount) internal view returns (uint256 treasuryFee, uint256 dexFee) {
        uint256 totalFee = (_amount * feeBPS) / MAX_BPS;
        dexFee = (totalFee * dexFeeBPS) / MAX_BPS;
        treasuryFee = totalFee - dexFee;
    }

    function _transferCollateral(address _to, uint256 _amount) internal {
        if (_amount > 0) {
            (bool sent, ) = _to.call{value: _amount}("");
            if (!sent) revert FailedToSendETH();
        }
    }

    function _checkMcUpperLimit() internal view {
        uint256 mc = getMarketCap();
        if (mc > mcUpperLimit) revert MarketcapThresholdReached();
    }

    function _checkMcLower() internal {
        uint256 mc = getMarketCap();
        if (mc > mcLowerLimit) {
            tradingStopped = true;
        }
    }

    // --- View Functions ---

    function getMarketCap() public view returns (uint256) {
        if (virtualTokenReserves == 0) return 0;
        uint256 mc = (virtualCollateralReserves * 10 ** 18 * totalSupply()) / virtualTokenReserves;
        return mc / 10 ** 18;
    }

    function getState() external view returns (TokenState) {
        return currentState;
    }

    function getBuyerInfo(address _buyer) external view returns (BuyerInfo memory) {
        return _buyers[_buyer];
    }

    function buyers(address _buyer) external view returns (BuyerInfo memory) {
        return _buyers[_buyer];
    }

    function getTotalEthRaised() external view returns (uint256) {
        return totalEthRaised;
    }

    function hasSaleSucceeded() external view returns (bool) {
        return currentState == TokenState.Succeeded || currentState == TokenState.Migrated;
    }

    function getUniswapPair() external view returns (address) {
        return pair;
    }

    function getBondingCurveParams() external view returns (uint256, uint256, uint256) {
        return (virtualTokenReserves, virtualCollateralReserves, mcUpperLimit);
    }

    function getDeadlineInfo() external view returns (uint256 deadline, uint256 timeRemaining, bool isExpired, bool isCancelled) {
        deadline = launchDeadline;
        timeRemaining = block.timestamp >= launchDeadline ? 0 : launchDeadline - block.timestamp;
        isExpired = block.timestamp > launchDeadline;
        isCancelled = saleCancelled;
    }

    function getLaunchInfo() external view returns (
        uint256 scheduledLaunchTime,
        uint256 timeUntilLaunch,
        bool hasLaunched,
        uint256 deadline,
        bool isActive
    ) {
        scheduledLaunchTime = launchTime;
        timeUntilLaunch = block.timestamp >= launchTime ? 0 : launchTime - block.timestamp;
        hasLaunched = block.timestamp >= launchTime;
        deadline = launchDeadline;
        isActive = hasLaunched && !saleCancelled && currentState == TokenState.Active;
    }

    function getBuyersList() external view returns (address[] memory) {
        return buyersList;
    }

    function getBuyersCount() external view returns (uint256) {
        return buyersList.length;
    }

    function getTokensForEth(uint256 _ethAmount) external view returns (uint256, uint256) {
        uint256 fee = _ethAmount * feeBPS / MAX_BPS;
        uint256 netAmount = _ethAmount - fee;
        
        if (virtualCollateralReserves == 0 || virtualTokenReserves == 0) return (0, 0);
        
        uint256 tokensOut = (netAmount * virtualTokenReserves) / (virtualCollateralReserves + netAmount);
        return (tokensOut, getMarketCap());
    }

    // --- Transfer restrictions ---
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == pair && sendingToPairNotAllowed) revert SendingToPairIsNotAllowedBeforeMigration();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (to == pair && sendingToPairNotAllowed) revert SendingToPairIsNotAllowedBeforeMigration();
        return super.transferFrom(from, to, amount);
    }

    // --- Security View Functions ---
    
    function canUserDeposit(address user, uint256 amount) external view returns (bool canDeposit, string memory reason) {
        return securityManager.canUserDeposit(user, amount);
    }
    
    function getUserStatistics(address user) external view returns (uint256 depositCount, uint256 totalDeposited, uint256 lastDepositBlockNumber, bool canDeposit) {
        return securityManager.getUserStatistics(user);
    }
}