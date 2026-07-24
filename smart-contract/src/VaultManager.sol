// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract VaultManager is Ownable {
    IERC20 public usdc;
    address public feeReceiver;
    address public savingCore;
    uint256 public totalPromisedInterest;

    event VaultFunded(address indexed funder, uint256 amount);
    event VaultWithdrawn(address indexed admin, uint256 amount);
    event FeeReceiverSet(address indexed feeReceiver);
    event SavingCoreSet(address indexed savingCore);

    modifier onlySavingCore() {
        require(
            msg.sender == savingCore,
            "Only saving core can call this function"
        );
        _;
    }

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    function fundVault(uint256 amount) external {
        require(amount > 0, "Can't fund 0 to vault");
        bool succeed = usdc.transferFrom(msg.sender, address(this), amount);
        require(succeed, "Fail to transfer USDC to vault");
        emit VaultFunded(msg.sender, amount);
    }

    function withdrawVault(uint256 amount) external onlyOwner {
        require(
            usdc.balanceOf(address(this)) - amount >= totalPromisedInterest,
            "total promised interest is greater than the withdraw amount"
        );
        require(amount > 0, "Can't withdraw 0 from vault");
        bool succeed = usdc.transfer(msg.sender, amount);
        require(succeed, "Fail to transfer USDC from vault");
        emit VaultWithdrawn(msg.sender, amount);
    }

    function increaseTotalPromisedInterest(
        uint256 amount
    ) external onlySavingCore {
        totalPromisedInterest += amount;
    }

    function decreaseTotalPromisedInterest(
        uint256 amount
    ) external onlySavingCore {
        totalPromisedInterest -= amount;
    }

    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        require(_feeReceiver != address(0), "Invalid address");
        require(feeReceiver == address(0), "FeeReceiver already set");
        feeReceiver = _feeReceiver;
        emit FeeReceiverSet(_feeReceiver);
    }

    function setSavingCore(address _savingCore) external onlyOwner {
        require(_savingCore != address(0), "Invalid address");
        require(savingCore == address(0), "SavingCore already set");
        savingCore = _savingCore;
        usdc.approve(_savingCore, type(uint256).max);
        emit SavingCoreSet(_savingCore);
    }
}
