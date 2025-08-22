// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./QoraFiTokenCore.sol";

/**
 * @title QoraFiLaunchpadVesting
 * @notice Vesting and refund functionality for QoraFi tokens
 */
contract QoraFiLaunchpadVesting is QoraFiTokenCore {
    
    // --- Additional Events ---
    event InitialTokensClaimed(address indexed buyer, uint256 amount);
    event VestedTokensClaimed(address indexed buyer, uint256 amount);
    event RefundClaimed(address indexed buyer, uint256 amount);

    // --- Additional Errors ---
    error NoTokensOwed();
    error InitialTokensAlreadyClaimed();
    error NoVestedTokensAvailable();
    error NoRefundAvailable();
    error RefundAlreadyClaimed();
    error MigrationHasNotOccurred();

    // --- Additional Modifiers ---
    modifier onlyMigratedState() {
        if (currentState != TokenState.Migrated) revert MigrationHasNotOccurred();
        _;
    }

    constructor(ConstructorParams memory _params) QoraFiTokenCore(_params) {}

    // --- Sell Functions (disabled) ---
    function sellExactIn(uint256, uint256) external payable onlyFactory returns (uint256, uint256, uint256) {
        revert SaleNotActive(); // No selling during bonding curve
    }
    
    function sellExactOut(uint256, uint256) external payable onlyFactory returns (uint256, uint256, uint256, uint256) {
        revert SaleNotActive(); // No selling during bonding curve
    }

    // --- Refund Functions ---

    /**
     * @notice Claim refund if sale cancelled
     */
    function claimRefund() external nonReentrant {
        if (!saleCancelled) revert SaleNotCancelled();
        
        BuyerInfo storage buyerInfo = _buyers[msg.sender];
        if (buyerInfo.ethContributed == 0) revert NoRefundAvailable();
        if (buyerInfo.refundClaimed) revert RefundAlreadyClaimed();
        
        uint256 refundAmount = buyerInfo.ethContributed;
        buyerInfo.refundClaimed = true;
        
        _transferCollateral(msg.sender, refundAmount);
        emit RefundClaimed(msg.sender, refundAmount);
    }

    /**
     * @notice Emergency refund all buyers (factory only)
     */
    function emergencyRefundAll() external onlyFactory nonReentrant {
        if (!saleCancelled) revert SaleNotCancelled();
        
        for (uint256 i = 0; i < buyersList.length; i++) {
            address buyer = buyersList[i];
            BuyerInfo storage buyerInfo = _buyers[buyer];
            
            if (buyerInfo.ethContributed > 0 && !buyerInfo.refundClaimed) {
                uint256 refundAmount = buyerInfo.ethContributed;
                buyerInfo.refundClaimed = true;
                
                _transferCollateral(buyer, refundAmount);
                emit RefundClaimed(buyer, refundAmount);
            }
        }
    }

    // --- Vesting Functions ---

    /**
     * @notice Claim initial tokens (equal to investment value)
     */
    function claimInitialTokens() external onlyMigratedState nonReentrant {
        BuyerInfo storage buyerInfo = _buyers[msg.sender];
        
        if (buyerInfo.ethContributed == 0) revert NoTokensOwed();
        if (buyerInfo.initialTokensClaimed) revert InitialTokensAlreadyClaimed();
        
        uint256 totalTokensAtMigration = buyerInfo.tokensOwed;
        uint256 immediateTokens = _calculateImmediateTokens(buyerInfo.ethContributed, totalTokensAtMigration);
        
        buyerInfo.initialTokensClaimed = true;
        buyerInfo.immediateTokensReceived = immediateTokens;
        
        _mint(msg.sender, immediateTokens);
        emit InitialTokensClaimed(msg.sender, immediateTokens);
    }

    /**
     * @notice Claim vested tokens (daily over 6 days)
     */
    function claimVestedTokens() external onlyMigratedState nonReentrant {
        BuyerInfo storage buyerInfo = _buyers[msg.sender];
        
        if (buyerInfo.tokensOwed == 0) revert NoTokensOwed();
        if (!buyerInfo.initialTokensClaimed) revert InitialTokensAlreadyClaimed();
        
        uint256 availableVested = _calculateAvailableVestedTokens(msg.sender);
        if (availableVested == 0) revert NoVestedTokensAvailable();
        
        buyerInfo.vestedTokensClaimed += availableVested;
        
        _mint(msg.sender, availableVested);
        emit VestedTokensClaimed(msg.sender, availableVested);
    }

    // --- Internal Vesting Logic ---

    function _calculateImmediateTokens(uint256 ethContributed, uint256 totalTokensOwed) internal view returns (uint256) {
        // If LP hasn't launched yet or price is 0, fall back to 50%
        if (lpLaunchPrice == 0) {
            return totalTokensOwed / 2;
        }
        
        // Calculate tokens worth the user's ETH investment at LP launch price
        // lpLaunchPrice is in wei per token, ethContributed is in wei
        uint256 immediateTokens = (ethContributed * 1e18) / lpLaunchPrice;
        
        // Ensure we don't give more tokens than the user is owed
        if (immediateTokens > totalTokensOwed) {
            immediateTokens = totalTokensOwed;
        }
        
        return immediateTokens;
    }

    function _calculateAvailableVestedTokens(address buyer) internal view returns (uint256) {
        BuyerInfo memory buyerInfo = _buyers[buyer];
        
        if (buyerInfo.tokensOwed == 0 || migrationTimestamp == 0 || !buyerInfo.initialTokensClaimed) return 0;
        
        uint256 timeElapsed = block.timestamp - migrationTimestamp;
        if (timeElapsed >= VESTING_DURATION) {
            return buyerInfo.tokensOwed - buyerInfo.immediateTokensReceived - buyerInfo.vestedTokensClaimed;
        }
        
        uint256 dailyAmount = (buyerInfo.tokensOwed - buyerInfo.immediateTokensReceived) / 6;
        uint256 daysElapsed = timeElapsed / DAILY_VESTING_DURATION;
        uint256 available = dailyAmount * daysElapsed;
        
        return available > buyerInfo.vestedTokensClaimed ? available - buyerInfo.vestedTokensClaimed : 0;
    }

    // --- Advanced View Functions ---

    function getAvailableVestedTokens(address _buyer) external view returns (uint256) {
        return _calculateAvailableVestedTokens(_buyer);
    }

    /**
     * @notice Get detailed vesting information for a buyer
     * @param _buyer Buyer address
     * @return ethInvested ETH invested by buyer
     * @return tokensOwed Total tokens owed to buyer
     * @return immediateTokens Tokens claimable immediately (based on investment value)
     * @return vestedTokens Remaining tokens to be vested
     * @return dailyVestAmount Tokens claimable per day
     * @return lpPrice LP launch price (wei per token)
     */
    function getVestingInfo(address _buyer) external view returns (
        uint256 ethInvested,
        uint256 tokensOwed,
        uint256 immediateTokens,
        uint256 vestedTokens,
        uint256 dailyVestAmount,
        uint256 lpPrice
    ) {
        BuyerInfo memory buyerInfo = _buyers[_buyer];
        ethInvested = buyerInfo.ethContributed;
        tokensOwed = buyerInfo.tokensOwed;
        lpPrice = lpLaunchPrice;
        
        if (tokensOwed > 0) {
            immediateTokens = _calculateImmediateTokens(ethInvested, tokensOwed);
            vestedTokens = tokensOwed - immediateTokens;
            dailyVestAmount = vestedTokens / 6; // 6 days vesting
        }
    }


    function canClaimRefund(address buyer) external view returns (bool canClaim, uint256 refundAmount) {
        if (!saleCancelled) return (false, 0);
        
        BuyerInfo memory buyerInfo = _buyers[buyer];
        canClaim = buyerInfo.ethContributed > 0 && !buyerInfo.refundClaimed;
        refundAmount = canClaim ? buyerInfo.ethContributed : 0;
    }

    function getTotalRefundsAvailable() external view returns (uint256 totalRefunds, uint256 buyersWithRefunds) {
        if (!saleCancelled) return (0, 0);
        
        for (uint256 i = 0; i < buyersList.length; i++) {
            BuyerInfo memory buyerInfo = _buyers[buyersList[i]];
            if (buyerInfo.ethContributed > 0 && !buyerInfo.refundClaimed) {
                totalRefunds += buyerInfo.ethContributed;
                buyersWithRefunds++;
            }
        }
    }

    function getCurveProgressBps() external view returns (uint256) {
        if (tokensMigrationThreshold == 0) return 0;
        uint256 progress = ((initialTokenSupply - balanceOf(address(this))) * MAX_BPS) / tokensMigrationThreshold;
        return progress < 100 ? 100 : (progress > MAX_BPS ? MAX_BPS : progress);
    }

    function getAmountOutAndFee(uint256 _amountIn, uint256 _reserveIn, uint256 _reserveOut, bool /* _paymentTokenIsIn */) external view returns (uint256 amountOut, uint256 fee) {
        fee = (_amountIn * feeBPS) / MAX_BPS;
        uint256 amountInMinusFee = _amountIn - fee;
        
        if (_reserveIn == 0 || _reserveOut == 0) return (0, 0);
        amountOut = (amountInMinusFee * _reserveOut) / (_reserveIn + amountInMinusFee);
    }

    function getAmountInAndFee(uint256 _amountOut, uint256 _reserveIn, uint256 _reserveOut, bool /* _paymentTokenIsOut */) external view returns (uint256 amountIn, uint256 fee) {
        if (_reserveIn == 0 || _reserveOut == 0 || _amountOut >= _reserveOut) return (0, 0);
        
        uint256 numerator = _reserveIn * _amountOut;
        uint256 denominator = _reserveOut - _amountOut;
        uint256 amountInBeforeFee = numerator / denominator;
        
        // Add fee on top
        amountIn = (amountInBeforeFee * MAX_BPS) / (MAX_BPS - feeBPS);
        fee = amountIn - amountInBeforeFee;
    }
}