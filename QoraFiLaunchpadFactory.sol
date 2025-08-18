// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IQoraFiToken} from "../interfaces/IQoraFiToken.sol";
import {IQoraFiLaunchpadFactory} from "../interfaces/IQoraFiLaunchpadFactory.sol";
import {ISecurityManager} from "../interfaces/SecurityInterfaces.sol";
import {LaunchpadHelpers} from "../libraries/LaunchpadHelpers.sol";

// Import the self-contained QoraFiToken
import {QoraFiTokenCore} from "./QoraFiTokenCore.sol";
import {QoraFiLaunchpadVesting} from "./QoraFiLaunchpadVesting.sol";

/**
 * @title QoraFiLaunchpadFactory
 * @notice Factory for deploying self-contained QoraFi tokens with deadline system
 * @dev Works with self-contained QoraFiToken (no separate interface imports)
 */
contract QoraFiLaunchpadFactory is Ownable, ReentrancyGuard, IQoraFiLaunchpadFactory {
    using LaunchpadHelpers for *;
    
    // --- Security Manager ---
    ISecurityManager public immutable securityManager;
    
    // --- State Variables ---
    address public treasury;
    address public dexTreasury;
    address public signer;
    uint256 public launchFee;
    
    // Default parameters for token template
    address public immutable uniV2Router;
    uint256 public defaultTotalSupply;
    uint256 public defaultVirtualTokenReserves;
    uint256 public defaultVirtualCollateralReserves;
    uint256 public defaultFeeBasisPoints;
    uint256 public defaultDexFeeBasisPoints;
    uint256 public defaultMigrationFeeFixed;
    uint256 public defaultPoolCreationFee;
    uint256 public defaultMcLowerLimit;
    uint256 public defaultMcUpperLimit;
    uint256 public defaultTokensMigrationThreshold;
    
    // Registry of deployed tokens
    mapping(address => bool) public isDeployedToken;
    address[] public deployedTokens;
    
    // Signature replay protection
    mapping(bytes32 => bool) public usedSignatures;
    
    // Access control for migration
    mapping(address => bool) public canMigrate;

    // --- Events (defined in interface) ---
    event TokenLaunchScheduled(address indexed token, uint256 launchTime, uint256 deadline);
    event EmergencyTransactionProposed(bytes32 indexed txHash, address indexed proposer, uint256 executeAfter);
    event EmergencyTransactionExecuted(bytes32 indexed txHash, bool success);
    event EmergencyTransactionCancelled(bytes32 indexed txHash);

    // --- Errors (defined in interface) ---

    /**
     * @notice Constructor to initialize the factory
     */
    constructor(
        address _initialOwner,
        address _treasury,
        address _dexTreasury,
        address _signer,
        uint256 _launchFee,
        address _uniV2Router,
        uint256 _defaultTotalSupply,
        uint256 _defaultVirtualTokenReserves,
        uint256 _defaultVirtualCollateralReserves,
        uint256 _defaultFeeBasisPoints,
        uint256 _defaultDexFeeBasisPoints,
        uint256 _defaultMigrationFeeFixed,
        uint256 _defaultPoolCreationFee,
        uint256 _defaultMcLowerLimit,
        uint256 _defaultMcUpperLimit,
        uint256 _defaultTokensMigrationThreshold,
        address _securityManager
    ) Ownable(_initialOwner) {
        // Basic validation
        require(_treasury != address(0) && _dexTreasury != address(0) && _signer != address(0) && _uniV2Router != address(0), "Invalid address");
        require(_securityManager != address(0), "Invalid security manager");
        require(_defaultTotalSupply > 0 && _defaultMcUpperLimit > 0, "Invalid parameters");
        require(_defaultFeeBasisPoints <= 10000 && _defaultDexFeeBasisPoints <= 10000, "Invalid fee BPS");
        
        treasury = _treasury;
        dexTreasury = _dexTreasury;
        signer = _signer;
        launchFee = _launchFee;
        uniV2Router = _uniV2Router;
        securityManager = ISecurityManager(_securityManager);
        
        // Set default parameters
        defaultTotalSupply = _defaultTotalSupply;
        defaultVirtualTokenReserves = _defaultVirtualTokenReserves;
        defaultVirtualCollateralReserves = _defaultVirtualCollateralReserves;
        defaultFeeBasisPoints = _defaultFeeBasisPoints;
        defaultDexFeeBasisPoints = _defaultDexFeeBasisPoints;
        defaultMigrationFeeFixed = _defaultMigrationFeeFixed;
        defaultPoolCreationFee = _defaultPoolCreationFee;
        defaultMcLowerLimit = _defaultMcLowerLimit;
        defaultMcUpperLimit = _defaultMcUpperLimit;
        defaultTokensMigrationThreshold = _defaultTokensMigrationThreshold;
        
        // Owner can migrate tokens by default
        canMigrate[_initialOwner] = true;
    }

    // --- Admin Functions ---
    
    function setLaunchFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = launchFee;
        launchFee = _newFee;
        emit LaunchFeeUpdated(oldFee, _newFee);
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Invalid address");
        address oldTreasury = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }

    function setDexTreasury(address _newDexTreasury) external onlyOwner {
        require(_newDexTreasury != address(0), "Invalid address");
        address oldDexTreasury = dexTreasury;
        dexTreasury = _newDexTreasury;
        emit DexTreasuryUpdated(oldDexTreasury, _newDexTreasury);
    }

    function setSigner(address _newSigner) external onlyOwner {
        require(_newSigner != address(0), "Invalid address");
        address oldSigner = signer;
        signer = _newSigner;
        emit SignerUpdated(oldSigner, _newSigner);
    }

    function setDefaultParameters(
        uint256 _totalSupply,
        uint256 _virtualTokenReserves,
        uint256 _virtualCollateralReserves,
        uint256 _feeBasisPoints,
        uint256 _dexFeeBasisPoints,
        uint256 _migrationFeeFixed,
        uint256 _poolCreationFee,
        uint256 _mcLowerLimit,
        uint256 _mcUpperLimit,
        uint256 _tokensMigrationThreshold
    ) external onlyOwner {
        require(_totalSupply > 0 && _mcUpperLimit > 0, "Invalid parameters");
        require(_feeBasisPoints <= 10000 && _dexFeeBasisPoints <= 10000, "Invalid fee BPS");
        require(_mcLowerLimit < _mcUpperLimit, "Invalid market cap range");
        
        defaultTotalSupply = _totalSupply;
        defaultVirtualTokenReserves = _virtualTokenReserves;
        defaultVirtualCollateralReserves = _virtualCollateralReserves;
        defaultFeeBasisPoints = _feeBasisPoints;
        defaultDexFeeBasisPoints = _dexFeeBasisPoints;
        defaultMigrationFeeFixed = _migrationFeeFixed;
        defaultPoolCreationFee = _poolCreationFee;
        defaultMcLowerLimit = _mcLowerLimit;
        defaultMcUpperLimit = _mcUpperLimit;
        defaultTokensMigrationThreshold = _tokensMigrationThreshold;
        
        emit DefaultParametersUpdated();
    }

    function setMigrationPermission(address _account, bool _canMigrate) external onlyOwner {
        canMigrate[_account] = _canMigrate;
        emit MigrationPermissionUpdated(_account, _canMigrate);
    }

    function withdrawFees() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFeesToWithdraw();
        
        (bool success, ) = treasury.call{value: balance}("");
        if (!success) revert FeeWithdrawalFailed();
        
        emit FeesWithdrawn(treasury, balance);
    }

    // --- Simplified Emergency Functions ---
    
    /**
     * @notice Emergency token recovery (simplified - owner only with event logging)
     */
    function emergencyTokenRecovery(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(0) && _amount > 0, "Invalid parameters");
        require(IERC20(_token).transfer(treasury, _amount), "Transfer failed");
        emit TokenSaleCancelled(address(0), "Emergency token recovery executed");
    }

    // --- Token Creation ---
    
    /**
     * @notice Create a new QoraFi token with scheduled launch and deadline system
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _launchTime Scheduled launch timestamp (use block.timestamp for immediate launch)
     * @param _deadlineDuration Deadline duration (24h, 48h, or 72h)
     * @param _nonce Unique nonce for signature
     * @param _signature Authorization signature
     */
    function createQoraFiToken(
        string calldata _name,
        string calldata _symbol,
        uint256 _launchTime, // Scheduled launch timestamp
        uint256 _deadlineDuration, // 24h, 48h, or 72h in seconds
        uint256 _nonce,
        bytes calldata _signature
    ) external payable nonReentrant returns (address tokenAddress) {
        if (msg.value != launchFee) revert InvalidLaunchFee();
        
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) {
            revert InvalidParameters();
        }

        // Validate launch time and deadline duration
        if (_launchTime < block.timestamp) {
            revert InvalidParameters(); // Launch time cannot be in the past
        }
        if (_deadlineDuration != 24 hours && _deadlineDuration != 48 hours && _deadlineDuration != 72 hours) {
            revert InvalidDeadlineDuration();
        }

        LaunchpadHelpers.validateLaunchParameters(_name, _symbol, _launchTime, _deadlineDuration);
        LaunchpadHelpers.validateAndStoreSignature(
            _name, _symbol, _launchTime, _deadlineDuration, _nonce, _signature,
            signer, address(this), msg.sender, usedSignatures
        );

        // Deploy new token instance using the ConstructorParams struct
        QoraFiLaunchpadVesting token = new QoraFiLaunchpadVesting(
            QoraFiTokenCore.ConstructorParams({
                name: _name,
                symbol: _symbol,
                creator: msg.sender,
                treasury: treasury,
                dexTreasury: dexTreasury,
                uniV2Router: uniV2Router,
                totalSupply: defaultTotalSupply,
                virtualTokenReserves: defaultVirtualTokenReserves,
                virtualCollateralReserves: defaultVirtualCollateralReserves,
                feeBasisPoints: defaultFeeBasisPoints,
                dexFeeBasisPoints: defaultDexFeeBasisPoints,
                migrationFeeFixed: defaultMigrationFeeFixed,
                poolCreationFee: defaultPoolCreationFee,
                mcLowerLimit: defaultMcLowerLimit,
                mcUpperLimit: defaultMcUpperLimit,
                tokensMigrationThreshold: defaultTokensMigrationThreshold,
                deadlineDuration: _deadlineDuration,
                launchTime: _launchTime,
                securityManager: address(securityManager)
            })
        );

        tokenAddress = address(token);
        
        isDeployedToken[tokenAddress] = true;
        deployedTokens.push(tokenAddress);
        
        emit NewQoraFiToken(tokenAddress, msg.sender, _name, _symbol, _deadlineDuration, _signature);
        emit TokenLaunchScheduled(tokenAddress, _launchTime, _launchTime + _deadlineDuration);
    }
    

    // --- Trading Proxy Functions ---
    
    function buyFromLaunchpad(address _token) external payable nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiLaunchpadVesting(_token).buy{value: msg.value}(msg.sender);
    }

    function buyExactOutFromLaunchpad(
        address _token,
        uint256 _tokenAmount,
        uint256 _maxCollateralAmount
    ) external payable nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiLaunchpadVesting(_token).buyExactOut{value: msg.value}(msg.sender, _tokenAmount, _maxCollateralAmount);
    }

    function buyExactInFromLaunchpad(
        address _token,
        uint256 _amountOutMin
    ) external payable nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiLaunchpadVesting(_token).buyExactIn{value: msg.value}(msg.sender, _amountOutMin);
    }

    // Note: Selling functions removed - only buying allowed during bonding curve phase

    function migrateFromLaunchpad(address _token) external nonReentrant {
        if (!canMigrate[msg.sender]) revert UnauthorizedMigration();
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        
        QoraFiLaunchpadVesting(_token).migrate();
    }

    // --- Admin Functions for Cancelled Sales ---

    /**
     * @notice Cancel a token sale manually (admin only)
     */
    function cancelTokenSale(address _token) external onlyOwner nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiLaunchpadVesting(_token).cancelSale();
        emit TokenSaleCancelled(_token, "Manual admin cancellation");
    }

    /**
     * @notice Trigger emergency refund for all buyers of a cancelled sale
     */
    function emergencyRefundAllBuyers(address _token) external onlyOwner nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiLaunchpadVesting(_token).emergencyRefundAll();
    }

    /**
     * @notice Check deadline status for a token
     */
    function checkTokenDeadline(address _token) external view returns (
        uint256 deadline,
        uint256 timeRemaining,
        bool isExpired,
        bool isCancelled
    ) {
        return LaunchpadHelpers.getTokenDeadlineInfo(_token, isDeployedToken[_token]);
    }

    /**
     * @notice Check launch status for a token
     */
    function checkTokenLaunch(address _token) external view returns (
        uint256 scheduledLaunchTime,
        uint256 timeUntilLaunch,
        bool hasLaunched,
        uint256 deadline,
        bool isActive
    ) {
        return LaunchpadHelpers.getTokenLaunchInfo(_token, isDeployedToken[_token]);
    }

    /**
     * @notice Batch check deadlines for multiple tokens
     */
    function batchCheckDeadlines(address[] calldata _tokens) external {
        LaunchpadHelpers.batchCheckDeadlines(_tokens, isDeployedToken);
    }

    // --- View Functions ---
    
    function getDeployedTokensCount() external view returns (uint256) {
        return deployedTokens.length;
    }

    function getDeployedToken(uint256 _index) external view returns (address) {
        require(_index < deployedTokens.length, "Index out of bounds");
        return deployedTokens[_index];
    }

    function getAllDeployedTokens() external view returns (address[] memory) {
        return deployedTokens;
    }

    function isSignatureUsed(bytes calldata _signature) external view returns (bool) {
        bytes32 sigHash = keccak256(_signature);
        return usedSignatures[sigHash];
    }

    function getTokensByCreator(address _creator) external view returns (address[] memory) {
        return LaunchpadHelpers.getTokensByCreator(_creator, deployedTokens);
    }

    function getActiveTokens() external view returns (address[] memory) {
        return LaunchpadHelpers.getActiveTokens(deployedTokens);
    }

    // Emergency system view functions removed to reduce contract size
    
    receive() external payable {}
}