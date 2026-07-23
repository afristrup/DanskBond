// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./DGBToken.sol";

/// @title CouponDistributor
/// @notice Pays periodic coupons to DGBToken holders, pro-rata to their
/// balance at a snapshot block. Pull-based claims, not push.
contract CouponDistributor {
    using SafeERC20 for IERC20;

    DGBToken public immutable bond;
    IERC20 public immutable cashToken;
    address public custodian;

    struct Period {
        uint64 snapshotBlock;
        uint256 totalCoupon;
        uint256 totalSupplyAtSnapshot;
        bool funded;
    }

    Period[] public periods;
    mapping(uint256 => mapping(address => bool)) public claimed;

    event PeriodOpened(uint256 indexed periodIndex, uint64 snapshotBlock, uint256 totalSupplyAtSnapshot);
    event PeriodFunded(uint256 indexed periodIndex, uint256 totalCoupon);
    event CouponClaimed(uint256 indexed periodIndex, address indexed holder, uint256 amount);

    error NotCustodian();
    error SnapshotNotInPast();
    error PeriodAlreadyFunded();
    error PeriodNotFunded();
    error AlreadyClaimed();
    error NoBalanceAtSnapshot();

    modifier onlyCustodian() {
        if (msg.sender != custodian) revert NotCustodian();
        _;
    }

    constructor(address bond_, address cashToken_, address custodian_) {
        bond = DGBToken(bond_);
        cashToken = IERC20(cashToken_);
        custodian = custodian_;
    }

    function openPeriod(uint64 snapshotBlock) external onlyCustodian returns (uint256 periodIndex) {
        if (snapshotBlock >= block.number) revert SnapshotNotInPast();
        periodIndex = periods.length;
        uint256 supplyAtSnapshot = bond.totalSupplyAt(snapshotBlock);
        periods.push(
            Period({
                snapshotBlock: snapshotBlock, totalCoupon: 0, totalSupplyAtSnapshot: supplyAtSnapshot, funded: false
            })
        );
        emit PeriodOpened(periodIndex, snapshotBlock, supplyAtSnapshot);
    }

    function fundPeriod(uint256 periodIndex, uint256 amount) external onlyCustodian {
        Period storage p = periods[periodIndex];
        if (p.funded) revert PeriodAlreadyFunded();
        cashToken.safeTransferFrom(msg.sender, address(this), amount);
        p.totalCoupon = amount;
        p.funded = true;
        emit PeriodFunded(periodIndex, amount);
    }

    /// @dev Entitlement is read from the snapshot block, not the current
    /// balance, so buying in after the snapshot grants no claim.
    function claim(uint256 periodIndex) external {
        Period storage p = periods[periodIndex];
        if (!p.funded) revert PeriodNotFunded();
        if (claimed[periodIndex][msg.sender]) revert AlreadyClaimed();

        uint256 holderBalance = bond.balanceOfAt(msg.sender, p.snapshotBlock);
        if (holderBalance == 0) revert NoBalanceAtSnapshot();

        claimed[periodIndex][msg.sender] = true;
        uint256 amount = (p.totalCoupon * holderBalance) / p.totalSupplyAtSnapshot;
        cashToken.safeTransfer(msg.sender, amount);
        emit CouponClaimed(periodIndex, msg.sender, amount);
    }
}
