// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {ERC20Mock} from "../src/ERC20Mock.sol";
import {PancakeTrade} from "../src/PancakeTrade.sol";
import {IPancakeRouter01} from "../src/interfaces/IPancakeRouter01.sol";

// forge script script/PancakeTradePro.s.sol:PancakeTradePro --rpc-url https://data-seed-prebsc-1-s3.bnbchain.org:8545  --broadcast  --slow   -vvvv
contract PancakeTradePro is Script {
    address sender;
    //pro
    address router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address factory = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    //test
    // address factory = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    // address router = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;

    function run() public {
        test_trade();
    }

    function test_trade() public {
        sender = vm.addr(vm.envUint("OP_PRI_PRO"));
        vm.startBroadcast(vm.envUint("OP_PRI_PRO"));
        PancakeTrade trade = new PancakeTrade(factory, router);
       

        trade.setMaker(sender);

    }
}
