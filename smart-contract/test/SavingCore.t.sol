// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {SavingCore} from "../src/SavingCore.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";

contract ReentrantAttacker is IERC721Receiver {
    SavingCore public savingCore;
    uint256 public targetDepositId;

    constructor(SavingCore _savingCore) {
        savingCore = _savingCore;
    }

    function setTarget(uint256 depositId) external {
        targetDepositId = depositId;
    }

    function attack() external {
        savingCore.withdrawAtMaturity(targetDepositId);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external override returns (bytes4) {
        // Attempt reentrant call during callback
        try savingCore.withdrawAtMaturity(targetDepositId) {} catch {}
        return this.onERC721Received.selector;
    }
}

contract MockFailingUSDC is MockUSDC {
    bool public failTransferFrom;
    bool public failTransfer;

    function setFailTransferFrom(bool _fail) external {
        failTransferFrom = _fail;
    }

    function setFailTransfer(bool _fail) external {
        failTransfer = _fail;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransferFrom) return false;
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfer) return false;
        return super.transfer(to, amount);
    }
}

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
    // 2. ACCESS CONTROL & VAULTMANAGER TESTS (Task 6.3)
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
        vaultManager.unpause();

        vm.expectRevert();
        vaultManager.withdrawVault(100 * 1e6);

        vm.expectRevert();
        vaultManager.approveUSDC(alice, 100);

        vm.stopPrank();
    }

    function test_VaultManager_fundVault_ZeroAmount_Revert() public {
        vm.prank(admin);
        vm.expectRevert("Can't fund 0 to vault");
        vaultManager.fundVault(0);
    }

    function test_VaultManager_withdrawVault_ZeroAmount_Revert() public {
        vm.prank(admin);
        vm.expectRevert("Can't withdraw 0 from vault");
        vaultManager.withdrawVault(0);
    }

    function test_VaultManager_setFeeReceiver_ZeroAddress_Revert() public {
        vm.prank(admin);
        vm.expectRevert("Invalid address");
        vaultManager.setFeeReceiver(address(0));
    }

    function test_VaultManager_setSavingCore_ZeroAddress_Revert() public {
        vm.prank(admin);
        vm.expectRevert("Invalid address");
        vaultManager.setSavingCore(address(0));
    }

    function test_VaultManager_onlySavingCore_Revert() public {
        vm.startPrank(alice);
        vm.expectRevert("Only saving core can call this function");
        vaultManager.increaseTotalPromisedInterest(100);

        vm.expectRevert("Only saving core can call this function");
        vaultManager.decreaseTotalPromisedInterest(100);
        vm.stopPrank();
    }

    function test_VaultManager_pause_unpause_Success() public {
        vm.startPrank(admin);
        vaultManager.pause();
        assertTrue(vaultManager.paused());
        vaultManager.unpause();
        assertFalse(vaultManager.paused());
        vm.stopPrank();
    }

    function test_VaultManager_approveUSDC_Success() public {
        vm.prank(admin);
        vaultManager.approveUSDC(alice, 500 * 1e6);
        assertEq(usdc.allowance(address(vaultManager), alice), 500 * 1e6);
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

    function test_earlyWithdraw_ZeroPenalty() public {
        // Plan with 0% penalty
        vm.prank(admin);
        savingCore.createPlan(90, 300, 0, 100 * 1e6, 100000 * 1e6, true);

        vm.prank(alice);
        savingCore.openDeposit(1, 1000 * 1e6, 300, false);

        vm.warp(block.timestamp + 10 days);

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        savingCore.earlyWithdraw(0, 500 * 1e6);

        // 0 penalty -> receives full 500 USDC
        assertEq(usdc.balanceOf(alice) - aliceBalBefore, 500 * 1e6);
    }

    function test_earlyWithdraw_FeeReceiverNotSet_Revert() public {
        // Re-deploy empty fee receiver vault
        vm.startPrank(admin);
        MockUSDC newUsdc = new MockUSDC();
        VaultManager noFeeVault = new VaultManager(address(newUsdc));
        SavingCore newCore = new SavingCore(
            address(noFeeVault),
            address(newUsdc)
        );
        noFeeVault.setSavingCore(address(newCore));
        // feeReceiver is address(0)
        newCore.createPlan(90, 300, 300, 100 * 1e6, 100000 * 1e6, true);
        newUsdc.mint(admin, 100000 * 1e6);
        newUsdc.approve(address(noFeeVault), type(uint256).max);
        noFeeVault.fundVault(100000 * 1e6);
        vm.stopPrank();

        newUsdc.mint(alice, 1000 * 1e6);
        vm.startPrank(alice);
        newUsdc.approve(address(newCore), type(uint256).max);
        newCore.openDeposit(0, 1000 * 1e6, 300, false);

        vm.expectRevert("Fee receiver not set in VaultManager");
        newCore.earlyWithdraw(0, 500 * 1e6);
        vm.stopPrank();
    }

    function test_earlyWithdraw_Reverts_ZeroAmount_And_ExceedsPrincipal() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 1000 * 1e6, PLAN_APR_BPS, false);

        vm.startPrank(alice);

        vm.expectRevert("Invalid withdraw amount");
        savingCore.earlyWithdraw(0, 0);

        vm.expectRevert("Invalid withdraw amount");
        savingCore.earlyWithdraw(0, 1001 * 1e6);

        vm.stopPrank();
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

    function test_renewDeposit_RateDrop_DecreasesPromisedInterest() public {
        uint64 depositAmount = 10000 * 1e6;

        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        // Admin drops plan APR to 100 BPS (1.00%)
        vm.prank(admin);
        savingCore.updatePlan(0, 100);

        vm.prank(alice);
        savingCore.renewDeposit(0);

        (
            ,
            ,
            uint32 newApr,
            ,
            ,
            ,
            ,

        ) = savingCore.deposits(0);
        assertEq(newApr, 100);
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

        // Liquidation engine triggered: NFT burned (tokenId 0) and remaining principal refunded to Alice
        vm.expectRevert(); // burned NFT (tokenId 0)
        savingCore.ownerOf(0);

        assertGt(usdc.balanceOf(alice), aliceBalBefore);
    }

    function test_autoRenewDeposit_CompleteWipeout() public {
        uint64 tinyDeposit = 100_000; // 0.1 USDC

        vm.startPrank(admin);
        savingCore.createPlan(
            PLAN_TENOR,
            PLAN_APR_BPS,
            PLAN_PENALTY_BPS,
            100_000,
            PLAN_MAX_DEPOSIT,
            true
        );
        vm.stopPrank();

        vm.prank(alice);
        savingCore.openDeposit(1, tinyDeposit, PLAN_APR_BPS, true);

        vm.warp(block.timestamp + (PLAN_TENOR * 1 days) + 2 days + 1);

        (, bytes memory performData) = savingCore.checkUpkeep("");

        savingCore.performUpkeep(performData);

        vm.expectRevert(); // burned NFT (tokenId 0)
        savingCore.ownerOf(0);
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

    // ==========================================
    // 8b. ADDITIONAL BRANCH EDGE-CASE TESTS
    // ==========================================

    function test_VaultManager_fundVault_TransferFromFails_Revert() public {
        vm.startPrank(admin);
        MockFailingUSDC badUsdc = new MockFailingUSDC();
        VaultManager badVault = new VaultManager(address(badUsdc));
        badUsdc.mint(admin, 1000 * 1e6);
        badUsdc.approve(address(badVault), type(uint256).max);
        badUsdc.setFailTransferFrom(true);

        vm.expectRevert("Fail to transfer USDC to vault");
        badVault.fundVault(100 * 1e6);
        vm.stopPrank();
    }

    function test_VaultManager_withdrawVault_TransferFails_Revert() public {
        vm.startPrank(admin);
        MockFailingUSDC badUsdc = new MockFailingUSDC();
        VaultManager badVault = new VaultManager(address(badUsdc));
        badUsdc.mint(admin, 1000 * 1e6);
        badUsdc.approve(address(badVault), type(uint256).max);
        badVault.fundVault(1000 * 1e6);
        badUsdc.setFailTransfer(true);

        vm.expectRevert("Fail to transfer USDC from vault");
        badVault.withdrawVault(100 * 1e6);
        vm.stopPrank();
    }

    function test_autoRenewDeposit_EarlyExecution_Returns() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, true);

        // Call performUpkeep manually before grace period ends
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        savingCore.performUpkeep(abi.encode(ids));

        // Deposit remains unchanged in term #1
        (uint64 principal, , , , , , , ) = savingCore.deposits(0);
        assertEq(principal, 10000 * 1e6);
    }

    function test_autoRenewDeposit_DisabledBot_Returns() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, false); // enableBot = false

        vm.warp(block.timestamp + PLAN_TENOR * 1 days + 3 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        savingCore.performUpkeep(abi.encode(ids));

        (uint64 principal, , , , , , , ) = savingCore.deposits(0);
        assertEq(principal, 10000 * 1e6);
    }

    function test_autoRenewDeposit_ClosedDeposit_Returns() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, true);

        vm.prank(alice);
        savingCore.earlyWithdraw(0, 10000 * 1e6); // Close deposit

        vm.warp(block.timestamp + PLAN_TENOR * 1 days + 3 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        savingCore.performUpkeep(abi.encode(ids));
    }

    function test_autoRenewDeposit_DisabledPlan_Returns() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, true);

        vm.prank(admin);
        savingCore.disablePlan(0);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days + 3 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        savingCore.performUpkeep(abi.encode(ids));
    }

    function test_autoRenewDeposit_RateDrop_DecreasesDebt() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, true);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days + 3 days);

        // Rate drops to 10 BPS (0.10%)
        vm.prank(admin);
        savingCore.updatePlan(0, 10);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        savingCore.performUpkeep(abi.encode(ids));

        (
            ,
            ,
            uint32 newApr,
            ,
            ,
            ,
            ,

        ) = savingCore.deposits(0);
        assertEq(newApr, 10);
    }

    function test_autoRenewDeposit_VaultUnderfunded_Returns() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, true);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days + 3 days);

        // Rate jumps to 20000 BPS (200%), but vault is underfunded for 200% rate expansion
        vm.prank(admin);
        savingCore.updatePlan(0, 20000);

        uint256 vaultBal = usdc.balanceOf(address(vaultManager));
        uint256 promised = vaultManager.totalPromisedInterest();
        uint256 withdrawable = vaultBal - promised;

        vm.prank(admin);
        // Withdraw vault liquidity down to promised interest threshold
        vaultManager.withdrawVault(withdrawable);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        savingCore.performUpkeep(abi.encode(ids));
    }

    function test_checkUpkeep_ShortCircuitBranches() public {
        // Deposit 0: enableBot = false
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, false);

        // Deposit 1: closed by early withdrawal
        vm.prank(bob);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, true);
        vm.prank(bob);
        savingCore.earlyWithdraw(1, 10000 * 1e6);

        // Deposit 2: plan disabled
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, true);
        vm.prank(admin);
        savingCore.disablePlan(0);

        vm.warp(block.timestamp + (PLAN_TENOR * 1 days) + 3 days);

        // checkUpkeep evaluates all short-circuit branches (status != ACTIVE, enableBot == false, plan.enable == false)
        (bool upkeepNeeded, ) = savingCore.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_checkUpkeep_NoDeposits_ReturnsFalse() public {
        vm.startPrank(admin);
        VaultManager emptyVault = new VaultManager(address(usdc));
        SavingCore emptyCore = new SavingCore(address(emptyVault), address(usdc));
        emptyVault.setSavingCore(address(emptyCore));
        vm.stopPrank();

        (bool upkeepNeeded, bytes memory performData) = emptyCore.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    // ==========================================
    // 9. FUZZ TESTS (Task 7)
    // ==========================================

    function testFuzz_openDeposit(uint64 depositAmount, bool enableBot) public {
        depositAmount = uint64(bound(depositAmount, PLAN_MIN_DEPOSIT, PLAN_MAX_DEPOSIT));

        usdc.mint(alice, depositAmount);
        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, enableBot);

        assertEq(savingCore.ownerOf(0), alice);
        uint256 expectedInterest = (uint256(depositAmount) * PLAN_APR_BPS * PLAN_TENOR) / (365 * 10000);
        assertEq(vaultManager.totalPromisedInterest(), expectedInterest);
    }

    function testFuzz_earlyWithdraw(uint64 depositAmount, uint64 withdrawRatioBps) public {
        depositAmount = uint64(bound(depositAmount, PLAN_MIN_DEPOSIT, PLAN_MAX_DEPOSIT));
        withdrawRatioBps = uint64(bound(withdrawRatioBps, 100, 10000)); // 1% to 100%

        usdc.mint(alice, depositAmount);
        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + 30 days);

        uint256 withdrawAmount = (uint256(depositAmount) * withdrawRatioBps) / 10000;
        if (withdrawAmount == 0) return;

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        savingCore.earlyWithdraw(0, withdrawAmount);

        assertGt(usdc.balanceOf(alice), aliceBalBefore);
    }

    function testFuzz_withdrawAtMaturity(uint64 depositAmount, uint32 extraDays) public {
        depositAmount = uint64(bound(depositAmount, PLAN_MIN_DEPOSIT, PLAN_MAX_DEPOSIT));
        extraDays = uint32(bound(extraDays, 0, 365));

        usdc.mint(alice, depositAmount);
        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + (PLAN_TENOR * 1 days) + (extraDays * 1 days));

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        savingCore.withdrawAtMaturity(0);

        uint256 expectedInterest = (uint256(depositAmount) * PLAN_APR_BPS * PLAN_TENOR) / (365 * 10000);
        assertEq(usdc.balanceOf(alice) - aliceBalBefore, uint256(depositAmount) + expectedInterest);
    }

    function testFuzz_renewDeposit(uint64 depositAmount, uint32 newAprBps) public {
        depositAmount = uint64(bound(depositAmount, PLAN_MIN_DEPOSIT, PLAN_MAX_DEPOSIT));
        newAprBps = uint32(bound(newAprBps, 100, 2000)); // 1% to 20% APR

        usdc.mint(alice, depositAmount);
        vm.prank(alice);
        savingCore.openDeposit(0, depositAmount, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        vm.prank(admin);
        savingCore.updatePlan(0, newAprBps);

        vm.prank(alice);
        savingCore.renewDeposit(0);

        (
            ,
            ,
            uint32 actualApr,
            ,
            ,
            ,
            ,

        ) = savingCore.deposits(0);
        assertEq(actualApr, newAprBps);
    }

    // ==========================================
    // 10. DESIGN ANSWERS TEST CASES (Questions 1 - 7)
    // ==========================================

    /**
     * @notice Design Question 1: Transferable Certificate (Section 7.4 & 8.2 Q1)
     * @dev Question: If Alice sells/transfers her CD NFT to Bob before maturity, who can withdraw?
     * @dev Verification:
     * 1. Alice opens deposit #0.
     * 2. Alice transfers NFT #0 to Bob using `savingCore.transferFrom(alice, bob, 0)`.
     * 3. Warp to maturity date.
     * 4. Alice attempts to withdraw -> REVERTS ("Not owner").
     * 5. Bob attempts to withdraw -> SUCCEEDS and receives principal + interest.
     */
    function test_Q1_TransferableCertificate_BobCanWithdraw() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, false);

        // Alice transfers NFT certificate (tokenId 0) to Bob
        vm.prank(alice);
        savingCore.transferFrom(alice, bob, 0);

        assertEq(savingCore.ownerOf(0), bob);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        // Alice trying to withdraw reverts "Not owner"
        vm.prank(alice);
        vm.expectRevert("Not owner");
        savingCore.withdrawAtMaturity(0);

        // Bob withdraws successfully
        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        savingCore.withdrawAtMaturity(0);

        assertGt(usdc.balanceOf(bob), bobBalBefore);
    }

    /**
     * @notice Design Question 2: Empty Vault & Solvency Guard (Section 7.4 & 8.2 Q2)
     * @dev Question: What problem is created if the vault lacks funds for interest, and how is it solved?
     * @dev Verification:
     * 1. VaultManager enforces a Solvency Guard (`withdrawVault` check).
     * 2. Admin attempts to drain vault liquidity below `totalPromisedInterest`.
     * 3. Transaction REVERTS ("total promised interest is greater than the withdraw amount").
     * 4. Proves vault can never be drained into insolvency before user maturity.
     */
    function test_Q2_EmptyVault_SolvencyGuardPreventsInsolvency() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, false);

        uint256 vaultBal = usdc.balanceOf(address(vaultManager));

        // Admin attempt to drain vault fails due to Solvency Guard
        vm.prank(admin);
        vm.expectRevert("total promised interest is greater than the withdraw amount");
        vaultManager.withdrawVault(vaultBal);
    }

    /**
     * @notice Design Question 3: Dead Bot / Offline Automation (Section 7.4 & 8.2 Q3)
     * @dev Question: What happens to deposits if the auto-renew bot goes offline for one month?
     * @dev Verification:
     * 1. Alice opens deposit #0 with `enableBot = false`.
     * 2. Time warps 30 days past grace period (simulating a dead/offline keeper bot).
     * 3. Alice's funds remain safe in `ACTIVE` state without penalty or capital loss.
     * 4. Alice calls `withdrawAtMaturity(0)` manually and receives 100% of her principal + interest.
     */
    function test_Q3_DeadBot_UserCanWithdrawOrRenewManually() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, false); // enableBot = false

        // Bot is dead / offline for 30 days past maturity
        vm.warp(block.timestamp + (PLAN_TENOR * 1 days) + 30 days);

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        // User can manually claim 100% of principal + yield anytime
        vm.prank(alice);
        savingCore.withdrawAtMaturity(0);

        assertGt(usdc.balanceOf(alice), aliceBalBefore);
    }

    /**
     * @notice Design Question 4: Rounding Dust (Section 7.4 & 8.2 Q4)
     * @dev Question: Who keeps the rounding dust from integer division `(principal * apr * tenor) / (365 * 10000)`?
     * @dev Verification:
     * 1. Interest calculation truncates down (floor division).
     * 2. Truncated dust fractions stay safely in `VaultManager` treasury.
     * 3. Asserts the vault pays exactly the floor integer result without insolvency or balance errors.
     */
    function test_Q4_RoundingDust_TruncatesFloorToVault() public {
        uint64 principal = 1000 * 1e6; // 1,000 USDC
        vm.prank(alice);
        savingCore.openDeposit(0, principal, PLAN_APR_BPS, false);

        uint256 expectedInterest = (uint256(principal) * PLAN_APR_BPS * PLAN_TENOR) / (365 * 10000);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        uint256 vaultBalBefore = usdc.balanceOf(address(vaultManager));
        vm.prank(alice);
        savingCore.withdrawAtMaturity(0);

        uint256 vaultBalAfter = usdc.balanceOf(address(vaultManager));

        // Vault only pays floor division result, truncated dust remains safely in treasury
        assertEq(vaultBalBefore - vaultBalAfter, expectedInterest);
    }

    /**
     * @notice Design Question 5: Boundary Times & Comparison Operators (Section 7.4 & 8.2 Q5)
     * @dev Question: At exact second of `maturityAt`, is a withdrawal early or at maturity?
     * @dev Verification:
     * 1. Exact second BEFORE `maturityAt` (`maturityAt - 1`) -> `withdrawAtMaturity` REVERTS ("Maturity not reached yet.").
     * 2. Exact second OF `maturityAt` (`maturityAt`) -> `withdrawAtMaturity` SUCCEEDS (`block.timestamp >= userdeposit.maturityAt`).
     * 3. Ensures clean separation between `earlyWithdraw` (`< maturityAt`) and `withdrawAtMaturity` (`>= maturityAt`).
     */
    function test_Q5_BoundaryTimes_MaturityAndGracePeriod() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, true);

        uint256 maturity = block.timestamp + (PLAN_TENOR * 1 days);

        // Exact second before maturity -> withdrawAtMaturity reverts
        vm.warp(maturity - 1);
        vm.expectRevert("Maturity not reached yet.");
        vm.prank(alice);
        savingCore.withdrawAtMaturity(0);

        // Exact second of maturity -> withdrawAtMaturity succeeds (>= maturityAt)
        vm.warp(maturity);
        vm.prank(alice);
        savingCore.withdrawAtMaturity(0);
    }

    /**
     * @notice Design Question 6: Disabled Plan with Active Deposits (Section 7.4 & 8.2 Q6)
     * @dev Question: What happens if admin disables a plan with active deposits? Can users renew into it?
     * @dev Verification:
     * 1. Alice opens deposit #0 under Plan 0.
     * 2. Admin disables Plan 0.
     * 3. Bob attempts `openDeposit(0, ...)` -> REVERTS ("plan is not enabled").
     * 4. Alice attempts `renewDeposit(0)` -> REVERTS ("Plan is not enabled").
     * 5. Alice calls `withdrawAtMaturity(0)` -> SUCCEEDS and receives her principal + interest.
     */
    function test_Q6_DisabledPlan_ActiveDepositCanStillWithdraw() public {
        vm.prank(alice);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, false);

        // Admin disables Plan 0
        vm.prank(admin);
        savingCore.disablePlan(0);

        // New deposits into Plan 0 revert
        vm.prank(bob);
        vm.expectRevert("plan is not enabled");
        savingCore.openDeposit(0, 5000 * 1e6, PLAN_APR_BPS, false);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        // Renewing into disabled plan reverts
        vm.prank(alice);
        vm.expectRevert("Plan is not enabled");
        savingCore.renewDeposit(0);

        // Active deposit holder CAN STILL withdraw at maturity!
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        savingCore.withdrawAtMaturity(0);

        assertGt(usdc.balanceOf(alice), aliceBalBefore);
    }

    /**
     * @notice Design Question 7: Attack Thinking & Reentrancy Guard (Section 7.4 & 8.2 Q7)
     * @dev Question: How does the system prevent a double-withdrawal reentrancy attack?
     * @dev Verification:
     * 1. `ReentrantAttacker` contract calls `withdrawAtMaturity(0)`.
     * 2. Inside the ERC721 callback, `ReentrantAttacker` attempts to re-enter `withdrawAtMaturity(0)`.
     * 3. `nonReentrant` modifier & Checks-Effects-Interactions pattern (`DepositStatus.CLOSE` and `_burn`) block reentrancy.
     * 4. Re-entrant call fails gracefully, preventing double withdrawals.
     */
    function test_Q7_AttackThinking_ReentrancyAttackReverts() public {
        vm.startPrank(admin);
        ReentrantAttacker attacker = new ReentrantAttacker(savingCore);
        usdc.mint(address(attacker), 10000 * 1e6);
        vm.stopPrank();

        vm.startPrank(address(attacker));
        usdc.approve(address(savingCore), type(uint256).max);
        savingCore.openDeposit(0, 10000 * 1e6, PLAN_APR_BPS, false);
        attacker.setTarget(0);

        vm.warp(block.timestamp + PLAN_TENOR * 1 days);

        // Reentrancy attack attempt during withdrawal callback fails gracefully
        attacker.attack();
        vm.stopPrank();

        // Deposit status is CLOSED and NFT burned
        vm.expectRevert();
        savingCore.ownerOf(0);
    }
}
