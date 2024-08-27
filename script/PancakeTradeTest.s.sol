// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {ERC20Mock} from "../src/ERC20Mock.sol";
import {PancakeTrade, ExecutorBot, ISwapRouter} from "../src/PancakeTrade.sol";
import {IPancakeRouter01} from "../src/interfaces/IPancakeRouter01.sol";

// forge script script/PancakeTradeTest.s.sol:PancakeTradeTest --rpc-url https://data-seed-prebsc-1-s3.bnbchain.org:8545  --broadcast  --slow   -vvvv
contract PancakeTradeTest is Script {
    address sender;
    //pro
    // address router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    // address factory = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    //test
    address routerv2 = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address routerv3 = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    function run() public {
        test_trade();
    }

    function test_trade() public {
        sender = vm.addr(vm.envUint("OP_PRI"));
        vm.startBroadcast(vm.envUint("OP_PRI"));


        PancakeTrade trade = new PancakeTrade(routerv2, routerv3);
        trade.setFee(5e10, 1000, sender);
        
        // trade.setManager(sender);
        // trade.setMaker(sender, sender);
        // trade.setFee(1e4, 1000, sender);
        // ERC20Mock usdt =ERC20Mock();
    }
}
