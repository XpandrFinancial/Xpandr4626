// SPDX-License-Identifier: No License (None)
// No permissions granted before Sunday, 5th May 2025, then GPL-3.0 after this date.

/** 
@title  - XpandrUnityVault2
@author - Nikar0 
@notice - Immutable, streamlined, security & gas considerate unified Vault + Strategy contract.
          Includes: feeToken switch / 0% withdraw fee default / Total Vault profit in USD /
          Deposit & harvest buffers / Timestamp & Slippage protection /

@notice - This version sends all fees to a contract instead of multiple txs to each receiving protocol address.
        - Less global variables/bytecode, cheaper harvest tx

https://www.github.com/nikar0/Xpandr4626  @Nikar0_


Vault based on EIP-4626 by @joey_santoro, @transmissions11, et all.
https://eips.ethereum.org/EIPS/eip-4626

Using solmate libs for ERC20, ERC4626
https://github.com/transmissions11/solmate

Using solady SafeTransferLib
https://github.com/Vectorized/solady/

Special thanks to 543 from Equalizer/Guru_Network for the brainstorming & QA

@notice - AccessControl = modified solmate Owned.sol w/ added Strategist + error codes.
        - Pauser = modified OZ Pausable.sol using uint8 instead of bool + error codes.
**/

pragma solidity ^0.8.19;

import {ERC20, ERC4626, FixedPointMathLib} from "./interfaces/solmate/ERC4626light.sol";
import {SafeTransferLib} from "./interfaces/solady/SafeTransferLib.sol";
import {AccessControl} from "./interfaces/AccessControl.sol";
import {Pauser} from "./interfaces/Pauser.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";
import {IEqualizerPair} from "./interfaces/IEqualizerPair.sol";
import {IEqualizerRouter} from "./interfaces/IEqualizerRouter.sol";
import {IEqualizerGauge} from "./interfaces/IEqualizerGauge.sol";

contract XpandrUnityVault2 is ERC4626, AccessControl, Pauser {
    using FixedPointMathLib for uint;

    /*//////////////////////////////////////////////////////////////
                          VARIABLES & EVENTS
    //////////////////////////////////////////////////////////////*/

    event Harvest(address indexed harvester);
    event SetRouterOrGauge(address indexed newRouter, address indexed newGauge);
    event SetFeesAndRecipient(uint64 withdrawFee, uint64 totalFees, address indexed newRecipient);
    event SlippageSetDelaySet(uint8 slippage, uint64 delay);
    event Panic(address indexed caller);
    event CustomTx(address indexed from, uint indexed amount);
    event StuckTokens(address indexed caller, uint indexed amount, address indexed token);
    
    // Tokens
    address public constant wftm = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant equal = address(0x3Fd3A0c85B70754eFc07aC9Ac0cbBDCe664865A6);
    address public constant mpx = address(0x66eEd5FF1701E6ed8470DC391F05e27B1d0657eb);
    address internal constant usdc = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);  //vaultProfit denominator
    address internal feeToken;         //Switch for which token protocol receives fees in. In mind for Native & Stable but fits any Equal - X token swap.
    address[] internal rewardTokens;
    address[3] internal slippageLPs;

    // 3rd party contracts
    address public gauge;
    address public router;

    // Xpandr addresses
    address public xpandrRecipient;

    // Fee Structure
    uint64 internal constant FEE_DIVISOR = 1000;               
    uint64 public constant platformFee = 35;                 // 3.5% Platform fee cap
    uint64 public withdrawFee;                               // 0% withdraw fee. Logic kept in case spam/economic attacks bypass buffers, can only be set to 0 or 0.1%
    uint64 public callFee = 125;
    uint64 public xpandrFee = 875;

    // Controllers
    uint64 internal delay;
    uint64 internal vaultProfit;                               // Excludes performance fees 
    uint64 internal lastHarvest;                             // Safeguard only allows harvest being called if > delay
    uint8 internal harvestOnDeposit;    
    uint8 internal slippage;                       
    mapping(address => uint64) internal lastUserDeposit;     //Safeguard only allows same user deposits if > delay

    constructor(
        ERC20 _asset,
        address _gauge,
        address _router,
        uint8 _slippage,
        address _xpandrRecipient,
        address _strategist
        )
       ERC4626(
            _asset,
            string(abi.encodePacked("Tester Vault")),
            string(abi.encodePacked("LP"))
        )
        {
        gauge = _gauge;
        router = _router;
        xpandrRecipient = _xpandrRecipient;
        strategist = _strategist;
        emit SetStrategist(address(0), strategist);
        delay = 600; // 10 mins
        slippage = _slippage;

        slippageLPs = [address(0x3d6c56f6855b7Cc746fb80848755B0a9c3770122), address(asset), address(0x7547d05dFf1DA6B4A2eBB3f0833aFE3C62ABD9a1)];
        rewardTokens.push(equal);
        lastHarvest = uint64(block.timestamp);
        _addAllowance();
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

     function depositAll() external {
        deposit(SafeTransferLib.balanceOf(address(asset), msg.sender), msg.sender);
    }

    // Deposit 'asset' into the vault which then deposits funds into the farm.  
    function deposit(uint assets, address receiver) public override whenNotPaused returns (uint shares) {
        if(tx.origin != receiver){revert XpandrErrors.NotAccountOwner();}
        if(lastUserDeposit[receiver] != 0) {if(_timestamp() < lastUserDeposit[receiver] + delay) {revert XpandrErrors.UnderTimeLock();}}
        if(assets > SafeTransferLib.balanceOf(address(asset), receiver)){revert XpandrErrors.OverCap();}
        shares = convertToShares(assets);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}

        lastUserDeposit[receiver] = _timestamp();
        emit Deposit(receiver, receiver, assets, shares);

        SafeTransferLib.safeTransferFrom(address(asset), receiver, address(this), assets); // Need to transfer before minting or ERC777s could reenter.
        _mint(receiver, shares);
        _earn();

        if(harvestOnDeposit != 0) {afterDeposit(assets, shares);}
    }

    function withdrawAll() external {
        withdraw(SafeTransferLib.balanceOf(address(this), msg.sender), msg.sender, msg.sender);
    }

    // Withdraw 'asset' from farm into vault & sends to receiver.
    function withdraw(uint shares, address receiver, address _owner) public override returns (uint assets) {
        if(tx.origin != receiver && tx.origin != _owner){revert XpandrErrors.NotAccountOwner();}
        if(shares > SafeTransferLib.balanceOf(address(this), _owner)){revert XpandrErrors.OverCap();}
        assets = convertToAssets(shares);
        if(assets == 0 || shares == 0){revert XpandrErrors.ZeroAmount();}
       
        _burn(_owner, shares);
        emit Withdraw(_owner, receiver, _owner, assets, shares);
        _collect(assets);

        uint assetBal = asset.balanceOf(address(this));
        if (assetBal > assets) {assetBal = assets;}

        if(withdrawFee != 0){
            uint withdrawFeeAmt = assetBal * withdrawFee / FEE_DIVISOR;
            SafeTransferLib.safeTransfer(address(asset), receiver, assetBal - withdrawFeeAmt);
        } else {SafeTransferLib.safeTransfer(address(asset), receiver, assetBal);}

    }

    function harvest() external {
        if(msg.sender != tx.origin){revert XpandrErrors.NotEOA();}
        if(_timestamp() < lastHarvest + delay){revert XpandrErrors.UnderTimeLock();}
        _harvest(msg.sender);
    }

    function _harvest(address caller) internal whenNotPaused {
        lastHarvest = _timestamp();
        emit Harvest(caller);

        IEqualizerGauge(gauge).getReward(address(this), rewardTokens);
        uint outputBal = SafeTransferLib.balanceOf(equal, address(this));

        if (outputBal != 0 ) {
            _chargeFees(caller);
            _addLiquidity();
        }
        _earn();
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    // Deposits funds in the farm
    function _earn() internal {
        uint assetBal = asset.balanceOf(address(this));
        IEqualizerGauge(gauge).deposit(assetBal);
    }

    // Withdraws funds from the farm
    function _collect(uint _amount) internal {
        uint assetBal = SafeTransferLib.balanceOf(address(asset), address(this));
        if (assetBal < _amount) {
            IEqualizerGauge(gauge).withdraw(_amount - assetBal);
        }
    }

    function _chargeFees(address caller) internal {                   
        uint equalBal = SafeTransferLib.balanceOf(equal, address(this));
        uint minAmt = getSlippage(equalBal, slippageLPs[0], equal);
        IEqualizerRouter(router).swapExactTokensForTokensSimple(equalBal, minAmt, equal, wftm, false, address(this), lastHarvest);
        
        uint feeBal = SafeTransferLib.balanceOf(wftm, address(this)) * platformFee / FEE_DIVISOR;
        uint toProfit = SafeTransferLib.balanceOf(wftm, address(this)) - feeBal;

        uint usdProfit = IEqualizerPair(slippageLPs[2]).sample(wftm, toProfit, 1, 1)[0];
        vaultProfit = vaultProfit + uint64(usdProfit);

        uint callAmt = feeBal * callFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(wftm, caller, callAmt);

        uint xpandrAmt = feeBal * xpandrFee / FEE_DIVISOR;
        SafeTransferLib.safeTransfer(wftm, xpandrRecipient, xpandrAmt);
    }

    function _addLiquidity() internal {
        uint wftmHalf = SafeTransferLib.balanceOf(wftm, address(this)) >> 1;
        (uint minAmt) = getSlippage(wftmHalf, address(asset), wftm);
        IEqualizerRouter(router).swapExactTokensForTokensSimple(wftmHalf, minAmt, wftm, mpx, false, address(this), lastHarvest);

        uint t1Bal = SafeTransferLib.balanceOf(wftm, address(this));
        uint t2Bal = SafeTransferLib.balanceOf(mpx, address(this));
        IEqualizerRouter(router).addLiquidity(wftm, mpx, false, t1Bal, t2Bal, 1, 1, address(this), lastHarvest);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    // Returns amount of reward in native upon calling the harvest function
    function callReward() public view returns (uint) {
        uint outputBal = IEqualizerGauge(gauge).earned(equal, address(this));
        uint wrappedOut;
        if (outputBal != 0) {
            (wrappedOut,) = IEqualizerRouter(router).getAmountOut(outputBal, equal, wftm);
        } 
        return wrappedOut * platformFee / FEE_DIVISOR * callFee / FEE_DIVISOR;
    }
    
    function idleFunds() external view returns (uint) {
        return SafeTransferLib.balanceOf(address(asset), address(this));
    }
    
    // Returns total amount of 'asset' held by the vault and contracts it deposits in.
    function totalAssets() public view override returns (uint) {
        return  SafeTransferLib.balanceOf(address(asset), address(this)) + balanceOfPool();
    }

    //Return how much 'asset' the vault has working in the farm
    function balanceOfPool() public view returns (uint) {
        return IEqualizerGauge(gauge).balanceOf(address(this));
    }

    // Returns rewards unharvested
    function rewardBalance() external view returns (uint) {
        return IEqualizerGauge(gauge).earned(equal, address(this));
    }

    // Function for UIs to display the current value of 1 vault share
    function getPricePerFullShare() external view returns (uint) {
        return totalSupply == 0 ? 1e18 : totalAssets() * 1e18 / totalSupply;
    }

    function convertToShares(uint assets) public view override returns (uint) {
        uint supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    function convertToAssets(uint shares) public view override returns (uint) {
        uint supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.
        return supply == 0 ? shares : shares.mulDivUp(totalAssets(), supply);
    }

    function vaultProfits() external view returns (uint64){
        return vaultProfit / 1e6;
    }

    /*//////////////////////////////////////////////////////////////
                              SECURITY
    //////////////////////////////////////////////////////////////*/

    // Pauses the vault & executes emergency withdraw
    function panic() external onlyAdmin {
        pause();
        emit Panic(msg.sender);
        IEqualizerGauge(gauge).withdraw(balanceOfPool());
    }

    function pause() public onlyAdmin {
        _pause();
        _subAllowance();
    }

    function unpause() external whenPaused onlyAdmin {
        _unpause();
        _addAllowance();
        _earn();
    }

    //Guards against timestamp spoofing
    function _timestamp() internal view returns (uint64 timestamp){
        (,,uint lastBlock) = IEqualizerPair(slippageLPs[2]).getReserves();
        timestamp = uint64(lastBlock + 300);
    }

    function getSlippage(uint _amount, address _lp, address _token) internal view returns(uint minAmt){
        uint[] memory t1Amts = IEqualizerPair(_lp).sample(_token, _amount, 2, 1);
        minAmt = (t1Amts[0] + t1Amts[1] ) / 2;
        minAmt = minAmt - (minAmt *  slippage / 100);
    }

    /*//////////////////////////////////////////////////////////////
                               SETTERS
    //////////////////////////////////////////////////////////////*/

    function setFeesAndRecipient(uint64 _withdrawFee, uint64 _callFee, uint64 _recipientFee, address _recipient) external onlyAdmin {
        if(_withdrawFee != 0 && _withdrawFee != 1){revert XpandrErrors.OverCap();}
        uint64 sum = _callFee + _recipientFee;
        if(sum > FEE_DIVISOR){revert XpandrErrors.OverCap();}
        if(_recipient != address(0) && _recipient != xpandrRecipient){xpandrRecipient = _recipient;}

        callFee = _callFee;
        withdrawFee = _withdrawFee;
        xpandrFee = _recipientFee;
        emit SetFeesAndRecipient(withdrawFee, sum, xpandrRecipient);
    }

    function setRouterOrGauge(address _router, address _gauge) external onlyOwner {
        if(_router == address(0) || _gauge == address(0)){revert XpandrErrors.ZeroAddress();}
        if(_router != router){router = _router;}
        if(_gauge != gauge){gauge = _gauge;}
        emit SetRouterOrGauge(router, gauge);
    }

    // Sets harvestOnDeposit
    function setHarvestOnDeposit(uint8 _harvestOnDeposit) external onlyAdmin {
        if(_harvestOnDeposit != 0 && _harvestOnDeposit != 1){revert XpandrErrors.OverCap();}
        harvestOnDeposit = _harvestOnDeposit;
    } 

    function setSlippageSetDelay(uint8 _slippage, uint64 _delay) external onlyAdmin{
        if(_delay > 1800 || _delay < 600) {revert XpandrErrors.InvalidDelay();}
        if(_slippage > 5 || _slippage < 1){revert XpandrErrors.OverCap();}

        if(_delay != delay){delay = _delay;}
        if(_slippage != slippage){slippage = _slippage;}
        emit SlippageSetDelaySet(slippage, delay);
    }

    /*//////////////////////////////////////////////////////////////
                               UTILS
    //////////////////////////////////////////////////////////////

    This function exists for cases where a vault may receive sporadic 3rd party rewards such as airdrop from it's deposit in a farm.
    Enables convert that token into more of this vault's reward. */ 
    function customTx(address _token, uint _amount, IEqualizerRouter.Routes[] memory _path) external onlyAdmin {
        if(_token == equal || _token == wftm || _token == mpx){revert XpandrErrors.InvalidTokenOrPath();}
        uint bal;
        if(_amount == 0) {bal = SafeTransferLib.balanceOf(_token, address(this));}

        emit CustomTx(_token, bal);
        SafeTransferLib.safeApprove(_token, router, 0);
        SafeTransferLib.safeApprove(_token, router, type(uint).max);
        IEqualizerRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(bal, 1, _path, address(this), _timestamp());   
    }

    function _subAllowance() internal {
        SafeTransferLib.safeApprove(address(asset), gauge, 0);
        SafeTransferLib.safeApprove(equal, router, 0);
        SafeTransferLib.safeApprove(wftm, router, 0);
        SafeTransferLib.safeApprove(mpx, router, 0);
    }

    function _addAllowance() internal {
        SafeTransferLib.safeApprove(address(asset), gauge, type(uint).max);
        SafeTransferLib.safeApprove(equal, router, type(uint).max);
        SafeTransferLib.safeApprove(wftm, router, type(uint).max);
        SafeTransferLib.safeApprove(mpx, router, type(uint).max);
    }

    //ERC4626 hook. Called by deposit if harvestOnDeposit != 0. Args unused but part of 4626 spec
    function afterDeposit(uint assets, uint shares) internal override {
        _harvest(tx.origin);
    }
}