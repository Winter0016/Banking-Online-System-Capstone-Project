# Online Banking System: Architecture & Flaws Breakdown

This document breaks down the entire concept of the capstone project, the roles of each contract and function, and the built-in flaws in the base specification (which are what the bonus challenges are meant to fix!).

## 1. The Core Concept & Process
You are building an on-chain Certificate of Deposit (CD) system. 
- A user locks up their money (USDC) for a fixed period (e.g., 180 days).
- In exchange, they get a fixed interest rate (APR) when they withdraw at the end of the term.
- If they withdraw early, they get NO interest, and they lose a percentage of their principal as a penalty.
- The bank's money (used to pay interest) is kept completely separate from the users' money (their original deposit).

### The Deposit Lifecycle:
1. **Open:** User deposits 1,000 USDC. They are minted an NFT (the certificate). The current APR and penalty are "snapshotted" (saved onto that specific deposit).
2. **Maturity:** 180 days pass. The user returns the NFT and gets their 1,000 USDC back, PLUS the interest calculated using the snapshotted APR. 
3. **Grace Period / Auto-Renew:** If the user forgets to withdraw within 2 days after maturity, a bot will automatically reinvest their principal + earned interest into a new 180-day cycle, *protecting* their original APR.

---

## 2. The Contracts & Functions

### Contract 1: `SavingCore.sol`
This is the brains of the operation. It holds all the users' deposited principal and handles the business rules. It also acts as the ERC721 NFT contract.
- `createPlan()` / `updatePlan()` / `enablePlan()` / `disablePlan()`: Admin functions to create or modify saving products (like a bank offering a new 3.5% interest rate).
- `openDeposit()`: Pulls USDC from the user, saves the plan details, and mints the NFT certificate to the user.
- `withdrawAtMaturity()`: Verifies the term is over. Sends the principal back to the user from `SavingCore`, and requests `VaultManager` to send the interest to the user. Burns the NFT.
- `earlyWithdraw()`: Calculates the penalty (e.g., 3.5%). Sends the penalty to the admin, sends the remaining principal back to the user. Zero interest is paid.
- `renewDeposit()`: Manual rollover. Calculates interest, adds it to the principal, and starts a new deposit term.
- `autoRenewDeposit()`: Callable by anyone (usually a bot) after the grace period ends. Automatically rolls over the deposit using the original locked-in APR.

### Contract 2: `VaultManager.sol`
This is the bank's vault. It strictly holds the bank's own money, which is used to pay out the yield (interest).
- `fundVault()`: Admin deposits USDC into the vault to ensure there is enough liquidity to pay users their interest.
- `withdrawVault()`: Admin removes USDC from the vault (taking profits).
- `setFeeReceiver()`: Admin sets the address that receives the early withdrawal penalties.
- `pause()` / `unpause()`: Emergency switches to stop all withdrawals or deposits if a hack occurs.

### Contract 3: `MockUSDC.sol`
- A fake USDC token with exactly 6 decimals. Used purely for testing so you can simulate real-world stablecoin behavior.

---

## 3. The Flaws (And why the Bonus Challenges exist)

The base specification has some intentional, dangerous flaws that a real DeFi protocol would never allow. Identifying and fixing these is how you get the +10 bonus points.

### Flaw 1: The "Hostage Principal" Problem (Challenge C1)
- **The Flaw:** In the base spec, if a user tries to `withdrawAtMaturity()`, the transaction will **revert** (fail) if the `VaultManager` doesn't have enough money to pay the interest.
- **Why it's bad:** The Bank Admin can literally hold your original deposit hostage just by refusing to fund the vault. You can't even get your principal back!
- **The Fix:** Change the code so that if the vault is empty, the user gets their principal back immediately, and the contract records a "debt" (IOU) for the interest to be claimed later.

### Flaw 2: The "Bank Run" / Solvency Problem (Challenge C2)
- **The Flaw:** The base spec allows the Admin to call `withdrawVault()` and drain the entire vault at any time.
- **Why it's bad:** An admin could see that a user is about to earn 50 USDC in interest tomorrow, and drain the vault today. The vault becomes insolvent.
- **The Fix:** Add a solvency guard. Every time a deposit is opened, track how much maximum interest is "promised" to the user. `withdrawVault()` must revert if withdrawing would drop the vault balance below the total promised interest.

### Flaw 3: All-or-Nothing Withdrawals (Challenge C3)
- **The Flaw:** If a user deposits 10,000 USDC but suddenly needs 1,000 USDC to pay for a car repair, `earlyWithdraw()` forces them to withdraw the *entire* 10,000 USDC and suffer the 3.5% penalty on all of it.
- **Why it's bad:** It's terrible UX. Traditional CDs often let you break off a piece of your deposit.
- **The Fix:** Create a `partialEarlyWithdraw(amount)` function. The user pays the 3.5% penalty *only* on the 1,000 USDC they withdraw, and the remaining 9,000 USDC continues earning interest until maturity.

### Flaw 4: Fragmented Deposits (Challenge C4)
- **The Flaw:** If a user opens a 180-day deposit, and a month later wants to add more money, they have to open a completely separate, second deposit (which mints a second NFT).
- **Why it's bad:** Users end up with dozens of NFTs to track, all maturing at different dates, which is annoying to manage and costs a lot of gas.
- **The Fix:** Allow "Top-Ups". Let a user add principal to an active deposit. The hard part (the challenge) is figuring out the math to weight the interest correctly based on how much time is left in the term. 

---

## 4. Uncovering the "Hidden" Flaws (Challenge C5 Ideas)

The document specifically mentions that finding a gap yourself is the "most valuable skill in this course." Even if you implement C1–C4, there are still massive, real-world DeFi vulnerabilities hidden in this architecture. Here are 4 excellent potential flaws you could use for your C5 challenge to impress your teacher:

### C5 Idea A: The Frontrunning / Slippage Flaw (Highly Recommended)
- **The Flaw:** When a user calls `openDeposit(planId, amount)`, they are expecting the current APR. But the Admin has an `updatePlan(planId, newApr)` function. If the Admin lowers the APR from 5% to 1%, and their transaction processes right before the user's transaction, the user gets locked into a 180-day term at 1% against their will!
- **The Fix:** Add "Slippage Protection." Change `openDeposit` to accept a third parameter: `openDeposit(planId, amount, minExpectedApr)`. If the plan's current APR is lower than the user's `minExpectedApr`, the transaction reverts, protecting them. This is identical to how Uniswap protects traders from price changes.

### C5 Idea B: The Auto-Renew "Griefing" Flaw
- **The Flaw:** The spec says an off-chain bot will automatically renew a deposit if the user does nothing for 3 days (or 2 days for your variant). But what if a user went on vacation and *wanted* to withdraw on Day 4? The bot force-locks their money for another 180 days! To get it out, they now have to suffer the 3.5% early withdrawal penalty. The bot essentially griefs the user.
- **The Fix:** When a user calls `openDeposit()`, let them pass a boolean flag: `bool optInToAutoRenew`. If false, the bot is completely blocked from renewing their deposit. The funds just sit safely waiting for the user to return.

### C5 Idea C: The "Ragequit" / Centralization Flaw
- **The Flaw:** The VaultManager has a `pause()` function. If the Admin goes rogue, gets hacked, or loses their private key, they can pause the system forever. Users can never call `withdrawAtMaturity()` and their principal is permanently stolen/locked.
- **The Fix:** Implement a "Time-locked Escape Hatch." If the system has been paused for more than 7 days continuously, users can call a special `emergencyRagequit()` function. This bypasses the pause restriction and allows them to withdraw their original principal (forfeiting interest), protecting them from a malicious admin.

### C5 Idea D: The Illiquid Yield Flaw
- **The Flaw:** A user has to wait the entire 180 days to see a single cent of interest. Traditional finance and modern DeFi often pay out yield monthly or block-by-block. 
- **The Fix:** Add a `claimInterest(depositId)` function. This calculates the interest earned *up to the current block timestamp* and pays it out to the user instantly, updating a `lastClaimedAt` timestamp so they can't double-dip. This allows users to actually use their earned money without breaking the 180-day lock on their principal.
