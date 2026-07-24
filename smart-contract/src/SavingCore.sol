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
    Pausable,
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

    // Events
    event PlanCreated(
        uint32 indexed planId,
        uint32 tenorDays,
        uint32 aprbps,
        uint32 withdrawalFeeBps,
        uint64 minDeposit,
        uint64 maxDeposit,
        bool enable
    );
    event PlanUpdated(uint32 indexed planId, uint32 newAprBps);
    event PlanStatusToggled(uint32 indexed planId, bool enable);
    event DepositOpened(
        uint256 indexed depositId,
        address indexed owner,
        uint32 indexed planId,
        uint64 principal,
        uint40 maturityAt,
        uint32 aprBpsAtOpen,
        bool enableBot
    );
    event DepositWithdrawnAtMaturity(
        uint256 indexed depositId,
        address indexed owner,
        uint256 principal,
        uint256 interest
    );
    event EarlyWithdrawal(
        uint256 indexed depositId,
        address indexed owner,
        uint256 withdrawAmount,
        uint256 penaltyFee,
        uint256 netPrincipalReturned
    );
    event DepositRenewed(
        uint256 indexed depositId,
        address indexed owner,
        uint64 newPrincipal,
        uint40 newMaturityAt,
        uint32 newAprBps,
        bool isAutoRenew
    );
    event DepositLiquidated(
        uint256 indexed depositId,
        address indexed owner,
        uint256 principalRefunded,
        uint256 feeDeducted
    );

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
        emit PlanCreated(
            planId,
            tenorDays,
            aprbps,
            withdrawalFeeBps,
            minDeposit,
            maxDeposit,
            enable
        );
    }

    function updatePlan(uint32 planId, uint32 newAprBps) external onlyOwner {
        plans[planId].aprbps = newAprBps;
        emit PlanUpdated(planId, newAprBps);
    }

    function enablePlan(uint32 planId) external onlyOwner {
        _planAllowDeposit(planId, true);
    }

    function disablePlan(uint32 planId) external onlyOwner {
        _planAllowDeposit(planId, false);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function openDeposit(
        uint32 planId,
        uint64 principal,
        uint32 expectedAprBps,
        bool enableBot
    ) external whenNotPaused {
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
            maturityAt: uint40(
                block.timestamp + (plans[planId].tenorDays * 1 days)
            ),
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
        require(
            usdc.balanceOf(address(vaultManager)) >=
                vaultManager.totalPromisedInterest() + interest,
            "Vault underfunded: interest not pre-funded"
        );
        vaultManager.increaseTotalPromisedInterest(interest);

        _safeMint(msg.sender, tokenId);
        usdc.transferFrom(msg.sender, address(this), principal);

        emit DepositOpened(
            tokenId,
            msg.sender,
            planId,
            principal,
            deposits[tokenId].maturityAt,
            plans[planId].aprbps,
            enableBot
        );
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

        userdeposit.status = DepositStatus.CLOSE;
        uint256 WithdrawPrincipal = userdeposit.principal;
        _burn(DepositId);

        usdc.transfer(msg.sender, WithdrawPrincipal);
        usdc.transferFrom(address(vaultManager), msg.sender, interest);

        emit DepositWithdrawnAtMaturity(
            DepositId,
            msg.sender,
            WithdrawPrincipal,
            interest
        );
    }

    function renewDeposit(
        uint256 depositId,
        uint32 expectedAprBps
    ) external nonReentrant whenNotPaused {
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

        Plan memory currentPlan = plans[userdeposit.planId];
        require(expectedAprBps == currentPlan.aprbps, "aprBps do not match");
        require(currentPlan.enable, "Plan is not enabled");

        uint256 earnedInterest = _calculateInterest(
            userdeposit.principal,
            userdeposit.aprBpsAtOpen,
            userdeposit.tenorDaysAtOpen
        );

        uint64 newPrincipal = userdeposit.principal + uint64(earnedInterest);
        require(
            newPrincipal >= currentPlan.minDeposit &&
                newPrincipal <= currentPlan.maxDeposit,
            "principal is not in range"
        );

        usdc.transferFrom(address(vaultManager), address(this), earnedInterest);

        userdeposit.principal = newPrincipal;
        userdeposit.maturityAt = uint40(
            block.timestamp + (currentPlan.tenorDays * 1 days)
        );
        userdeposit.aprBpsAtOpen = currentPlan.aprbps;
        userdeposit.penaltyBpsAtOpen = currentPlan.withdrawalFeeBps;
        userdeposit.tenorDaysAtOpen = currentPlan.tenorDays;

        uint256 newPromisedInterest = _calculateInterest(
            newPrincipal,
            currentPlan.aprbps,
            currentPlan.tenorDays
        );

        if (newPromisedInterest > earnedInterest) {
            uint256 netIncrease = newPromisedInterest - earnedInterest;
            require(
                usdc.balanceOf(address(vaultManager)) >=
                    vaultManager.totalPromisedInterest() + netIncrease,
                "Vault underfunded: interest not pre-funded"
            );
            vaultManager.increaseTotalPromisedInterest(netIncrease);
        } else if (earnedInterest > newPromisedInterest) {
            vaultManager.decreaseTotalPromisedInterest(
                earnedInterest - newPromisedInterest
            );
        }

        emit DepositRenewed(
            depositId,
            msg.sender,
            newPrincipal,
            userdeposit.maturityAt,
            currentPlan.aprbps,
            false
        );
    }

    function earlyWithdraw(
        uint256 DepositId,
        uint256 withdrawAmount
    ) external nonReentrant {
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

        uint256 promisedInterestToSubtract = _calculateInterest(
            uint64(withdrawAmount),
            userdeposit.aprBpsAtOpen,
            userdeposit.tenorDaysAtOpen
        );
        vaultManager.decreaseTotalPromisedInterest(promisedInterestToSubtract);

        userdeposit.principal -= uint64(withdrawAmount);

        if (userdeposit.principal == 0) {
            userdeposit.status = DepositStatus.CLOSE;
            _burn(DepositId);
        }

        uint256 penalty = (withdrawAmount * userdeposit.penaltyBpsAtOpen) /
            10000;
        uint256 remainingPrincipal = withdrawAmount - penalty;

        address feeReceiver = vaultManager.feeReceiver();
        if (penalty > 0) {
            require(
                feeReceiver != address(0),
                "Fee receiver not set in VaultManager"
            );
            usdc.transfer(feeReceiver, penalty);
        }

        usdc.transfer(msg.sender, remainingPrincipal);

        emit EarlyWithdrawal(
            DepositId,
            msg.sender,
            withdrawAmount,
            penalty,
            remainingPrincipal
        );
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
        if (paused()) {
            return (false, "");
        }

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

    function performUpkeep(
        bytes calldata performData
    ) external override nonReentrant whenNotPaused {
        uint256[] memory depositIds = abi.decode(performData, (uint256[]));
        for (uint256 i = 0; i < depositIds.length; i++) {
            _autoRenewDeposit(depositIds[i]);
        }
    }

    function _autoRenewDeposit(uint256 depositId) internal {
        Deposit storage userdeposit = deposits[depositId];

        if (
            paused() ||
            userdeposit.status != DepositStatus.ACTIVE ||
            !userdeposit.enableBot ||
            block.timestamp <= userdeposit.maturityAt + 2 days
        ) {
            return;
        }

        Plan memory currentPlan = plans[userdeposit.planId];
        if (!currentPlan.enable) {
            return;
        }

        uint256 earnedInterest = _calculateInterest(
            userdeposit.principal,
            userdeposit.aprBpsAtOpen,
            userdeposit.tenorDaysAtOpen
        );

        uint256 fee = vaultManager.feeReceiver() != address(0)
            ? AUTOMATION_FEE
            : 0;

        if (earnedInterest >= fee) {
            uint256 userInterest = earnedInterest - fee;

            usdc.transferFrom(
                address(vaultManager),
                address(this),
                earnedInterest
            );
            if (fee > 0) {
                usdc.transfer(vaultManager.feeReceiver(), fee);
            }

            uint64 newPrincipal = userdeposit.principal + uint64(userInterest);
            if (
                newPrincipal < currentPlan.minDeposit ||
                newPrincipal > currentPlan.maxDeposit
            ) {
                return;
            }

            userdeposit.principal = newPrincipal;
            userdeposit.maturityAt = uint40(
                block.timestamp + (currentPlan.tenorDays * 1 days)
            );
            userdeposit.aprBpsAtOpen = currentPlan.aprbps;
            userdeposit.penaltyBpsAtOpen = currentPlan.withdrawalFeeBps;
            userdeposit.tenorDaysAtOpen = currentPlan.tenorDays;

            uint256 newPromisedInterest = _calculateInterest(
                newPrincipal,
                currentPlan.aprbps,
                currentPlan.tenorDays
            );

            if (newPromisedInterest > earnedInterest) {
                uint256 netIncrease = newPromisedInterest - earnedInterest;
                if (
                    usdc.balanceOf(address(vaultManager)) <
                    vaultManager.totalPromisedInterest() + netIncrease
                ) {
                    return;
                }
                vaultManager.increaseTotalPromisedInterest(netIncrease);
            } else if (earnedInterest > newPromisedInterest) {
                vaultManager.decreaseTotalPromisedInterest(
                    earnedInterest - newPromisedInterest
                );
            }

            emit DepositRenewed(
                depositId,
                ownerOf(depositId),
                newPrincipal,
                userdeposit.maturityAt,
                currentPlan.aprbps,
                true
            );
        } else {
            uint256 principalDeduction = fee - earnedInterest;

            usdc.transferFrom(
                address(vaultManager),
                address(this),
                earnedInterest
            );

            address owner = ownerOf(depositId);
            uint256 remainingPrincipal = 0;

            if (userdeposit.principal <= principalDeduction) {
                uint256 totalAvailable = userdeposit.principal + earnedInterest;
                usdc.transfer(vaultManager.feeReceiver(), totalAvailable);
                userdeposit.principal = 0;
            } else {
                remainingPrincipal = userdeposit.principal - principalDeduction;
                usdc.transfer(vaultManager.feeReceiver(), fee);
                usdc.transfer(owner, remainingPrincipal);
                userdeposit.principal = 0;
            }

            vaultManager.decreaseTotalPromisedInterest(earnedInterest);

            userdeposit.status = DepositStatus.CLOSE;
            _burn(depositId);

            emit DepositLiquidated(depositId, owner, remainingPrincipal, fee);
            return;
        }
    }

    function _planAllowDeposit(uint32 planId, bool enable) internal {
        plans[planId].enable = enable;
        emit PlanStatusToggled(planId, enable);
    }

    function _calculateInterest(
        uint64 principal,
        uint32 aprBps,
        uint32 tenorDays
    ) internal pure returns (uint256) {
        return (principal * aprBps * tenorDays) / (365 * 10000);
    }
}
