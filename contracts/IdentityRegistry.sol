// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IdentityRegistry
/// @notice KYC/whitelist registry. A wallet must be registered here before
/// it can hold or trade a DGBToken.
contract IdentityRegistry {
    address public complianceOfficer;
    address public pendingComplianceOfficer;

    mapping(address => bool) public isVerified;
    mapping(address => bytes2) public countryOf;
    mapping(address => bool) public isApprovedContract;

    event Registered(address indexed wallet, bytes2 country);
    event Revoked(address indexed wallet);
    event ContractApproved(address indexed contractAddress);
    event ContractApprovalRevoked(address indexed contractAddress);
    event ComplianceOfficerTransferStarted(address indexed previousOfficer, address indexed newOfficer);
    event ComplianceOfficerTransferred(address indexed previousOfficer, address indexed newOfficer);

    error NotComplianceOfficer();
    error NotPendingComplianceOfficer();
    error ZeroAddress();
    error ArrayLengthMismatch();

    modifier onlyCompliance() {
        if (msg.sender != complianceOfficer) revert NotComplianceOfficer();
        _;
    }

    constructor(address _complianceOfficer) {
        if (_complianceOfficer == address(0)) revert ZeroAddress();
        complianceOfficer = _complianceOfficer;
    }

    function register(address wallet, bytes2 country) external onlyCompliance {
        _register(wallet, country);
    }

    /// @dev Batch registration for onboarding a cohort in one tx.
    function registerBatch(address[] calldata wallets, bytes2[] calldata countries) external onlyCompliance {
        if (wallets.length != countries.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < wallets.length; i++) {
            _register(wallets[i], countries[i]);
        }
    }

    function _register(address wallet, bytes2 country) internal {
        if (wallet == address(0)) revert ZeroAddress();
        isVerified[wallet] = true;
        countryOf[wallet] = country;
        emit Registered(wallet, country);
    }

    function revoke(address wallet) external onlyCompliance {
        isVerified[wallet] = false;
        emit Revoked(wallet);
    }

    /// @dev Approves a non-human contract (e.g. PontesDvP) as a valid
    /// transfer counterparty, without treating it as a KYC'd identity.
    function approveContract(address contractAddress) external onlyCompliance {
        if (contractAddress == address(0)) revert ZeroAddress();
        isApprovedContract[contractAddress] = true;
        emit ContractApproved(contractAddress);
    }

    function revokeContractApproval(address contractAddress) external onlyCompliance {
        isApprovedContract[contractAddress] = false;
        emit ContractApprovalRevoked(contractAddress);
    }

    /// @dev Two-step handover so a mistyped address can't brick registration.
    function transferComplianceOfficer(address newOfficer) external onlyCompliance {
        if (newOfficer == address(0)) revert ZeroAddress();
        pendingComplianceOfficer = newOfficer;
        emit ComplianceOfficerTransferStarted(complianceOfficer, newOfficer);
    }

    function acceptComplianceOfficer() external {
        if (msg.sender != pendingComplianceOfficer) {
            revert NotPendingComplianceOfficer();
        }
        emit ComplianceOfficerTransferred(complianceOfficer, msg.sender);
        complianceOfficer = msg.sender;
        pendingComplianceOfficer = address(0);
    }

    function canHold(address wallet) external view returns (bool) {
        return isVerified[wallet] || isApprovedContract[wallet];
    }
}
