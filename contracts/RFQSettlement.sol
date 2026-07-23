// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title RFQSettlement
/// @notice Market makers sign off-chain price quotes (EIP-712); the named
/// taker submits the signed quote here and both legs settle atomically.
contract RFQSettlement is EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    struct Quote {
        address marketMaker;
        address taker;
        address bondToken;
        address quoteToken;
        uint256 bondAmount;
        uint256 quoteAmount;
        uint256 expiry;
        uint256 nonce;
    }

    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "Quote(address marketMaker,address taker,address bondToken,address quoteToken,uint256 bondAmount,uint256 quoteAmount,uint256 expiry,uint256 nonce)"
    );

    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    event Filled(
        address indexed marketMaker, address indexed taker, address bondToken, uint256 bondAmount, uint256 quoteAmount
    );
    event QuoteCancelled(address indexed marketMaker, uint256 nonce);

    error QuoteExpired();
    error NonceAlreadyUsed();
    error BadSignature();
    error NotTheQuotedTaker();

    constructor() EIP712("DanskBondRFQ", "1") {}

    /// @dev Requires msg.sender == q.taker, so only the named taker's own
    /// call can trigger execution of a maker's signed quote.
    function fillQuote(Quote calldata q, bytes calldata signature) external {
        if (msg.sender != q.taker) revert NotTheQuotedTaker();
        if (block.timestamp > q.expiry) revert QuoteExpired();
        if (nonceUsed[q.marketMaker][q.nonce]) revert NonceAlreadyUsed();

        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
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
        address signer = _hashTypedDataV4(structHash).recover(signature);
        if (signer != q.marketMaker) revert BadSignature();

        nonceUsed[q.marketMaker][q.nonce] = true;

        IERC20(q.quoteToken).safeTransferFrom(msg.sender, q.marketMaker, q.quoteAmount);
        IERC20(q.bondToken).safeTransferFrom(q.marketMaker, msg.sender, q.bondAmount);

        emit Filled(q.marketMaker, msg.sender, q.bondToken, q.bondAmount, q.quoteAmount);
    }

    /// @dev Lets a market maker invalidate a quote it no longer wants to honour.
    function cancelQuote(uint256 nonce) external {
        nonceUsed[msg.sender][nonce] = true;
        emit QuoteCancelled(msg.sender, nonce);
    }
}
