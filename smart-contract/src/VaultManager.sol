// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {
//     AccessControl
// } from "openzeppelin-contracts/contracts/access/AccessControl.sol";

contract VaultManager is Ownable, Pausable {
    IERC20 public usdc;
    address public feeReceiver; // 20 bytes.
    address public savingCore; // 20 bytes
    uint256 public totalPromisedInterest;

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
    }

    function withdrawVault(uint256 amount) external onlyOwner {
        require(
            usdc.balanceOf(address(this)) - amount >= totalPromisedInterest,
            "total promised interest is greater than the withdraw amount"
        );
        require(amount > 0, "Can't withdraw 0 from vault");
        bool succeed = usdc.transfer(msg.sender, amount);
        require(succeed, "Fail to transfer USDC from vault");
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
        feeReceiver = _feeReceiver;
    }
    function setSavingCore(address _savingCore) external onlyOwner {
        require(_savingCore != address(0), "Invalid address");
        savingCore = _savingCore;
    }

    function approveUSDC(address to, uint256 amount) external onlyOwner {
        usdc.approve(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
