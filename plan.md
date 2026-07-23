# Capstone Implementation Plan (Online Banking System)

## Personal Variant (Student ID ends in ...16)
- **A (Last Digit)** = 6
- **B (Second-to-last Digit)** = 1


- **Grace period (auto-renew):** 2 days *(calculated as (6 mod 3) + 2)*
- **Default plan APR:** 3.50% / 350 bps *(calculated as 200 + 6 * 25)*
- **Early withdraw penalty:** 3.50% / 350 bps *(calculated as 300 + 1 * 50)*
- **Default plan tenor:** 180 days *(calculated because B=1 is odd)*

**Framework:** Foundry
**Bonus Challenges:** C1 (Safe Principal), C2 (Solvency Guard), C3 (Partial Early Withdraw), C4 (Top-Up), C5 (Slippage Protection,The Auto-Renew "Griefing" Flaw,Centralization Flaw when pausing, The Illiquid Yield Flaw,....etc).

---

## Project Overview & Architecture

### What is this project?
This is a decentralized Online Banking System that allows users to deposit USDC into fixed-term savings plans. Upon depositing, users receive an ERC721 NFT that acts as their "Certificate of Deposit". The NFT represents their underlying principal and the promised interest they will earn at the end of the lockup period (tenor).

### Smart Contract Architecture
The protocol is strictly separated into two main contracts to follow the **Separation of Concerns** security pattern:

#### 1. VaultManager (The Treasury)
- **Role:** Acts as the bank vault. It securely holds all user USDC deposits and is responsible for paying out interest.
- **Base Functionality:** It allows the Admin to fund the vault with USDC, set the fee receiver for penalties, and provides an Emergency Stop (Pause) button to halt the system if needed.
- **Access:** Regular users do not interact with this contract directly. It is only called by the `SavingCore` contract to process deposits/withdrawals, and by the Admin to fund or withdraw from the vault.

#### 2. SavingCore (The Logic & Receipt Token)
- **Role:** The brain of the system. It handles all the banking rules, calculates interest, manages the time-locks, and issues the ERC721 receipt NFTs to users.
- **Base Functionality:** It enforces the core banking rules: users lock tokens to earn interest, suffer a penalty for early withdrawals, and can renew deposits manually or automatically.
- **Access:** 
  - **Admin:** Interacts with this contract to create, update, enable, and disable various savings plans.
  - **Users:** Interacts with this contract to open deposits, claim their funds when the lockup period ends, perform early withdrawals, or renew their deposits.

#### 3. MockUSDC (The Test Token)
- **Role:** A simulated version of the real-world USDC stablecoin. It is hardcoded to 6 decimals (just like real USDC) to ensure the system's math works flawlessly in a real mainnet environment.

### Basic User Flow
1. **Admin** creates a Savings Plan (e.g., 180 days, 3.5% APR).
2. **Admin** funds the treasury with USDC to cover future interest payments.
3. **User** opens a deposit. Their USDC is securely locked in the treasury, and they receive a unique NFT in their wallet acting as their digital receipt.
4. **User** waits for the lockup period to end.
5. **User** claims their matured deposit. The NFT receipt is burned, and the system automatically sends the original principal plus all earned interest back to the user's wallet.

### Minimum Project Requirements (Per Assignment Spec)
To receive full credit for this capstone, the project must include:
1. **Three Core Smart Contracts:**
   - `MockUSDC.sol`: A test ERC20 token hardcoded to 6 decimals.
   - `VaultManager.sol`: The treasury contract that holds the bank's liquidity pool.
   - `SavingCore.sol`: The logic contract that issues ERC721 NFT certificates.
2. **Five Core User Flows:** Open Deposit, Withdraw at Maturity, Early Withdrawal, Manual Renew, and Auto Renew (bot-triggered after grace period).
3. **Event Emissions:** Must emit specific events for frontends (`PlanCreated`, `PlanUpdated`, `DepositOpened`, `Withdrawn`, `Renewed`).
4. **Test Suite:** Comprehensive test coverage (>90%) validating the math, edge cases, and time-travel logic using the student's unique personal variant numbers.
5. **Frontend:** A simple React frontend connected to MetaMask allowing users to view plans, deposit, withdraw, and renew.
6. **Documentation:** A README answering the 7 Open Design Questions and defending architectural choices.
7. **Demo:** A 3-5 minute video demonstrating the working frontend.

---

## Detailed Sprint Backlog Minimum Work (10-Day Accelerated Timeline)

### Phase 1: Smart Contracts Core & Bonus Logic & Discover vulnerabilities (July 18 - July 22)

#### NOTE: All of this has hidden vulnerabilities, The code implement will be adjusted dynamically based on newly discovered vulnerabilities from time to time.

#### Day 1 (Saturday, July 18): Project Setup & Infrastructure
- [x] **Task 1.1:** Run `forge init` to scaffold the project structure.
  *Purpose:* Initialize the Foundry framework to establish a blazing-fast testing and deployment pipeline.
- [x] **Task 1.2:** Install OpenZeppelin contracts via `forge install OpenZeppelin/openzeppelin-contracts --no-commit`.
  *Purpose:* Integrate audited, industry-standard security modules to protect against basic vulnerabilities.
- [x] **Task 1.3: Create `MockUSDC.sol`**
  *Purpose:* Deploy a simulated stablecoin to guarantee mathematical yield calculations performed locally map 1:1 with mainnet USDC.
  - Inherit from OpenZeppelin `ERC20`.
  - Override the `decimals()` function to return `6`.
  - Add an external `mint(address to, uint256 amount)` function for testing purposes.
- [x] **Task 1.4: Create `VaultManager.sol`**
  *Purpose:* Establish the central reserve to implement the Separation of Concerns pattern, isolating bank funds from logic to reduce the attack surface.
  - Inherit from `Ownable` and `Pausable`.
  - Define state variables: `usdc` (IERC20), `savingCore` (address), `feeReceiver` (address).
  - Define Custom Errors (`OnlySavingCore`, `InvalidAddress`).
  - Write `fundVault(uint256 amount)`: transfers USDC from msg.sender to the contract.
  - Write `setSavingCore(address)` and `setFeeReceiver(address)` (onlyOwner).
  - Write `pause()` and `unpause()` (onlyOwner).
- **MDR:** Both contracts compile and pass initial syntax checks.

#### Day 2 (Sunday, July 19): SavingCore State & Open Deposit
- [x] **Task 2.1: Create `SavingCore.sol` Base**
  *Purpose:* Deploy the central brain of the protocol to handle user interactions and maintain the state of all deposits.
  - Inherit from OpenZeppelin `ERC721`, `Ownable`, and `ReentrancyGuard`.
  - Define `Plan` struct: `tenorDays`, `aprBps`, `minDeposit`, `maxDeposit`, `earlyWithdrawPenaltyBps`, `enabled`.
  - Define `Deposit` struct: `principal`, `maturityAt`, `aprBpsAtOpen`, `penaltyBpsAtOpen`, `status`, `planId`.
  - Create mappings: `uint256 => Plan` and `uint256 => Deposit`.
- [x] **Task 2.2: Plan Management Admin Functions**
  *Purpose:* Allow the protocol to dynamically adapt to market conditions by offering different APRs, tenors, and penalty rates.
  - Write `createPlan(...)` to add a new plan to the mapping.
  - Write `updatePlan(uint256 planId, uint256 newAprBps)`.
  - Write `enablePlan()` and `disablePlan()`.
- [x] **Task 2.3: `openDeposit()` & C5 Slippage Protection**
  *Purpose:* Secure user funds, snapshot the current APR, and prevent malicious admins from front-running user deposits to lower rates (C5).
  - Write `openDeposit(uint256 planId, uint256 amount, uint256 minExpectedApr)`.
  - Implement C5 logic: `require(plan.aprBps >= minExpectedApr, "Slippage: APR dropped");`
  - Transfer USDC from user to `SavingCore`.
  - Mint the ERC721 NFT certificate to the user.
  - Populate the `Deposit` struct with snapshotted values.
- **MDR:** `openDeposit` is fully functional and mints an NFT.

#### Day 3 (Monday, July 20): Withdrawals, Math & Solvency Guard
- [x] **Task 3.1: Update `VaultManager.sol` for C2 (Solvency Guard)**
  *Purpose:* Mathematically prevent the Admin from withdrawing protocol liquidity if it would cause the vault to default on owed user interest.
  - Add state variable `uint256 public totalPromisedInterest`.
  - Update `withdrawVault(uint256 amount)`: `require(usdc.balanceOf(this) - amount >= totalPromisedInterest)`.
- [x] **Task 3.2: `withdrawAtMaturity()`**
  *Purpose:* Provide the core user exit flow to precisely calculate interest, burn the receipt NFT, and perfectly synchronize the Treasury's debt ledger.
  - Write function taking `depositId`. Verify NFT ownership.
  - Add time check: `require(block.timestamp >= deposit.maturityAt)`.
  - Calculate simple interest: `(principal * aprBps * tenorSeconds) / (365 days * 10000)`.
  - Transfer principal to user directly from `SavingCore`.
  - Call `VaultManager.payInterest(user, interestAmount)`.
  - Burn the NFT and update deposit status to `Withdrawn`.
- [x] **Task 3.3: `earlyWithdraw()` & C3 Partial Early Withdraw**
  *Purpose:* Massively improve UX by allowing depositors to withdraw partial amounts for emergency liquidity, paying penalties only on the withdrawn amount.
  - Update function signature to `earlyWithdraw(uint256 depositId, uint256 withdrawAmount)`.
  - Calculate penalty only on the `withdrawAmount`.
  - Decrease `VaultManager`'s `totalPromisedInterest` based *only* on the interest the `withdrawAmount` would have earned.
  - Transfer penalty to the `VaultManager`'s `feeReceiver`.
  - Transfer remaining principal (`withdrawAmount - penalty`) to the user.
  - Leave the rest of the principal in the active deposit (C3 Fix).
- **MDR:** Solvency guard is active, and math calculations for early/mature withdrawals are implemented.

#### Day 4 (Tuesday, July 21): Renewals & Top-Ups
- [x] **Task 4.1: `renewDeposit()` (Manual)**
  *Purpose:* Retain user liquidity within the protocol by compounding earned interest into a new active term.
  - Calculate earned interest from the matured deposit.
  - Compound it: `newPrincipal = oldPrincipal + interest`.
  - Overwrite the existing deposit struct to save massive gas (no new NFT minted).
- [x] **Task 4.2: `autoRenewDeposit()` (Bot)**
  *Purpose:* Provide a "set-and-forget" experience while protecting users from malicious rate drops during bot renewals (Griefing Protection).
  - Enforce the grace period: `require(block.timestamp > deposit.maturityAt + 2 days)`.
  - Overwrite the existing deposit struct to save gas, strictly locking it to the *original* `aprBpsAtOpen` to protect the user from rate drops.
  - **Challenge C5 Discovered & Solved (Unprofitable Liquidation):** Implemented a Yield-Deduction Automation fee (1 USDC). If a user's earned interest cannot cover the bot fee, the system automatically deducts the deficit from their principal, forcefully closes the deposit, and refunds the remaining balance. This prevents users with tiny balances from bleeding their principal to bot fees over time.
- [x] ~~**Task 4.3: `topUpDeposit()` (Challenge C4)**~~ **(SKIPPED - DESIGN FLAW)**
  *Reason for Skipping:*  discovered a fundamental Game Theory and Banking Economics flaw in the concept of "Top-Ups" for Fixed-Term deposits. Permitting users to inject fresh capital into an old deposit shortly before maturity severely harms the protocol's profitability and defeats the purpose of a fixed lockup. Furthermore, NFT fragmentation is actually beneficial for the bank because it forces users to ladder investments and re-lock fresh capital at current market rates. Thus, Challenge C4 is intentionally omitted to protect protocol health.
- **MDR:** Manual renew and auto-renew all compile and execute. Top-ups intentionally skipped.

#### Day 5 (Wednesday, July 22): The Principal Safety Net (C1)
- [x] **Task 5.1: Implement C1 (Safe Principal / Full Reserve Yield Solvency)**
  *Purpose:* Eliminate the "Hostage Principal" flaw by enforcing 100% Full Reserve Yield Pre-funding at deposit entry and renewals.
  - Check `usdc.balanceOf(VaultManager) >= totalPromisedInterest + newInterest` in `openDeposit()`, `renewDeposit()`, and `_autoRenewDeposit()`.
  - Guarantees the bank NEVER accepts a deposit unless its yield is 100% pre-funded in the vault, preventing empty vault scenarios when users mature.
- **MDR:** Full Reserve Yield Pre-funding check enforces 100% interest solvency at entry.

### Phase 2: Auditing & Testing (July 23 - July 24)

#### Day 6 & Day 7: Unit Testing & Time-Travel Edge Cases
- [x] **Task 6.1:** Setup test fixtures and environment in `SavingCore.t.sol`.
- [x] **Task 6.2:** Test `MockUSDC` minting and 6 decimals precision.
- [x] **Task 6.3:** Test Admin access control restrictions (`onlyOwner` on plan/vault settings).
- [x] **Task 6.4:** Test `openDeposit` happy path, slippage protection, and revert conditions (min/max deposit, disabled plan, underfunded vault).
- [x] **Task 7.1:** Test `withdrawAtMaturity` exact interest payout with time-travel (`vm.warp`).
- [x] **Task 7.2:** Test boundary times (`block.timestamp > maturityAt + 2 days`) for Chainlink Keepers automation.
- [x] **Task 7.3:** Write dedicated tests for C1 (Solvency Pre-funding), C2 (Solvency Guard), C3 (Partial Early Withdraw), and C5 (Liquidation & Slippage).
- [x] **Task 7.4:** Write Fuzz & Invariant tests (`testFuzz_...` in `SavingCore.t.sol` and `InvariantTest` in `Invariant.t.sol`) covering boundary edge cases, VaultManager branch coverage, and solvency invariants.
- **MDR:** Unit, Fuzz, and Invariant test suites fully implemented in `SavingCore.t.sol` and `Invariant.t.sol`.

### Phase 3: Frontend Integration (July 25 - July 26)

#### Day 8 (Saturday, July 25): React Setup & Read Functions
- [ ] **Task 8.1:** Run `npx create-vite` (React + TypeScript).
  *Purpose:* Provide a lightning-fast, type-safe development environment for the frontend.
- [ ] **Task 8.2:** Install Wagmi and Viem. Configure `WagmiProvider` for localhost.
  *Purpose:* Establish a seamless, reliable connection between the user's browser wallet and the local Anvil blockchain.
- [ ] **Task 8.3:** Export ABIs from Foundry and import them into React.
  *Purpose:* Connect the frontend codebase to the compiled smart contract interfaces.
- [ ] **Task 8.4:** Build UI to call `SavingCore.plans(id)` and map them to display cards.
  *Purpose:* Give users a transparent, real-time dashboard of available banking products and interest rates.
- **MDR:** Frontend successfully displays the saving plans directly from the local blockchain.

#### Day 9 (Sunday, July 26): Write Transactions & User Dashboard
- [ ] **Task 9.1:** Build the "Deposit" Modal. Use Wagmi `useWriteContract` to call `USDC.approve()`, then call `SavingCore.openDeposit()`.
  *Purpose:* Orchestrate the complex two-step transaction process into a smooth user experience.
- [ ] **Task 9.2:** Build the User Dashboard. Fetch all NFTs owned by the connected wallet using `SavingCore.balanceOf()` and `tokenOfOwnerByIndex()`.
  *Purpose:* Allow users to track their locked principal, expected maturity date, and accrued yield.
- [ ] **Task 9.3:** Add UI buttons for "Withdraw", "Early Withdraw", and "Top-Up", piping them to the correct smart contract calls.
  *Purpose:* Connect the frontend UI directly to the secure liquidation functions engineered in Phase 1.
- **MDR:** End-to-end user flow (connect wallet -> approve -> deposit -> fast forward time via Anvil -> withdraw) works from the browser.

### Phase 4: Finalization (July 27)

#### Day 10 (Monday, July 27): Documentation & Defense Prep
- [ ] **Task 10.1:** Populate `README.md`. Write clear instructions on how to run the tests and start the frontend.
  *Purpose:* Ensure the grading team can boot the local blockchain and launch the frontend without encountering errors.
- [ ] **Task 10.2:** Answer the 7 Design Questions from the assignment spec directly in the README.
  *Purpose:* Prove mastery of Solidity patterns and justify the engineering trade-offs made during development.
- [ ] **Task 10.3:** Write a detailed breakdown of how you solved C1, C2, C3, C4, and C5 for the +10 bonus points.
  *Purpose:* Explicitly highlight the advanced vulnerabilities discovered and solved, guaranteeing the +10 bonus points.
- [ ] **Task 10.4:** Record the 3-5 minute demo video using Loom or OBS, walking through the React app.
  *Purpose:* Provide undeniable visual proof of a fully functioning decentralized application prior to the oral defense.
- **MDR:** Project is zipped/committed to GitHub, video is uploaded, and you are 100% prepared for the oral defense.
