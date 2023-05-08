//SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStrategy { 
    function vault() external view returns (address);
    function want() external view returns (IERC20);
    function deposit() external;
    function afterDeposit() external;
    function withdraw(uint256) external;
    function balanceOf() external view returns (uint256);
    function harvest() external;
    function retireStrat() external;
    function panic() external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
    function harvestOnDeposit() external view returns(uint256);
}

