// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PontesDvP
/// @notice Hash-time-locked delivery-versus-payment contract for the asset
/// leg of a trade whose cash leg settles via the Pontes Hash-Link protocol.
///
/// Flow: seller locks bond tokens against a hashlock; the buyer's cash leg
/// locks the matching amount off-chain, referencing the same hashlock. Once
/// the cash leg settles, revealing the preimage lets anyone call claim() to
/// release the bond tokens. If the cash leg never settles, the seller calls
/// refund() after timeout.
///
/// @dev For lock() to succeed, this contract must be registered as an
/// approved contract in IdentityRegistry, since it is itself a transfer
/// recipient of the escrowed DGBToken.
contract PontesDvP {
    using SafeERC20 for IERC20;

    struct Lock {
        address seller;
        address buyer;
        address bondToken;
        uint256 amount;
        bytes32 hashlock;
        uint64 timeout;
        bool claimed;
        bool refunded;
    }

    mapping(bytes32 => Lock) public locks;

    event Locked(
        bytes32 indexed lockId,
        address seller,
        address buyer,
        address bondToken,
        uint256 amount,
        bytes32 hashlock,
        uint64 timeout
    );
    event Claimed(bytes32 indexed lockId, bytes32 preimage);
    event Refunded(bytes32 indexed lockId);

    error TimeoutNotInFuture();
    error ZeroAmount();
    error ZeroAddress();
    error LockAlreadyExists();
    error NoSuchLock();
    error AlreadySettled();
    error WrongPreimage();
    error LockExpired();
    error NotYetExpired();

    function lock(address buyer, address bondToken, uint256 amount, bytes32 hashlock, uint64 timeout)
        external
        returns (bytes32 lockId)
    {
        if (timeout <= block.timestamp) revert TimeoutNotInFuture();
        if (amount == 0) revert ZeroAmount();
        if (buyer == address(0) || bondToken == address(0)) {
            revert ZeroAddress();
        }

        lockId = keccak256(abi.encode(msg.sender, buyer, bondToken, amount, hashlock, timeout));
        if (locks[lockId].seller != address(0)) revert LockAlreadyExists();

        IERC20(bondToken).safeTransferFrom(msg.sender, address(this), amount);

        locks[lockId] = Lock({
            seller: msg.sender,
            buyer: buyer,
            bondToken: bondToken,
            amount: amount,
            hashlock: hashlock,
            timeout: timeout,
            claimed: false,
            refunded: false
        });

        emit Locked(lockId, msg.sender, buyer, bondToken, amount, hashlock, timeout);
    }

    function claim(bytes32 lockId, bytes32 preimage) external {
        Lock storage l = locks[lockId];
        if (l.seller == address(0)) revert NoSuchLock();
        if (l.claimed || l.refunded) revert AlreadySettled();
        if (keccak256(abi.encode(preimage)) != l.hashlock) {
            revert WrongPreimage();
        }
        if (block.timestamp > l.timeout) revert LockExpired();

        l.claimed = true;
        IERC20(l.bondToken).safeTransfer(l.buyer, l.amount);
        emit Claimed(lockId, preimage);
    }

    function refund(bytes32 lockId) external {
        Lock storage l = locks[lockId];
        if (l.seller == address(0)) revert NoSuchLock();
        if (l.claimed || l.refunded) revert AlreadySettled();
        if (block.timestamp <= l.timeout) revert NotYetExpired();

        l.refunded = true;
        IERC20(l.bondToken).safeTransfer(l.seller, l.amount);
        emit Refunded(lockId);
    }
}
