// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./IdentityRegistry.sol";

/// @title DGBToken
/// @notice Fractional tokenized exposure to a Danish Government Bond ISIN.
/// 1 token = 1 kr face value, minted 1:1 against bonds held by a custodian.
contract DGBToken is ERC20, Ownable {
    using Checkpoints for Checkpoints.Trace224;
    using SafeCast for uint256;

    IdentityRegistry public identityRegistry;

    string public isin;
    uint16 public couponBps;
    uint64 public maturity;
    address public custodian;

    /// @dev Trace224: block number and balance/supply both fit uint32/uint224.
    mapping(address => Checkpoints.Trace224) private _balanceCheckpoints;
    Checkpoints.Trace224 private _totalSupplyCheckpoints;

    event Minted(address indexed to, uint256 amount);
    event Redeemed(address indexed from, uint256 amount);
    event CustodianUpdated(address indexed previousCustodian, address indexed newCustodian);

    error NotCustodian();
    error RecipientNotVerified();
    error SenderNotVerified();
    error FutureOrCurrentBlock();
    error ZeroAddress();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory isin_,
        uint16 couponBps_,
        uint64 maturity_,
        address custodian_,
        address identityRegistry_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        isin = isin_;
        couponBps = couponBps_;
        maturity = maturity_;
        custodian = custodian_;
        identityRegistry = IdentityRegistry(identityRegistry_);
    }

    /// @dev Only the custodian mints, after buying the underlying bond.
    function mint(address to, uint256 amount) external {
        if (msg.sender != custodian) revert NotCustodian();
        if (!identityRegistry.canHold(to)) revert RecipientNotVerified();
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /// @dev Not gated on KYC status: a revoked wallet can still redeem to
    /// cash, it just can't sell onward to another on-chain wallet.
    function redeem(uint256 amount) external {
        _burn(msg.sender, amount);
        emit Redeemed(msg.sender, amount);
    }

    /// @dev Lets the owner rotate the custodian address.
    function setCustodian(address newCustodian) external onlyOwner {
        if (newCustodian == address(0)) revert ZeroAddress();
        address previous = custodian;
        custodian = newCustodian;
        emit CustodianUpdated(previous, newCustodian);
    }

    /// @dev Enforces the KYC allow-list on both sides of every transfer.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (!identityRegistry.canHold(to)) revert RecipientNotVerified();
            if (!identityRegistry.canHold(from)) revert SenderNotVerified();
        }

        super._update(from, to, value);

        uint32 blockKey = block.number.toUint32();
        if (from != address(0)) {
            _balanceCheckpoints[from].push(blockKey, balanceOf(from).toUint224());
        }
        if (to != address(0)) {
            _balanceCheckpoints[to].push(blockKey, balanceOf(to).toUint224());
        }
        if (from == address(0) || to == address(0)) {
            _totalSupplyCheckpoints.push(blockKey, totalSupply().toUint224());
        }
    }

    /// @notice Historical balance of `account` at the end of `blockNumber`.
    function balanceOfAt(address account, uint256 blockNumber) external view returns (uint256) {
        if (blockNumber >= block.number) revert FutureOrCurrentBlock();
        return _balanceCheckpoints[account].upperLookupRecent(blockNumber.toUint32());
    }

    /// @notice Historical total supply at the end of `blockNumber`.
    function totalSupplyAt(uint256 blockNumber) external view returns (uint256) {
        if (blockNumber >= block.number) revert FutureOrCurrentBlock();
        return _totalSupplyCheckpoints.upperLookupRecent(blockNumber.toUint32());
    }
}
