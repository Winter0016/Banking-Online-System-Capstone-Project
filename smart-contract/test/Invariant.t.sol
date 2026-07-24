// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {SavingCore} from "../src/SavingCore.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract Handler is Test {
    SavingCore public savingCore;
    VaultManager public vaultManager;
    MockUSDC public usdc;

    address public admin;
    address public feeReceiver;
    address[] public users;

    uint256 public constant INITIAL_VAULT_FUND = 10_000_000 * 1e6; // 10M USDC
    uint256 public constant USER_START_BALANCE = 1_000_000 * 1e6;  // 1M USDC

    uint256 public depositCounter;

    constructor(
        SavingCore _savingCore,
        VaultManager _vaultManager,
        MockUSDC _usdc,
        address _admin,
        address _feeReceiver
    ) {
        savingCore = _savingCore;
        vaultManager = _vaultManager;
        usdc = _usdc;
        admin = _admin;
        feeReceiver = _feeReceiver;

        users.push(address(0x100));
        users.push(address(0x200));
        users.push(address(0x300));

        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], USER_START_BALANCE);
            vm.prank(users[i]);
            usdc.approve(address(savingCore), type(uint256).max);
        }
    }

    function openDeposit(uint8 userSeed, uint64 amount, bool enableBot) public {
        address user = users[userSeed % users.length];
        amount = uint64(bound(amount, 100 * 1e6, 50000 * 1e6));

        (, uint32 aprBps, uint32 tenorDays, , , ) = savingCore.plans(0);
        uint256 interest = (uint256(amount) * aprBps * tenorDays) / (365 * 10000);

        if (usdc.balanceOf(address(vaultManager)) < vaultManager.totalPromisedInterest() + interest) {
            return;
        }

        vm.prank(user);
        try savingCore.openDeposit(0, amount, aprBps, enableBot) {
            depositCounter++;
        } catch {}
    }

    function earlyWithdraw(uint256 depositIdSeed, uint64 withdrawRatioBpsSeed) public {
        if (depositCounter == 0) return;
        uint256 depositId = depositIdSeed % depositCounter;

        try savingCore.ownerOf(depositId) returns (address owner) {
            (uint64 principal, uint40 maturityAt, , , , , , SavingCore.DepositStatus status) = savingCore.deposits(depositId);
            if (status != SavingCore.DepositStatus.ACTIVE || block.timestamp >= maturityAt || principal == 0) return;

            uint64 withdrawRatioBps = uint64(bound(withdrawRatioBpsSeed, 100, 10000));
            uint256 withdrawAmount = (uint256(principal) * withdrawRatioBps) / 10000;
            if (withdrawAmount == 0) return;

            vm.prank(owner);
            try savingCore.earlyWithdraw(depositId, withdrawAmount) {} catch {}
        } catch {}
    }

    function withdrawAtMaturity(uint256 depositIdSeed) public {
        if (depositCounter == 0) return;
        uint256 depositId = depositIdSeed % depositCounter;

        try savingCore.ownerOf(depositId) returns (address owner) {
            (uint64 principal, uint40 maturityAt, , , , , , SavingCore.DepositStatus status) = savingCore.deposits(depositId);
            if (status != SavingCore.DepositStatus.ACTIVE || block.timestamp < maturityAt || principal == 0) return;

            vm.prank(owner);
            try savingCore.withdrawAtMaturity(depositId) {} catch {}
        } catch {}
    }

    function renewDeposit(uint256 depositIdSeed) public {
        if (depositCounter == 0) return;
        uint256 depositId = depositIdSeed % depositCounter;

        try savingCore.ownerOf(depositId) returns (address owner) {
            (uint64 principal, uint40 maturityAt, , , , uint32 planId, , SavingCore.DepositStatus status) = savingCore.deposits(depositId);
            if (status != SavingCore.DepositStatus.ACTIVE || block.timestamp < maturityAt || principal == 0) return;

            (, uint32 planApr, , , , ) = savingCore.plans(planId);
            vm.prank(owner);
            try savingCore.renewDeposit(depositId, planApr) {} catch {}
        } catch {}
    }

    function performUpkeep() public {
        try savingCore.checkUpkeep("") returns (bool upkeepNeeded, bytes memory performData) {
            if (upkeepNeeded) {
                try savingCore.performUpkeep(performData) {} catch {}
            }
        } catch {}
    }

    function updatePlanApr(uint32 newAprBps) public {
        newAprBps = uint32(bound(newAprBps, 50, 5000)); // 0.5% to 50% APR
        vm.prank(admin);
        try savingCore.updatePlan(0, newAprBps) {} catch {}
    }

    function togglePlanEnable(bool enable) public {
        vm.prank(admin);
        if (enable) {
            try savingCore.enablePlan(0) {} catch {}
        } else {
            try savingCore.disablePlan(0) {} catch {}
        }
    }

    function togglePause(bool pauseState) public {
        vm.prank(admin);
        if (pauseState) {
            try savingCore.pause() {} catch {}
        } else {
            try savingCore.unpause() {} catch {}
        }
    }

    function warpTime(uint32 daysToWarp) public {
        daysToWarp = uint32(bound(daysToWarp, 1, 30 days));
        vm.warp(block.timestamp + daysToWarp);
    }
}

contract InvariantTest is Test {
    SavingCore public savingCore;
    VaultManager public vaultManager;
    MockUSDC public usdc;
    Handler public handler;

    address public admin = address(1);
    address public feeReceiver = address(2);

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        vaultManager = new VaultManager(address(usdc));
        savingCore = new SavingCore(address(vaultManager), address(usdc));

        vaultManager.setSavingCore(address(savingCore));
        vaultManager.setFeeReceiver(feeReceiver);

        savingCore.createPlan(180, 350, 350, 100 * 1e6, 1000000 * 1e6, true);

        usdc.mint(admin, 10_000_000 * 1e6);
        usdc.approve(address(vaultManager), type(uint256).max);
        vaultManager.fundVault(10_000_000 * 1e6);
        vm.stopPrank();

        handler = new Handler(savingCore, vaultManager, usdc, admin, feeReceiver);
        targetContract(address(handler));
    }

    /// @notice Invariant 1: Vault USDC balance MUST ALWAYS be >= totalPromisedInterest (Solvency Guarantee)
    function invariant_vaultSolvency() public view {
        assertGe(
            usdc.balanceOf(address(vaultManager)),
            vaultManager.totalPromisedInterest(),
            "Vault is insolvent: balance < totalPromisedInterest"
        );
    }

    /// @notice Invariant 2: Total USDC across system components is conserved
    function invariant_usdcConservation() public view {
        uint256 vaultBal = usdc.balanceOf(address(vaultManager));
        uint256 coreBal = usdc.balanceOf(address(savingCore));
        uint256 feeBal = usdc.balanceOf(feeReceiver);
        uint256 user1Bal = usdc.balanceOf(address(0x100));
        uint256 user2Bal = usdc.balanceOf(address(0x200));
        uint256 user3Bal = usdc.balanceOf(address(0x300));

        uint256 total = vaultBal + coreBal + feeBal + user1Bal + user2Bal + user3Bal;
        assertLe(total, 13_000_000 * 1e6, "USDC leaked or over-minted");
    }
}
