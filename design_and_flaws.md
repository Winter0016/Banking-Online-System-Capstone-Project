# Online Banking System: Architecture & Flaws Breakdown

## 1. System Architecture Overview
This project implements an on-chain Certificate of Deposit (CD) system. 
- A user locks up USDC for a fixed period (e.g., 180 days).
- In exchange, the system guarantees a fixed interest rate (APR) upon withdrawal at maturity.
- If an early withdrawal occurs, no interest is paid, and a percentage of the principal is deducted as a penalty.
- The protocol strictly separates the bank's funds (used for interest payouts) from the users' principal deposits.

### The Deposit Lifecycle:
1. **Open:** User deposits USDC (e.g. 1,000 USDC). The contract mints an NFT certificate. The current APR and penalty rates are "snapshotted" (saved onto that specific deposit).
2. **Maturity:** The lockup period ends. The user returns the NFT and receives their original principal back, plus interest calculated using the snapshotted APR. 
3. **Grace Period / Auto-Renew:** If the user does not withdraw within 2 days after maturity, a bot automatically reinvests the principal and earned interest into a new cycle, protecting the original APR.

---

## 2. Core Contracts & Functions

### Contract 1: `SavingCore.sol`
This is the core logic contract. It holds all user principal deposits, enforces business rules, and acts as the ERC721 NFT contract.
- `createPlan()` / `updatePlan()` / `enablePlan()` / `disablePlan()`: Admin functions to manage saving products.
- `openDeposit()`: Transfers USDC from the user, saves plan details, and mints the NFT certificate.
- `withdrawAtMaturity()`: Verifies term completion, returns principal, requests `VaultManager` to send interest, and burns the NFT.
- `earlyWithdraw()`: Deducts the penalty fee (e.g., 3.5%), sends the penalty to the admin fee receiver, and returns the remaining principal to the user. Zero interest is paid.
- `renewDeposit()`: Manual rollover mechanism. Calculates interest, adds it to the principal, and starts a new deposit term.
- `autoRenewDeposit()`: Executed by an off-chain bot after the grace period ends. Automatically rolls over the deposit using the original locked-in APR.

### Contract 2: `VaultManager.sol`
This is the treasury contract. It strictly holds the protocol's own liquidity, used exclusively for paying out yield (interest).
- `fundVault()`: Admin deposits USDC into the vault to ensure sufficient liquidity for interest payouts.
- `withdrawVault()`: Admin removes USDC from the vault.
- `setFeeReceiver()`: Admin configures the address that receives early withdrawal penalties.
- `pause()` / `unpause()`: Emergency switches to halt deposits and withdrawals.

### Contract 3: `MockUSDC.sol`
- A simulated ERC20 USDC token with 6 decimals. Used for testing to ensure mathematical precision matches real-world stablecoins.

---

## 3. Base Specification Vulnerabilities & Bonus Fixes

The base specification contains intentional architectural flaws. Identifying and mitigating these vulnerabilities is the focus of the bonus challenges.

### Flaw 1: The "Hostage Principal" Problem (Challenge C1)
- **The Flaw:** In the base spec, `withdrawAtMaturity()` reverts if the `VaultManager` lacks sufficient funds to pay the interest.
- **Vulnerability:** An admin could hold user principal hostage indefinitely by intentionally underfunding the vault.
- **The Fix:** Modify the withdrawal logic so that if the vault is underfunded, users immediately receive their principal and the contract records an IOU (debt) for the pending interest.

### Flaw 2: The Solvency Problem (Challenge C2)
- **The Flaw:** The base spec allows the Admin to execute `withdrawVault()` and drain the entire vault at any time.
- **Vulnerability:** An admin could drain the vault before major interest payouts, rendering the protocol insolvent.
- **The Fix:** Implement a solvency guard. Track the total "promised" interest across all active deposits. `withdrawVault()` must revert if a withdrawal drops the vault balance below the `totalPromisedInterest`.

### Flaw 3: All-or-Nothing Withdrawals (Challenge C3)
- **The Flaw:** `earlyWithdraw()` forces users to withdraw their entire deposit and suffer the penalty on the full amount.
- **Vulnerability:** Poor user experience. Users cannot liquidate small portions of their deposit for emergency liquidity.
- **The Fix:** Implement `partialEarlyWithdraw(amount)`. The penalty is only applied to the withdrawn amount, while the remaining principal continues earning interest.

### Flaw 4: Fragmented Deposits (Challenge C4)
- **The Flaw:** Users wishing to add funds to an existing plan must open a separate deposit, minting a new NFT.
- **Vulnerability:** Leads to fragmented liquidity, multiple NFTs with different maturity dates, and excessive gas costs.
- **The Fix:** Implement "Top-Ups", allowing users to add principal to an active deposit. This requires complex time-weighted interest calculations for the new combined principal.

---

## 4. Advanced Vulnerability Discovery (Challenge C5)

Beyond the documented flaws, the architecture contains several hidden, real-world DeFi vulnerabilities that can be mitigated for Challenge C5.

### Idea A: Frontrunning / Slippage Flaw
- **The Flaw:** When a user calls `openDeposit()`, they expect the current APR. If an Admin calls `updatePlan()` to lower the APR and frontruns the user's transaction, the user is locked into a lower rate against their will.
- **The Fix:** Implement "Slippage Protection". Update `openDeposit` to accept a `minExpectedApr` parameter. The transaction reverts if the current APR is below this threshold.

### Idea B: The Auto-Renew "Griefing" Vector
- **The Flaw:** The off-chain bot automatically renews a deposit after the grace period. If a user intends to withdraw but is delayed, the bot force-locks their funds for another full term, forcing them to take an early withdrawal penalty to access their money.
- **The Fix:** Add an `optInToAutoRenew` flag during `openDeposit()`. If false, the bot is blocked from renewing the deposit, allowing funds to sit idle safely.

### Idea C: The "Ragequit" / Centralization Risk
- **The Flaw:** The `VaultManager` has a `pause()` function. A compromised admin key could pause the system indefinitely, permanently freezing user principal.
- **The Fix:** Implement a "Time-locked Escape Hatch." If the system remains paused for a continuous duration (e.g., 7 days), users can call an `emergencyRagequit()` function to bypass the pause and withdraw their principal (forfeiting interest).

### Idea D: The Illiquid Yield Constraint
- **The Flaw:** Users must wait the entire term to access any earned interest, which is capital inefficient compared to modern DeFi protocols.
- **The Fix:** Implement a `claimInterest(depositId)` function. This calculates interest earned up to the current block timestamp and transfers it to the user, updating a `lastClaimedAt` timestamp to prevent double-claiming, without breaking the principal lock.
