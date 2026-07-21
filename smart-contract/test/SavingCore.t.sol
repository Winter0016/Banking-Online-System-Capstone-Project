// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {SavingCore} from "../src/SavingCore.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract SavingCoreTest is Test {
    SavingCore public savingCore;
    VaultManager public vaultManager;
    MockUSDC public usdc;

    address public admin = address(1);
    address public feeReceiver = address(2);
    address public alice = address(3);

    // Plan config based on variant (A=6, B=1) -> Tenor: 180 days, APR: 350 bps, Penalty: 350 bps
    uint32 constant PLAN_TENOR = 180;
    uint32 constant PLAN_APR_BPS = 350;
    uint32 constant PLAN_PENALTY_BPS = 350;
    uint64 constant PLAN_MIN_DEPOSIT = 100 * 1e6; // 100 USDC
    uint64 constant PLAN_MAX_DEPOSIT = 1000000 * 1e6; // 1M USDC

    function setUp() public {
        vm.startPrank(admin);

        // 1. Deploy contracts
        usdc = new MockUSDC();
        vaultManager = new VaultManager(address(usdc));
        savingCore = new SavingCore(address(vaultManager), address(usdc));

        // Setup Vault permissions and fee receiver
        vaultManager.setSavingCore(address(savingCore));
        vaultManager.setFeeReceiver(feeReceiver);
        
        // Vault must approve SavingCore to pull interest payouts
        vaultManager.approveUSDC(address(savingCore), type(uint256).max);

        // 2. Setup a SavingCore plan
        savingCore.createPlan(
            PLAN_TENOR,
            PLAN_APR_BPS,
            PLAN_PENALTY_BPS,
            PLAN_MIN_DEPOSIT,
            PLAN_MAX_DEPOSIT,
            true
        );

        // 3. Fund Vault for future interest
        usdc.mint(admin, 1000000 * 1e6); // 1 million USDC
        usdc.approve(address(vaultManager), type(uint256).max);
        vaultManager.fundVault(1000000 * 1e6);
        
        vm.stopPrank();

        // 4. Setup Alice
        usdc.mint(alice, 50000 * 1e6); // Alice gets 50,000 USDC
        vm.startPrank(alice);
        usdc.approve(address(savingCore), type(uint256).max);
        vm.stopPrank();
    }

    function test_openDeposit() public {
        uint64 depositAmount = 10000 * 1e6; // 10,000 USDC

        vm.startPrank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);
        vm.stopPrank();

        // Verify NFT minted to Alice
        assertEq(savingCore.ownerOf(0), alice);

        // Verify Vault debt increased
        // 10,000 * 3.50% * 180 / 365 = ~ 172.602739 USDC
        uint256 expectedInterest = (uint256(depositAmount) * PLAN_APR_BPS * PLAN_TENOR) / (365 * 10000);
        assertEq(vaultManager.totalPromisedInterest(), expectedInterest);

        // Verify Vault has enough money to cover the debt
        assertGe(usdc.balanceOf(address(vaultManager)), vaultManager.totalPromisedInterest());
    }

    function test_withdrawAtMaturity_Success() public {
        uint64 depositAmount = 10000 * 1e6;
        
        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        uint256 expectedInterest = (uint256(depositAmount) * PLAN_APR_BPS * PLAN_TENOR) / (365 * 10000);

        // Time travel!
        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        savingCore.withdrawAtMaturity(0);

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);

        // Alice should have gained back her principal + interest
        assertEq(aliceBalanceAfter - aliceBalanceBefore, depositAmount + expectedInterest);

        // Vault debt should be 0
        assertEq(vaultManager.totalPromisedInterest(), 0);
    }

    function test_partialEarlyWithdraw_Penalty() public {
        uint64 depositAmount = 10000 * 1e6;
        
        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        // Time travel only 50 days (NOT mature yet)
        vm.warp(block.timestamp + 50 days);

        uint256 withdrawAmount = 2000 * 1e6;
        uint256 expectedPenalty = (withdrawAmount * PLAN_PENALTY_BPS) / 10000;
        uint256 expectedReceive = withdrawAmount - expectedPenalty;

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 feeReceiverBalanceBefore = usdc.balanceOf(feeReceiver);
        uint256 vaultDebtBefore = vaultManager.totalPromisedInterest();

        vm.prank(alice);
        savingCore.earlyWithdraw(0, withdrawAmount);

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 feeReceiverBalanceAfter = usdc.balanceOf(feeReceiver);
        uint256 vaultDebtAfter = vaultManager.totalPromisedInterest();

        // 1. Check Alice received the correct amount (principal - penalty, no interest)
        assertEq(aliceBalanceAfter - aliceBalanceBefore, expectedReceive);

        // 2. Check penalty went to fee receiver
        assertEq(feeReceiverBalanceAfter - feeReceiverBalanceBefore, expectedPenalty);

        // 3. Check NFT still exists and Alice owns it (because she left 8,000 inside)
        assertEq(savingCore.ownerOf(0), alice);

        // 4. Check Vault Debt correctly decreased by the interest that the 2,000 would have earned
        uint256 interestShed = (withdrawAmount * PLAN_APR_BPS * PLAN_TENOR) / (365 * 10000);
        assertEq(vaultDebtBefore - vaultDebtAfter, interestShed);
    }
}
