//SPDX-License-Identifer: MIT

pragma solidity ^0.8.20;

interface IVaultManager {
    function increaseTotalPromisedInterest(uint256 amount) external;
    function decreaseTotalPromisedInterest(uint256 amount) external;
    function feeReceiver() external view returns (address);
}
