# Online Banking System: Architecture & Flaws Breakdown

## 1. System Architecture Overview
This project implements an on-chain Certificate of Deposit (CD) system. 
- A user locks up USDC for a fixed period (e.g., 180 days).
- In exchange, the system guarantees a fixed interest rate (APR) upon withdrawal at maturity.
- If an early withdrawal occurs, no interest is paid, and a percentage of the principal is deducted as a penalty on the withdrawn amount.
- The protocol strictly separates the bank's funds (used for interest payouts) from the users' principal deposits.

### The Deposit Lifecycle:
1. **Open:** User deposits USDC (e.g., 1,000 USDC). The contract mints an NFT certificate. The current APR, penalty rate, and tenor are "snapshotted" (`aprBpsAtOpen`, `penaltyBpsAtOpen`, `tenorDaysAtOpen`).
2. **Maturity:** The lockup period ends. The user returns the NFT and receives their original principal back plus yield calculated using snapshotted rates.
3. **Grace Period / Auto-Renew:** If the user enables automation (`enableBot = true`) and does not withdraw within 2 days after maturity, Chainlink Automation automatically rolls over the deposit in-place (saving gas), adopting the current active plan APR (`currentPlan.aprbps`).

---

## 2. Core Contracts & Functions

### Contract 1: `SavingCore.sol`
This is the core logic contract. It holds all user principal deposits, enforces business rules, and acts as the ERC721 NFT contract.
- `createPlan()` / `updatePlan()` / `enablePlan()` / `disablePlan()`: Admin functions to manage saving products.
- `openDeposit()`: Enforces plan status checks, `expectedAprBps` (slippage guard), and Full Reserve Pre-funding. Transfers USDC, snapshots plan details, and mints the NFT certificate.
- `withdrawAtMaturity()`: Verifies term completion, returns principal, transfers interest from `VaultManager`, and burns the NFT.
- `earlyWithdraw(depositId, amount)`: Deducts the penalty fee on the withdrawn portion, sends penalty to `feeReceiver`, and returns remaining principal to user. Reduces promised vault debt proportionally.
- `renewDeposit()`: Manual rollover mechanism. Calculates earned yield using snapshotted rates, compounds principal in-place, and locks into the active plan's current APR and tenor.
- `_autoRenewDeposit()` / `checkUpkeep()` / `performUpkeep()`: Chainlink Automation Keepers integration. Automatically rolls over mature deposits if `enableBot == true`, deducting a 1 USDC `AUTOMATION_FEE` from yield or liquidating micro-positions if unprofitable.

### Contract 2: `VaultManager.sol`
This is the treasury contract. It strictly holds the protocol's own liquidity, used exclusively for paying out yield (interest).
- `fundVault()`: Admin deposits USDC into the vault to pre-fund interest payouts.
- `withdrawVault()`: Admin removes USDC from the vault (guarded by Solvency Check).
- `increaseTotalPromisedInterest()` / `decreaseTotalPromisedInterest()`: Restricted accounting functions called by `SavingCore`.
- `setFeeReceiver()`: Admin configures the address that receives early withdrawal penalties.
- `pause()` / `unpause()`: Emergency switches to halt contract actions.

### Contract 3: `MockUSDC.sol`
- A simulated ERC20 USDC token with **6 decimals**. Used for testing to ensure mathematical precision matches real-world stablecoins.

---

## 3. Base Specification Vulnerabilities & Bonus Fixes

### Flaw 1: Hostage Principal & Empty Vault (Challenge C1 & C2 Solvency Solution)
- **The Flaw:** In the base spec, `withdrawAtMaturity()` reverts if `VaultManager` lacks sufficient funds to pay interest, holding user principal hostage.
- **The Solution:** Implemented **Full Reserve Yield Pre-funding** in `openDeposit()`, `renewDeposit()`, and `_autoRenewDeposit()`. The protocol checks `usdc.balanceOf(vault) >= totalPromisedInterest + newInterest` *before* accepting or extending any deposit. Combined with `VaultManager`'s Solvency Guard (`withdrawVault` cannot drop balance below `totalPromisedInterest`), the vault is mathematically guaranteed to be 100% pre-funded and solvent at all times!

### Flaw 2: The Treasury Solvency Problem (Challenge C2)
- **The Flaw:** The base spec allows the Admin to execute `withdrawVault()` and drain the entire vault at any time, risking insolvency before user maturities.
- **The Fix:** Implemented a solvency guard in `VaultManager.sol#withdrawVault()`. Tracks `totalPromisedInterest` across all active deposits and reverts if an admin withdrawal drops the vault balance below promised debt.

### Flaw 3: All-or-Nothing Early Withdrawals (Challenge C3)
- **The Flaw:** `earlyWithdraw()` forces users to liquidate their entire deposit and pay a penalty on the full principal amount.
- **The Fix:** Implemented partial early withdrawals `earlyWithdraw(depositId, withdrawAmount)`. Penalty applies strictly to `withdrawAmount`. The remaining principal stays active in the NFT certificate and continues earning yield.

### Flaw 4: Fragmented Deposits & Top-Up Flaw (Challenge C4 Omitted Analysis)
- **The Flaw:** Challenge C4 proposes top-up deposits to prevent NFT fragmentation.
- **The Omitted Decision:** We intentionally skipped C4 due to a severe **Game Theory and Yield Arbitrage Flaw**. Allowing users to inject fresh capital into an old deposit shortly before maturity exploits historical APRs and harms protocol profitability. NFT fragmentation is actually beneficial for bank health because it forces users to ladder investments at prevailing market rates.

---

## 4. Advanced Security Discoveries (Challenge C5)

### 1. Admin Frontrunning / Slippage Flaw
- **The Flaw:** When a user submits `openDeposit()`, an Admin could frontrun the transaction with `updatePlan()` to lower the APR.
- **The Fix:** Added `expectedAprBps` parameter to `openDeposit()`. Reverts if `expectedAprBps != plans[planId].aprbps`.

### 2. Forced Auto-Renew Lock-in Failsafe
- **The Flaw:** Mandatory bot auto-renewals trap delayed users for another full term (e.g., 180 days), forcing early withdrawal penalties if they need liquidity.
- **The Fix:** Implemented `enableBot` boolean flag in `openDeposit()`. If `enableBot == false`, `checkUpkeep()` ignores the deposit, allowing mature funds to sit safely idle so delayed users can withdraw 100% anytime without penalty.

### 3. Real-World Auto-Renew Rates & Obsolete Rate Arbitrage
- **The Flaw:** Base spec Section 3.5 suggests locking `autoRenewDeposit` to historical `aprBpsAtOpen`. If market rates drop, this creates a **User Arbitrage Exploit** where users deliberately let the bot auto-renew to drain the bank with obsolete high rates.
- **The Fix:** Aligned `renewDeposit()` and `autoRenewDeposit()` to update `userdeposit.aprBpsAtOpen = currentPlan.aprbps`, adopting active market rates matching real-world banking standards (HSBC, Chase, Yearn Finance).

### 4. Yield Bleed & Unprofitable Liquidation Engine
- **The Flaw:** Chainlink Keepers require automation fees. Micro-deposits earning tiny yield will slowly bleed their principal away over repeated bot cycles.
- **The Fix:** Implemented a 1 USDC `AUTOMATION_FEE` skimmed from yield. If `earnedInterest < AUTOMATION_FEE`, the system deducts the deficit from principal, refunds remaining capital to the user, and burns the deposit NFT to stop the bleeding immediately.
