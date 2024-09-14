// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {ERC20Mock} from "../src/ERC20Mock.sol";
import {Trade} from "../src/Trade.sol";
import {IPancakeRouter01} from "../src/interfaces/IPancakeRouter01.sol";

// forge script script/TradePro.s.sol:TradePro --rpc-url https://eth.llamarpc.com  --broadcast  --slow   -vvvv
contract TradePro is Script {
    address sender;
    //pro
    address routerv2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address routerv3 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function run() public {
        test_trade();
    }

    function test_trade() public {
        sender = vm.addr(vm.envUint("OP_PRI_PRO"));
        vm.startBroadcast(vm.envUint("OP_PRI_PRO"));

        // ERC20Mock erc = new ERC20Mock("TEST","TEST");
        Trade trade = new Trade(routerv2, routerv3);
        // trade.setFee(5e10, 1000, sender);

        // trade.setManager(sender);
        // trade.setMaker(sender, sender);
        // trade.setGasPriceLimit(sender, 10e9);
    }
}
