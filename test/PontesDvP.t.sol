// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/IdentityRegistry.sol";
import "../contracts/DGBToken.sol";
import "../contracts/PontesDvP.sol";
import "../contracts/CouponDistributor.sol";
import "../contracts/RFQSettlement.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Minimal mintable stablecoin stand-in for tests only.
contract MockCash is ERC20 {
    constructor() ERC20("Mock EURC", "mEURC") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @dev Shared registry + bond fixture for suites that need a live DGBToken.
abstract contract DanskBondTestBase is Test {
    IdentityRegistry registry;
    DGBToken bond;
    address custodian = address(0xC0DE);

    function setUp() public virtual {
        registry = new IdentityRegistry(address(this));
        bond = new DGBToken(
            "DGB 2.00% 2028",
            "DGB28",
            "DK0009925265",
            200,
            uint64(block.timestamp + 730 days),
            custodian,
            address(registry)
        );
    }
}

contract PontesDvPTest is DanskBondTestBase {
    PontesDvP dvp;

    address seller = address(0xA1);
    address buyer = address(0xB2);

    function setUp() public override {
        super.setUp();
        registry.register(seller, "DK");
        registry.register(buyer, "DK");

        vm.prank(custodian);
        bond.mint(seller, 1_000 ether);

        dvp = new PontesDvP();

        // PontesDvP escrows tokens, so it must itself be an approved holder.
        registry.approveContract(address(dvp));
    }

    function test_lockAndClaim_releasesAssetOnCorrectPreimage() public {
        bytes32 preimage = keccak256("pontes-demo-preimage");
        bytes32 hashlock = keccak256(abi.encode(preimage));
        uint64 timeout = uint64(block.timestamp + 1 hours);

        vm.startPrank(seller);
        bond.approve(address(dvp), 100 ether);
        bytes32 lockId = dvp.lock(buyer, address(bond), 100 ether, hashlock, timeout);
        vm.stopPrank();

        dvp.claim(lockId, preimage);

        assertEq(bond.balanceOf(buyer), 100 ether);
        assertEq(bond.balanceOf(seller), 900 ether);
    }

    function test_claim_revertsOnWrongPreimage() public {
        bytes32 hashlock = keccak256(abi.encode(keccak256("real-preimage")));
        uint64 timeout = uint64(block.timestamp + 1 hours);

        vm.startPrank(seller);
        bond.approve(address(dvp), 100 ether);
        bytes32 lockId = dvp.lock(buyer, address(bond), 100 ether, hashlock, timeout);
        vm.stopPrank();

        vm.expectRevert(PontesDvP.WrongPreimage.selector);
        dvp.claim(lockId, keccak256("wrong-preimage"));
    }

    function test_refund_returnsAssetAfterTimeoutIfCashLegFails() public {
        bytes32 hashlock = keccak256(abi.encode(keccak256("preimage")));
        uint64 timeout = uint64(block.timestamp + 1 hours);

        vm.startPrank(seller);
        bond.approve(address(dvp), 100 ether);
        bytes32 lockId = dvp.lock(buyer, address(bond), 100 ether, hashlock, timeout);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        dvp.refund(lockId);

        assertEq(bond.balanceOf(seller), 1_000 ether);
    }

    function test_transferRestriction_blocksNonKycRecipient() public {
        address stranger = address(0x999);

        vm.startPrank(seller);
        vm.expectRevert(DGBToken.RecipientNotVerified.selector);
        bond.transfer(stranger, 10 ether);
        vm.stopPrank();
    }

    function test_transferRestriction_blocksRevokedSender() public {
        registry.revoke(seller);

        vm.prank(seller);
        vm.expectRevert(DGBToken.SenderNotVerified.selector);
        bond.transfer(buyer, 10 ether);
    }

    function test_lock_revertsIfEscrowContractNotApproved() public {
        PontesDvP unapprovedDvp = new PontesDvP();
        bytes32 hashlock = keccak256(abi.encode(keccak256("preimage")));
        uint64 timeout = uint64(block.timestamp + 1 hours);

        vm.startPrank(seller);
        bond.approve(address(unapprovedDvp), 100 ether);
        vm.expectRevert(DGBToken.RecipientNotVerified.selector);
        unapprovedDvp.lock(buyer, address(bond), 100 ether, hashlock, timeout);
        vm.stopPrank();
    }
}

contract DGBTokenTest is DanskBondTestBase {
    address newCustodian = address(0xC0DF);
    address holder = address(0xA1);

    function setUp() public override {
        super.setUp();
        registry.register(holder, "DK");
    }

    function test_balanceOfAt_revertsForCurrentBlock() public {
        vm.expectRevert(DGBToken.FutureOrCurrentBlock.selector);
        bond.balanceOfAt(holder, block.number);
    }

    function test_totalSupplyAt_revertsForFutureBlock() public {
        vm.expectRevert(DGBToken.FutureOrCurrentBlock.selector);
        bond.totalSupplyAt(block.number + 1);
    }

    function test_setCustodian_updatesMintPermission() public {
        bond.setCustodian(newCustodian);

        vm.prank(custodian);
        vm.expectRevert(DGBToken.NotCustodian.selector);
        bond.mint(holder, 1 ether);

        vm.prank(newCustodian);
        bond.mint(holder, 1 ether);
        assertEq(bond.balanceOf(holder), 1 ether);
    }

    function test_setCustodian_revertsForNonOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        bond.setCustodian(newCustodian);
    }

    function test_setCustodian_revertsOnZeroAddress() public {
        vm.expectRevert(DGBToken.ZeroAddress.selector);
        bond.setCustodian(address(0));
    }
}

contract IdentityRegistryTest is Test {
    IdentityRegistry registry;
    address officer = address(this);
    address newOfficer = address(0xD1);

    function setUp() public {
        registry = new IdentityRegistry(officer);
    }

    function test_registerBatch_registersAllWallets() public {
        address[] memory wallets = new address[](2);
        wallets[0] = address(0x1);
        wallets[1] = address(0x2);
        bytes2[] memory countries = new bytes2[](2);
        countries[0] = "DK";
        countries[1] = "SE";

        registry.registerBatch(wallets, countries);

        assertTrue(registry.isVerified(wallets[0]));
        assertTrue(registry.isVerified(wallets[1]));
    }

    function test_registerBatch_revertsOnLengthMismatch() public {
        address[] memory wallets = new address[](1);
        wallets[0] = address(0x1);
        bytes2[] memory countries = new bytes2[](2);

        vm.expectRevert(IdentityRegistry.ArrayLengthMismatch.selector);
        registry.registerBatch(wallets, countries);
    }

    function test_revokeContractApproval_blocksPreviouslyApprovedContract() public {
        address approved = address(0xC1);
        registry.approveContract(approved);
        assertTrue(registry.canHold(approved));

        registry.revokeContractApproval(approved);
        assertFalse(registry.canHold(approved));
    }

    function test_complianceOfficerHandover_completesInTwoSteps() public {
        registry.transferComplianceOfficer(newOfficer);
        assertEq(registry.complianceOfficer(), officer);

        vm.prank(newOfficer);
        registry.acceptComplianceOfficer();

        assertEq(registry.complianceOfficer(), newOfficer);
        assertEq(registry.pendingComplianceOfficer(), address(0));
    }

    function test_acceptComplianceOfficer_revertsForNonPendingCaller() public {
        registry.transferComplianceOfficer(newOfficer);

        vm.prank(address(0xBAD));
        vm.expectRevert(IdentityRegistry.NotPendingComplianceOfficer.selector);
        registry.acceptComplianceOfficer();
    }
}

contract CouponDistributorTest is DanskBondTestBase {
    MockCash cash;
    address holderA = address(0xA1);
    address holderB = address(0xB2);
    address latecomer = address(0xC3);

    function setUp() public override {
        super.setUp();
        registry.register(holderA, "DK");
        registry.register(holderB, "DK");
        registry.register(latecomer, "DK");

        vm.startPrank(custodian);
        bond.mint(holderA, 700 ether);
        bond.mint(holderB, 300 ether);
        vm.stopPrank();

        cash = new MockCash();
    }

    function test_couponSplitsProRataAcrossSnapshotHolders() public {
        uint256 snapshotBlock = block.number;
        vm.roll(block.number + 1);

        CouponDistributor dist = new CouponDistributor(address(bond), address(cash), custodian);

        vm.prank(custodian);
        uint256 periodIndex = dist.openPeriod(uint64(snapshotBlock));

        cash.transfer(custodian, 20 ether);
        vm.startPrank(custodian);
        cash.approve(address(dist), 20 ether);
        dist.fundPeriod(periodIndex, 20 ether);
        vm.stopPrank();

        vm.prank(holderA);
        dist.claim(periodIndex);
        vm.prank(holderB);
        dist.claim(periodIndex);

        assertEq(cash.balanceOf(holderA), 14 ether); // 700/1000 * 20
        assertEq(cash.balanceOf(holderB), 6 ether); // 300/1000 * 20
    }

    function test_buyingAfterSnapshot_doesNotGrantEntitlement() public {
        uint256 snapshotBlock = block.number;
        vm.roll(block.number + 1);

        vm.prank(holderA);
        bond.transfer(latecomer, 200 ether);

        CouponDistributor dist = new CouponDistributor(address(bond), address(cash), custodian);

        vm.prank(custodian);
        uint256 periodIndex = dist.openPeriod(uint64(snapshotBlock));

        cash.transfer(custodian, 20 ether);
        vm.startPrank(custodian);
        cash.approve(address(dist), 20 ether);
        dist.fundPeriod(periodIndex, 20 ether);
        vm.stopPrank();

        vm.prank(holderA);
        dist.claim(periodIndex);
        assertEq(cash.balanceOf(holderA), 14 ether); // 700/1000 * 20

        vm.prank(latecomer);
        vm.expectRevert(CouponDistributor.NoBalanceAtSnapshot.selector);
        dist.claim(periodIndex);
    }

    function test_openPeriod_revertsIfSnapshotNotInPast() public {
        CouponDistributor dist = new CouponDistributor(address(bond), address(cash), custodian);

        vm.prank(custodian);
        vm.expectRevert(CouponDistributor.SnapshotNotInPast.selector);
        dist.openPeriod(uint64(block.number));
    }

    function test_fundPeriod_revertsIfAlreadyFunded() public {
        uint256 snapshotBlock = block.number;
        vm.roll(block.number + 1);

        CouponDistributor dist = new CouponDistributor(address(bond), address(cash), custodian);

        vm.prank(custodian);
        uint256 periodIndex = dist.openPeriod(uint64(snapshotBlock));

        cash.transfer(custodian, 20 ether);
        vm.startPrank(custodian);
        cash.approve(address(dist), 20 ether);
        dist.fundPeriod(periodIndex, 20 ether);

        vm.expectRevert(CouponDistributor.PeriodAlreadyFunded.selector);
        dist.fundPeriod(periodIndex, 20 ether);
        vm.stopPrank();
    }
}

contract RFQSettlementTest is DanskBondTestBase {
    MockCash cash;
    RFQSettlement rfq;

    uint256 makerKey = 0xA11CE;
    address maker;
    address taker = address(0xB2);
    address stranger = address(0x999);

    function setUp() public override {
        super.setUp();
        maker = vm.addr(makerKey);

        registry.register(maker, "DK");
        registry.register(taker, "DK");
        registry.register(stranger, "DK");

        cash = new MockCash();
        rfq = new RFQSettlement();

        vm.prank(custodian);
        bond.mint(maker, 100 ether);
        vm.prank(maker);
        bond.approve(address(rfq), 100 ether);

        cash.transfer(taker, 50 ether);
        vm.prank(taker);
        cash.approve(address(rfq), 50 ether);
        cash.transfer(stranger, 50 ether);
        vm.prank(stranger);
        cash.approve(address(rfq), 50 ether);
    }

    function _signedQuote(address takerAddr) internal returns (RFQSettlement.Quote memory q, bytes memory sig) {
        q = RFQSettlement.Quote({
            marketMaker: maker,
            taker: takerAddr,
            bondToken: address(bond),
            quoteToken: address(cash),
            bondAmount: 10 ether,
            quoteAmount: 10 ether,
            expiry: block.timestamp + 1 hours,
            nonce: 1
        });

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("DanskBondRFQ"),
                keccak256("1"),
                block.chainid,
                address(rfq)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Quote(address marketMaker,address taker,address bondToken,address quoteToken,uint256 bondAmount,uint256 quoteAmount,uint256 expiry,uint256 nonce)"
                ),
                q.marketMaker,
                q.taker,
                q.bondToken,
                q.quoteToken,
                q.bondAmount,
                q.quoteAmount,
                q.expiry,
                q.nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function test_fillQuote_revertsForNonTakerCaller() public {
        (RFQSettlement.Quote memory q, bytes memory sig) = _signedQuote(taker);

        vm.prank(stranger);
        vm.expectRevert(RFQSettlement.NotTheQuotedTaker.selector);
        rfq.fillQuote(q, sig);
    }

    function test_fillQuote_succeedsForNamedTaker() public {
        (RFQSettlement.Quote memory q, bytes memory sig) = _signedQuote(taker);

        vm.prank(taker);
        rfq.fillQuote(q, sig);

        assertEq(bond.balanceOf(taker), 10 ether);
        assertEq(cash.balanceOf(maker), 10 ether);
    }

    function test_cancelQuote_blocksSubsequentFill() public {
        (RFQSettlement.Quote memory q, bytes memory sig) = _signedQuote(taker);

        vm.prank(maker);
        rfq.cancelQuote(q.nonce);

        vm.prank(taker);
        vm.expectRevert(RFQSettlement.NonceAlreadyUsed.selector);
        rfq.fillQuote(q, sig);
    }
}
