// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IdentityRegistry} from "../contracts/IdentityRegistry.sol";
import {DGBToken} from "../contracts/DGBToken.sol";
import {RFQSettlement} from "../contracts/RFQSettlement.sol";
import {CouponDistributor} from "../contracts/CouponDistributor.sol";
import {PontesDvP} from "../contracts/PontesDvP.sol";
import {MockCash} from "../contracts/mocks/MockCash.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockCash cashToken = new MockCash();
        console2.log("MockCash deployed:", address(cashToken));

        IdentityRegistry identityRegistry = new IdentityRegistry(deployer);
        console2.log("IdentityRegistry deployed:", address(identityRegistry));

        DGBToken dgbToken = new DGBToken(
            "DGB 2.00% 2028",
            "DGB28",
            "DK0009925265",
            200,
            uint64(block.timestamp + 730 days),
            deployer,
            address(identityRegistry)
        );
        console2.log("DGBToken deployed:", address(dgbToken));

        RFQSettlement rfqSettlement = new RFQSettlement();
        console2.log("RFQSettlement deployed:", address(rfqSettlement));

        CouponDistributor couponDistributor =
            new CouponDistributor(address(dgbToken), address(cashToken), deployer);
        console2.log("CouponDistributor deployed:", address(couponDistributor));

        PontesDvP pontesDvP = new PontesDvP();
        console2.log("PontesDvP deployed:", address(pontesDvP));

        // PontesDvP escrows DGBToken, so it must itself be an approved holder.
        identityRegistry.approveContract(address(pontesDvP));

        vm.stopBroadcast();
    }
}
