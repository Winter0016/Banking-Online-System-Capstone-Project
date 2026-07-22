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
    address public bob = address(4);

    // Plan config based on personal variant (A=6, B=1)
    // Tenor: 180 days, APR: 350 bps (3.50%), Penalty: 350 bps (3.50%)
    uint32 constant PLAN_TENOR = 180;
    uint32 constant PLAN_APR_BPS = 350;
    uint32 constant PLAN_PENALTY_BPS = 350;
    uint64 constant PLAN_MIN_DEPOSIT = 100 * 1e6; // 100 USDC
    uint64 constant PLAN_MAX_DEPOSIT = 1000000 * 1e6; // 1,000,000 USDC

    function setUp() public {
        vm.startPrank(admin);

        // 1. Deploy contracts
        usdc = new MockUSDC();
        vaultManager = new VaultManager(address(usdc));
        savingCore = new SavingCore(address(vaultManager), address(usdc));

        // Setup Vault permissions and fee receiver
        vaultManager.setSavingCore(address(savingCore));
        vaultManager.setFeeReceiver(feeReceiver);
        vaultManager.approveUSDC(address(savingCore), type(uint256).max);

        // 2. Setup initial SavingCore plan (Plan 0)
        savingCore.createPlan(
            PLAN_TENOR,
            PLAN_APR_BPS,
            PLAN_PENALTY_BPS,
            PLAN_MIN_DEPOSIT,
            PLAN_MAX_DEPOSIT,
            true
        );

        // 3. Fund Vault with USDC for interest payouts
        usdc.mint(admin, 1000000 * 1e6); // 1 million USDC
        usdc.approve(address(vaultManager), type(uint256).max);
        vaultManager.fundVault(1000000 * 1e6);

        vm.stopPrank();

        // 4. Fund Alice and Bob
        usdc.mint(alice, 100000 * 1e6);
        usdc.mint(bob, 100000 * 1e6);

        vm.prank(alice);
        usdc.approve(address(savingCore), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(savingCore), type(uint256).max);
    }

    // ==========================================
    // 1. MOCK USDC & DEPLOYMENT TESTS (Task 6.2)
    // ==========================================

    function test_MockUSDC_DecimalsAndMint() public view {
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.balanceOf(alice), 100000 * 1e6);
    }

    // ==========================================
    // 2. ACCESS CONTROL RESTRICTIONS (Task 6.3)
    // ==========================================

    function test_createPlan_RevertNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        savingCore.createPlan(90, 400, 500, 100 * 1e6, 10000 * 1e6, true);
    }

    function test_updatePlan_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        savingCore.updatePlan(0, 500);

        vm.prank(admin);
        savingCore.updatePlan(0, 500);
        (, uint32 newApr, , , , ) = savingCore.plans(0);
        assertEq(newApr, 500);
    }

    function test_enableDisablePlan_OnlyOwner() public {
        vm.prank(admin);
        savingCore.disablePlan(0);
        (, , , , , bool enabled) = savingCore.plans(0);
        assertFalse(enabled);

        vm.prank(admin);
        savingCore.enablePlan(0);
        (, , , , , enabled) = savingCore.plans(0);
        assertTrue(enabled);
    }

    function test_VaultManager_OnlyOwnerFunctions() public {
        vm.startPrank(alice);

        vm.expectRevert();
        vaultManager.setFeeReceiver(alice);

        vm.expectRevert();
        vaultManager.setSavingCore(alice);

        vm.expectRevert();
        vaultManager.pause();

        vm.expectRevert();
        vaultManager.withdrawVault(100 * 1e6);

        vm.stopPrank();
    }

    // ==========================================
    // 3. OPEN DEPOSIT TESTS & REVERTS (Task 6.4)
    // ==========================================

    function test_openDeposit_HappyPath() public {
        uint64 depositAmount = 10000 * 1e6;

        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, true);

        // Verify NFT ownership
        assertEq(savingCore.ownerOf(0), alice);

        // Verify Vault promised debt increased
        uint256 expectedInterest = (uint256(depositAmount) *
            PLAN_APR_BPS *
            PLAN_TENOR) / (365 * 10000);
        assertEq(vaultManager.totalPromisedInterest(), expectedInterest);
    }

    function test_openDeposit_RevertSlippage() public {
        vm.prank(alice);
        vm.expectRevert("aprBps do not match");
        savingCore.openDeposit(0, 1000 * 1e6, PLAN_APR_BPS + 10, false);
    }

    function test_openDeposit_RevertDisabledPlan() public {
        vm.prank(admin);
        savingCore.disablePlan(0);

        vm.prank(alice);
        vm.expectRevert("plan is not enabled");
        savingCore.openDeposit(0, 1000 * 1e6, PLAN_APR_BPS, false);
    }

    function test_openDeposit_RevertMinMaxDeposit() public {
        vm.startPrank(alice);

        vm.expectRevert("principal is not in range");
        savingCore.openDeposit(0, 50 * 1e6, PLAN_APR_BPS, false); // Below min (100 USDC)

        vm.expectRevert("principal is not in range");
        savingCore.openDeposit(0, 2000000 * 1e6, PLAN_APR_BPS, false); // Above max (1M USDC)

        vm.stopPrank();
    }

    function test_openDeposit_RevertVaultUnderfunded() public {
        // Create an empty vault scenario
        vm.startPrank(admin);
        MockUSDC newUsdc = new MockUSDC();
        VaultManager emptyVault = new VaultManager(address(newUsdc));
        SavingCore newCore = new SavingCore(
            address(emptyVault),
            address(newUsdc)
        );
        emptyVault.setSavingCore(address(newCore));
        newCore.createPlan(
            PLAN_TENOR,
            PLAN_APR_BPS,
            PLAN_PENALTY_BPS,
            PLAN_MIN_DEPOSIT,
            PLAN_MAX_DEPOSIT,
            true
        );
        vm.stopPrank();

        newUsdc.mint(alice, 1000 * 1e6);
        vm.startPrank(alice);
        newUsdc.approve(address(newCore), type(uint256).max);

        vm.expectRevert("Vault underfunded: interest not pre-funded");
        newCore.openDeposit(0, 1000 * 1e6, PLAN_APR_BPS, false);
        vm.stopPrank();
    }

    // ==========================================
    // 4. WITHDRAW AT MATURITY TESTS (Task 3.2)
    // ==========================================

    function test_withdrawAtMaturity_Success() public {
        uint64 depositAmount = 10000 * 1e6;

        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        uint256 expectedInterest = (uint256(depositAmount) *
            PLAN_APR_BPS *
            PLAN_TENOR) / (365 * 10000);

        // Fast-forward to maturity
        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        savingCore.withdrawAtMaturity(0);

        assertEq(
            usdc.balanceOf(alice) - aliceBalBefore,
            depositAmount + expectedInterest
        );
        assertEq(vaultManager.totalPromisedInterest(), 0);
    }

    function test_withdrawAtMaturity_RevertNotOwner() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 1000 * 1e6, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        vm.prank(bob);
        vm.expectRevert("Not owner");
        savingCore.withdrawAtMaturity(0);
    }

    function test_withdrawAtMaturity_RevertNotMature() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 1000 * 1e6, PLAN_APR_BPS, false);

        // Warp to 1 second before maturity
        vm.warp(block.timestamp + (PLAN_TENOR * 1 days) - 1);

        vm.prank(alice);
        vm.expectRevert("Maturity not reached yet.");
        savingCore.withdrawAtMaturity(0);
    }

    function test_withdrawAtMaturity_RevertAlreadyClosed() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 1000 * 1e6, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        vm.startPrank(alice);
        savingCore.withdrawAtMaturity(0);

        vm.expectRevert(); // ERC721 ownerOf reverts for burned token
        savingCore.withdrawAtMaturity(0);
        vm.stopPrank();
    }

    // ==========================================
    // 5. EARLY WITHDRAWAL TESTS (Task 3.3 & C3)
    // ==========================================

    function test_earlyWithdraw_PartialExit() public {
        uint64 depositAmount = 10000 * 1e6;

        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + 30 days);

        uint256 withdrawAmount = 4000 * 1e6;
        uint256 expectedPenalty = (withdrawAmount * PLAN_PENALTY_BPS) / 10000;
        uint256 expectedReceive = withdrawAmount - expectedPenalty;

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        uint256 feeReceiverBalBefore = usdc.balanceOf(feeReceiver);

        vm.prank(alice);
        savingCore.earlyWithdraw(0, withdrawAmount);

        assertEq(usdc.balanceOf(alice) - aliceBalBefore, expectedReceive);
        assertEq(
            usdc.balanceOf(feeReceiver) - feeReceiverBalBefore,
            expectedPenalty
        );
        assertEq(savingCore.ownerOf(0), alice); // NFT remains active
    }

    function test_earlyWithdraw_FullExit() public {
        uint64 depositAmount = 5000 * 1e6;

        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        savingCore.earlyWithdraw(0, depositAmount);

        assertEq(vaultManager.totalPromisedInterest(), 0);
        vm.expectRevert(); // NFT burned
        savingCore.ownerOf(0);
    }

    function test_earlyWithdraw_RevertMaturityReached() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 1000 * 1e6, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        vm.prank(alice);
        vm.expectRevert("Maturity reached, use withdrawAtMaturity.");
        savingCore.earlyWithdraw(0, 500 * 1e6);
    }

    // ==========================================
    // 6. RENEWAL TESTS (Task 4.1, 4.2 & C5)
    // ==========================================

    function test_renewDeposit_ManualSuccess() public {
        uint64 depositAmount = 10000 * 1e6;

        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        uint256 expectedInterest = (uint256(depositAmount) *
            PLAN_APR_BPS *
            PLAN_TENOR) / (365 * 10000);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        // Admin updates plan APR to 500 bps (5.00%)
        vm.prank(admin);
        savingCore.updatePlan(0, 500);

        vm.prank(alice);
        savingCore.renewDeposit(0);

        // Verify principal compounded and new APR adopted
        (
            uint64 newPrincipal,
            uint40 newMaturity,
            uint32 newApr,
            ,
            ,
            ,
            ,

        ) = savingCore.deposits(0);
        assertEq(newPrincipal, depositAmount + uint64(expectedInterest));
        assertEq(newApr, 500);
        assertEq(newMaturity, uint40(block.timestamp + PLAN_TENOR * 1 days));
    }

    function test_renewDeposit_RevertDisabledPlan() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 1000 * 1e6, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        vm.prank(admin);
        savingCore.disablePlan(0);

        vm.prank(alice);
        vm.expectRevert("Plan is not enabled");
        savingCore.renewDeposit(0);
    }

    // ==========================================
    // 7. CHAINLINK AUTOMATION TESTS (Task 4.2)
    // ==========================================

    function test_checkUpkeep_GracePeriodEnforcement() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, true); // enableBot = true

        // Before maturity -> upkeep false
        (bool upkeepNeeded, ) = savingCore.checkUpkeep("");
        assertFalse(upkeepNeeded);

        // Exactly 2 days past maturity (grace period boundary) -> upkeep false
        vm.warp(block.timestamp + (PLAN_TENOR * 1 days) + 2 days);
        (upkeepNeeded, ) = savingCore.checkUpkeep("");
        assertFalse(upkeepNeeded);

        // 2 days + 1 second past maturity -> upkeep true
        vm.warp(block.timestamp + 1);
        bytes memory performData;
        (upkeepNeeded, performData) = savingCore.checkUpkeep("");
        assertTrue(upkeepNeeded);

        uint256[] memory ids = abi.decode(performData, (uint256[]));
        assertEq(ids.length, 1);
        assertEq(ids[0], 0);
    }

    function test_autoRenewDeposit_Profitable() public {
        uint64 depositAmount = 10000 * 1e6;

        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, true);

        vm.warp(block.timestamp + (PLAN_TENOR * 1 days) + 2 days + 1);

        (, bytes memory performData) = savingCore.checkUpkeep("");

        uint256 feeReceiverBalBefore = usdc.balanceOf(feeReceiver);

        savingCore.performUpkeep(performData);

        // Verify automation fee (1 USDC = 1,000,000 units) sent to fee receiver
        assertEq(usdc.balanceOf(feeReceiver) - feeReceiverBalBefore, 1_000_000);
    }

    function test_autoRenewDeposit_UnprofitableLiquidation() public {
        // Small deposit (10 USDC) yielding ~0.17 USDC interest < 1 USDC fee
        uint64 smallDeposit = 10 * 1e6;

        vm.startPrank(admin);
        savingCore.createPlan(
            PLAN_TENOR,
            PLAN_APR_BPS,
            PLAN_PENALTY_BPS,
            10 * 1e6,
            PLAN_MAX_DEPOSIT,
            true
        );
        vm.stopPrank();

        vm.prank(alice);
        savingCore.openDeposit(1, smallDeposit, PLAN_APR_BPS, true);

        vm.warp(block.timestamp + (PLAN_TENOR * 1 days) + 2 days + 1);

        (, bytes memory performData) = savingCore.checkUpkeep("");

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        savingCore.performUpkeep(performData);

        // Liquidation engine triggered: NFT burned and remaining principal refunded to Alice
        vm.expectRevert(); // burned NFT
        savingCore.ownerOf(1);

        assertGt(usdc.balanceOf(alice), aliceBalBefore);
    }

    // ==========================================
    // 8. SOLVENCY GUARD TESTS (Challenge C2)
    // ==========================================

    function test_withdrawVault_RevertSolvencyGuard() public {
        uint64 depositAmount = 100000 * 1e6;

        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        uint256 vaultBal = usdc.balanceOf(address(vaultManager));

        vm.startPrank(admin);
        // Admin attempts to withdraw more than (balance - promisedInterest)
        vm.expectRevert(
            "total promised interest is greater than the withdraw amount"
        );
        vaultManager.withdrawVault(vaultBal);
        vm.stopPrank();
    }
}
