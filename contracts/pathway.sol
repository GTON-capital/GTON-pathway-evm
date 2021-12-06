//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IERC20.sol";
import "./libraries/UniswapV2Library.sol";
import "./interfaces/IWETH.sol";
import './libraries/UniswapV2Library.sol';
import './libraries/UniswapV2Arbitrage.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';

interface IFarm {
    function userInfo(uint farmId, address userAddress) external returns (uint amount, uint debt);
}

interface ICan {
    function toggleRevert() external;
    function transferOwnership(address newOwner) external;
    function emergencyTakeout(IERC20 _token, address _to, uint _amount) external;
    function changeCanFee(uint _fee) external;
    function updateCan () external;
    function mintFor(address _user, uint _providedAmount) external;
    function burnFor(address _user, uint _providedAmount, uint _rewardAmount) external;
    function transfer(address _from, address _to, uint _providingAmount, uint _rewardAmount) external;
    function emergencySendToFarming(uint _amount) external;
    function emergencyGetFromFarming(uint _amount) external;
    function canInfo() external returns(
        uint totalProvidedTokenAmount,
        uint totalFarmingTokenAmount,
        uint accRewardPerShare,
        uint totalRewardsClaimed,
        uint farmId,
        address farm,
        address router,
        address lpToken,
        address providingToken,
        address rewardToken,
        uint fee
    );
}

contract PathwayRouter {
    IWETH public eth;
    IERC20 public gton;
    address public factory;

    address public owner;
    bool public revertFlag;

    modifier onlyOwner() {
        require(msg.sender == owner,"not owner");
        _;
    }   

    function transferOwnership(address _newOwner) public onlyOwner {
        owner = _newOwner;
    }

    function tokenTakeout(IERC20 _token, address _to, uint _amount) public onlyOwner {
        require(_token.transfer(_to,_amount));
    }  

    constructor (
        IWETH _eth,
        IERC20 _gton,
        address _factory,
        address _owner
    ) {
        eth = _eth;
        gton = _gton;
        factory = _factory;
        owner = _owner;
    }

    function rebalancePool (
        uint newTokenAPrice, 
        uint newTokenBPrice, 
        ICan can
    ) public onlyOwner {
        (,,,,uint farmId, address farm,,address pool,,,) = can.canInfo();
        // get the amount of lp can contract has in farming
        (uint manipulatingLpAmount,) = IFarm(farm).userInfo(farmId,address(can));
        // get pool tokens
        address tokenA = IUniswapV2Pair(pool).token0();
        address tokenB = IUniswapV2Pair(pool).token1();
        // take lp from candy farming
        can.emergencyGetFromFarming(manipulatingLpAmount);
        can.emergencyTakeout(IERC20(pool),address(this),manipulatingLpAmount);
        // unlock reserves from lp
        require(IUniswapV2Pair(pool).transfer(pool,manipulatingLpAmount),"not enough lp token to burn");
        // unlock reserves from lp
        IUniswapV2Pair(pool).burn(address(this));
        // compute arbitrage amount
        (uint resA, uint resB,) = IUniswapV2Pair(pool).getReserves();
        (bool aTob, uint amountIn) = UniswapV2LiquidityMathLibrary
            .computeProfitMaximizingTrade(
                newTokenAPrice,
                newTokenBPrice,
                resA,
                resB
            );
        // rebalance pool
        if (aTob) {
            uint amountOut = UniswapV2Library.getAmountOut(amountIn,resA,resB);
            IERC20(tokenA).transfer(pool,amountIn);
            IUniswapV2Pair(pool).swap(0,amountOut,address(this),bytes(""));
        } else {
            uint amountOut = UniswapV2Library.getAmountOut(amountIn,resB,resA);
            IERC20(tokenB).transfer(pool,amountIn);
            IUniswapV2Pair(pool).swap(amountOut,0,address(this),bytes(""));
        }
        // add liquidity with quote
        (resA,resB,) = IUniswapV2Pair(pool).getReserves();
        uint tokenAAmount;
        uint tokenBAmount;
        if( tokenA == address(gton) ) {
            tokenBAmount = IERC20(tokenB).balanceOf(address(this));
            tokenAAmount = UniswapV2Library.quote(tokenBAmount,resB,resA);
        } else {
            tokenAAmount = IERC20(tokenA).balanceOf(address(this));
            tokenBAmount = UniswapV2Library.quote(tokenAAmount,resA,resB);
        }
        require(IERC20(tokenA).transfer(pool,tokenAAmount),"not enough token A to add liquidity");
        require(IERC20(tokenB).transfer(pool,tokenBAmount),"not enough token B to add liquidity");
        // send lps to candy (sending by minting)
        uint lpAmount = IUniswapV2Pair(pool).mint(address(can));
        // put lps to farm
        can.emergencySendToFarming(lpAmount);
    }

    function massPoolRebalance(
        uint[] calldata tokenAPrices, 
        uint[] calldata tokenBPrices, 
        address[] calldata cans
    ) public onlyOwner {
        for (uint i = 0; i < cans.length; i++) {
            rebalancePool(tokenAPrices[i],tokenBPrices[i],ICan(cans[i]));
        }
    }
}