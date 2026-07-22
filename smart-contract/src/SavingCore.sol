// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {
    ERC721,
    ERC721URIStorage
} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {
    ReentrancyGuard
} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    AutomationCompatibleInterface
} from "chainlink-brownie-contracts/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

contract SavingCore is
    ERC721,
    Ownable,
    ReentrancyGuard,
    AutomationCompatibleInterface
{
    uint32 private _planIdCounter;
    uint64 private _DepositIdCounter;
    uint256 public constant AUTOMATION_FEE = 1_000_000; // 1 USDC (6 decimals)
    IVaultManager public vaultManager; // 20 bytes storage
    IERC20 public usdc;
    enum DepositStatus {
        ACTIVE,
        CLOSE
    }

    struct Plan {
        uint32 tenorDays; // 4 bytes
        uint32 aprbps; // 4 bytes
        uint32 withdrawalFeeBps; // 4 bytes
        uint64 minDeposit; //8 bytes
        uint64 maxDeposit; // 8 bytes
        bool enable; // 1 bytes
    }
    //Total: 29 bytes
    struct Deposit {
        uint64 principal; // 8 bytes (Max ~18.4 Trillion USDC)
        uint40 maturityAt; // 5 bytes (Unix Timestamp. Safe until the year 34,800!)
        uint32 aprBpsAtOpen; // 4 bytes
        uint32 penaltyBpsAtOpen; // 4 bytes
        uint32 tenorDaysAtOpen; // 4 bytes
        uint32 planId; // 4 bytes (The ID of the plan they chose)
        bool enableBot; // 1 byte
        DepositStatus status; // 1 byte  (Enums are stored as uint8 under the hood)
    }
    //total: 31 bytes (Fits perfectly in 1 storage slot!)

    mapping(uint256 => Plan) public plans;
    mapping(uint256 => Deposit) public deposits;
    constructor(
        address _vaultManager,
        address _usdc
    ) ERC721("SavingCore", "SC") Ownable(msg.sender) {
        vaultManager = IVaultManager(_vaultManager);
        usdc = IERC20(_usdc);
    }

    function createPlan(
        uint32 tenorDays,
        uint32 aprbps,
        uint32 withdrawalFeeBps,
        uint64 minDeposit,
        uint64 maxDeposit,
        bool enable
    ) external onlyOwner {
        uint32 planId = _planIdCounter++;
        plans[planId] = Plan({
            tenorDays: tenorDays,
            aprbps: aprbps,
            withdrawalFeeBps: withdrawalFeeBps,
            minDeposit: minDeposit,
            maxDeposit: maxDeposit,
            enable: enable
        });
    }
    function updatePlan(uint32 planId, uint32 newAprBps) external onlyOwner {
        plans[planId].aprbps = newAprBps;
    }
    function enablePlan(uint32 planId) external onlyOwner {
        _planAllowDeposit(planId, true);
    }
    function disablePlan(uint32 planId) external onlyOwner {
        _planAllowDeposit(planId, false);
    }
    function openDeposit(
        uint32 planId,
        uint64 principal,
        uint32 expectedAprBps,
        bool enableBot
    ) external {
        require(expectedAprBps == plans[planId].aprbps, "aprBps do not match");
        require(plans[planId].enable, "plan is not enabled");
        require(
            principal >= plans[planId].minDeposit &&
                principal <= plans[planId].maxDeposit,
            "principal is not in range"
        );
        uint256 tokenId = _DepositIdCounter++;
        deposits[tokenId] = Deposit({
            principal: principal,
            // Calculate future end date: Current time + (tenorDays * 86,400 seconds)
            maturityAt: uint40(
                block.timestamp + (plans[planId].tenorDays * 1 days)
            ),
            // Snapshot the APR, Penalty, and Tenor so they are locked in for this specific user
            aprBpsAtOpen: plans[planId].aprbps,
            penaltyBpsAtOpen: plans[planId].withdrawalFeeBps,
            tenorDaysAtOpen: plans[planId].tenorDays,
            planId: planId,
            enableBot: enableBot,
            status: DepositStatus.ACTIVE
        });
        uint256 interest = _calculateInterest(
            principal,
            plans[planId].aprbps,
            plans[planId].tenorDays
        );
        vaultManager.increaseTotalPromisedInterest(interest);

        _safeMint(msg.sender, tokenId);
        usdc.transferFrom(msg.sender, address(this), principal);
    }
    function withdrawAtMaturity(uint256 DepositId) external nonReentrant {
        Deposit storage userdeposit = deposits[DepositId];
        require(msg.sender == ownerOf(DepositId), "Not owner");
        require(
            userdeposit.status == DepositStatus.ACTIVE,
            "Deposit is not active"
        );
        require(
            block.timestamp >= userdeposit.maturityAt,
            "Maturity not reached yet."
        );
        uint256 interest = _calculateInterest(
            userdeposit.principal,
            userdeposit.aprBpsAtOpen,
            userdeposit.tenorDaysAtOpen
        );
        vaultManager.decreaseTotalPromisedInterest(interest);
        
        // Checks-Effects-Interactions Pattern: Update state & burn NFT BEFORE external token transfers!
        userdeposit.status = DepositStatus.CLOSE;
        uint256 WithdrawPrincipal = userdeposit.principal;
        _burn(DepositId);

        // External Transfers
        usdc.transfer(msg.sender, WithdrawPrincipal);
        usdc.transferFrom(address(vaultManager), msg.sender, interest);
    }

    function renewDeposit(uint256 depositId) external nonReentrant {
        Deposit storage userdeposit = deposits[depositId];
        require(msg.sender == ownerOf(depositId), "Not owner");
        require(
            userdeposit.status == DepositStatus.ACTIVE,
            "Deposit is not active"
        );
        require(
            block.timestamp >= userdeposit.maturityAt,
            "Maturity not reached yet."
        );

        // Fetch the current plan settings for the new term
        Plan memory currentPlan = plans[userdeposit.planId];
        require(currentPlan.enable, "Plan is not enabled");

        // 1. Calculate earned interest for completed term using snapshotted APR and snapshotted Tenor
        uint256 earnedInterest = _calculateInterest(
            userdeposit.principal,
            userdeposit.aprBpsAtOpen,
            userdeposit.tenorDaysAtOpen
        );

        // 2. Compound principal
        uint64 newPrincipal = userdeposit.principal + uint64(earnedInterest);

        // 3. Pull earned interest from VaultManager to SavingCore
        usdc.transferFrom(address(vaultManager), address(this), earnedInterest);

        // 4. Overwrite existing deposit directly with updated APR and Tenor from current plan
        userdeposit.principal = newPrincipal;
        userdeposit.maturityAt = uint40(
            block.timestamp + (currentPlan.tenorDays * 1 days)
        );
        userdeposit.aprBpsAtOpen = currentPlan.aprbps; // Takes the UPDATED APR from the plan!
        userdeposit.penaltyBpsAtOpen = currentPlan.withdrawalFeeBps;
        userdeposit.tenorDaysAtOpen = currentPlan.tenorDays; // Snapshot the new tenor

        // 5. Calculate new promised interest using the updated APR and Tenor
        uint256 newPromisedInterest = _calculateInterest(
            newPrincipal,
            currentPlan.aprbps,
            currentPlan.tenorDays
        );

        // Gas Optimization: Combine the two external calls into ONE single call!
        if (newPromisedInterest > earnedInterest) {
            vaultManager.increaseTotalPromisedInterest(
                newPromisedInterest - earnedInterest
            );
        } else if (earnedInterest > newPromisedInterest) {
            vaultManager.decreaseTotalPromisedInterest(
                earnedInterest - newPromisedInterest
            );
        }
    }

    function earlyWithdraw(uint256 DepositId, uint256 withdrawAmount) external nonReentrant {
        Deposit storage userdeposit = deposits[DepositId];
        require(msg.sender == ownerOf(DepositId), "Not owner");
        require(
            userdeposit.status == DepositStatus.ACTIVE,
            "Deposit is not active"
        );
        require(
            block.timestamp < userdeposit.maturityAt,
            "Maturity reached, use withdrawAtMaturity."
        );
        require(
            withdrawAmount > 0 && withdrawAmount <= userdeposit.principal,
            "Invalid withdraw amount"
        );

        // 1. Calculate the interest that was originally promised for this specific withdraw amount
        // so we can remove it from the Vault's debt
        uint256 promisedInterestToSubtract = _calculateInterest(
            uint64(withdrawAmount),
            userdeposit.aprBpsAtOpen,
            userdeposit.tenorDaysAtOpen
        );
        vaultManager.decreaseTotalPromisedInterest(promisedInterestToSubtract);

        // 2. Reduce the principal
        userdeposit.principal -= uint64(withdrawAmount);

        // 3. Mark deposit as closed and burn NFT ONLY if they withdrew everything
        if (userdeposit.principal == 0) {
            userdeposit.status = DepositStatus.CLOSE;
            _burn(DepositId);
        }

        // 4. Calculate penalty only on the withdrawn amount
        uint256 penalty = (withdrawAmount * userdeposit.penaltyBpsAtOpen) /
            10000;
        uint256 remainingPrincipal = withdrawAmount - penalty;

        // 5. Transfer penalty to the fee receiver
        address feeReceiver = vaultManager.feeReceiver();
        if (penalty > 0) {
            require(
                feeReceiver != address(0),
                "Fee receiver not set in VaultManager"
            );
            usdc.transfer(feeReceiver, penalty);
        }

        // 6. Transfer remaining principal to the user
        usdc.transfer(msg.sender, remainingPrincipal);
    }

    // ==========================================
    // CHAINLINK AUTOMATION (KEEPERS) INTEGRATION
    // ==========================================

    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // For the capstone demo, we will let the contract figure out the IDs entirely on-chain!
        // We ignore the checkData payload and loop through all existing deposits.
        uint256[] memory validUpkeeps = new uint256[](_DepositIdCounter);
        uint256 validCount = 0;

        for (uint256 i = 0; i < _DepositIdCounter; i++) {
            Deposit memory d = deposits[i];
            
            if (
                d.status == DepositStatus.ACTIVE &&
                d.enableBot == true &&
                block.timestamp > d.maturityAt + 2 days &&
                plans[d.planId].enable == true
            ) {
                validUpkeeps[validCount] = i;
                validCount++;
            }
        }

        if (validCount > 0) {
            upkeepNeeded = true;
            // Resize array to fit exactly the valid deposits
            uint256[] memory finalUpkeeps = new uint256[](validCount);
            for (uint256 i = 0; i < validCount; i++) {
                finalUpkeeps[i] = validUpkeeps[i];
            }
            performData = abi.encode(finalUpkeeps);
        } else {
            upkeepNeeded = false;
            performData = "";
        }
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        uint256[] memory depositIds = abi.decode(performData, (uint256[]));
        for (uint256 i = 0; i < depositIds.length; i++) {
            _autoRenewDeposit(depositIds[i]);
        }
    }

    function _autoRenewDeposit(uint256 depositId) internal {
        Deposit storage userdeposit = deposits[depositId];
        
        // Double check conditions at execution time
        if (
            userdeposit.status != DepositStatus.ACTIVE ||
            !userdeposit.enableBot ||
            block.timestamp <= userdeposit.maturityAt + 2 days
        ) {
            return; // Skip invalid deposits instead of reverting the whole batch
        }

        Plan memory currentPlan = plans[userdeposit.planId];
        if (!currentPlan.enable) {
            return; // Cannot auto-renew into a disabled plan
        }

        // 1. Calculate earned interest for completed term using snapshotted APR and Tenor
        uint256 earnedInterest = _calculateInterest(
            userdeposit.principal,
            userdeposit.aprBpsAtOpen,
            userdeposit.tenorDaysAtOpen
        );

        // 2. DeFi Liquidation Engine & Automation Fee
        uint256 fee = vaultManager.feeReceiver() != address(0) ? AUTOMATION_FEE : 0;
        
        if (earnedInterest >= fee) {
            // Path A: Profitable (or no fee)
            uint256 userInterest = earnedInterest - fee;
            
            // Pull full interest from Vault to SavingCore
            usdc.transferFrom(address(vaultManager), address(this), earnedInterest);
            if (fee > 0) {
                usdc.transfer(vaultManager.feeReceiver(), fee);
            }
            
            // 3. Compound principal (only the user's portion of the interest)
            uint64 newPrincipal = userdeposit.principal + uint64(userInterest);
            
            // 4. Overwrite deposit with current active plan parameters
            userdeposit.principal = newPrincipal;
            userdeposit.maturityAt = uint40(block.timestamp + (currentPlan.tenorDays * 1 days));
            userdeposit.aprBpsAtOpen = currentPlan.aprbps; // Adopts the current active plan APR
            userdeposit.penaltyBpsAtOpen = currentPlan.withdrawalFeeBps;
            userdeposit.tenorDaysAtOpen = currentPlan.tenorDays;
            
            // 5. Calculate new promised interest using current plan APR
            uint256 newPromisedInterest = _calculateInterest(
                newPrincipal,
                currentPlan.aprbps,
                currentPlan.tenorDays
            );

            // 6. Adjust Vault debt
            if (newPromisedInterest > earnedInterest) {
                vaultManager.increaseTotalPromisedInterest(newPromisedInterest - earnedInterest);
            } else if (earnedInterest > newPromisedInterest) {
                vaultManager.decreaseTotalPromisedInterest(earnedInterest - newPromisedInterest);
            }
        } else {
            // Path B: Unprofitable Liquidation (earnedInterest < fee)
            // They don't make enough interest to cover the fee. Liquidate their position.
            uint256 principalDeduction = fee - earnedInterest;
            
            // Pull the tiny earned interest from Vault
            usdc.transferFrom(address(vaultManager), address(this), earnedInterest);
            
            if (userdeposit.principal <= principalDeduction) {
                // Complete Wipeout (Extremely rare edge case)
                uint256 totalAvailable = userdeposit.principal + earnedInterest;
                usdc.transfer(vaultManager.feeReceiver(), totalAvailable);
                userdeposit.principal = 0;
            } else {
                // Normal Liquidation (Deduct deficit from principal and refund the rest)
                uint256 remainingPrincipal = userdeposit.principal - principalDeduction;
                usdc.transfer(vaultManager.feeReceiver(), fee);
                usdc.transfer(ownerOf(depositId), remainingPrincipal);
                userdeposit.principal = 0;
            }
            
            // Decrease vault debt since we are closing and NOT renewing
            vaultManager.decreaseTotalPromisedInterest(earnedInterest);
            
            // Close the deposit and burn the NFT to stop the bleeding
            userdeposit.status = DepositStatus.CLOSE;
            _burn(depositId);
            return;
        }
    }

    function _planAllowDeposit(uint32 planId, bool enable) internal {
        plans[planId].enable = enable;
    }
    function _calculateInterest(
        uint64 principal,
        uint32 aprBps,
        uint32 tenorDays
    ) internal pure returns (uint256) {
        return (principal * aprBps * tenorDays) / (365 * 10000); // better gas saving formula
    }
}
