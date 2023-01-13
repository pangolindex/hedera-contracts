// SPDX-License-Identifier: MIT
pragma solidity =0.8.15;

interface IMultiSigTransaction {
    function MULTISIG() external view returns (address);
    function confirmation(address account) external view returns (bool);
    function getConfirmations() external view returns (address[] memory);
    function getTransaction() external view returns (IMultiSigWallet.Transaction memory);
    function setTransaction(IMultiSigWallet.Transaction memory transaction) external;
    function setExecuted() external;
    function confirm(address account) external;
    function revoke(address account) external;
}

contract MultiSigTransaction is IMultiSigTransaction {
    address public immutable MULTISIG;
    IMultiSigWallet.Transaction private transaction;
    address[] private confirmations;

    mapping(address => bool) public confirmation;

    error AccessDenied();
    error AlreadyExecuted();
    error NoEffect();

    modifier onlyMultisig() {
        if (msg.sender != MULTISIG) revert AccessDenied();
        _;
    }

    modifier notExecuted() {
        if (transaction.executed) revert AlreadyExecuted();
        _;
    }

    constructor() {
        MULTISIG = msg.sender;
    }

    function getConfirmations() external view returns (address[] memory) {
        return confirmations;
    }

    function getTransaction() external view returns (IMultiSigWallet.Transaction memory) {
        return transaction;
    }

    // @dev Will always & can only be called once when constructed by MultiSigWallet
    function setTransaction(IMultiSigWallet.Transaction memory transaction) external onlyMultisig {
        transaction = transaction;
    }

    function setExecuted() external onlyMultisig notExecuted {
        transaction.executed = true;
    }

    // @dev Once the transaction is executed, confirmations cannot be added
    function confirm(address account) external onlyMultisig notExecuted {
        if (confirmation[account]) revert NoEffect();
        confirmation[account] = true;
        confirmations.push(account);
    }

    // @dev Allows any account with a confirmation to revoke it
    // @dev Once the transaction is executed, confirmations are final
    function revoke(address account) external onlyMultisig notExecuted {
        if (!confirmation[account]) revert NoEffect();
        confirmation[account] = false;
        address[] storage _confirmations = confirmations; // Gas savings
        uint256 confirmationCountWithoutLastSigner = _confirmations.length - 1; // Gas savings
        for (uint256 i; i < confirmationCountWithoutLastSigner; ++i) {
            if (_confirmations[i] == account) {
                confirmations[i] = _confirmations[confirmationCountWithoutLastSigner];
                break;
            }
        }
        confirmations.pop();
    }
}

abstract contract MultiSigHelper {
    function createTransaction(uint256 transactionId) internal returns (address) {
        return _create2(
            keccak256(abi.encodePacked(transactionId)),
            abi.encodePacked(type(MultiSigTransaction).creationCode)
        );
    }

    function locateTransaction(uint256 transactionId) internal view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(
                bytes1(0xff),
                address(this),
                keccak256(abi.encodePacked(transactionId)),
                keccak256(abi.encodePacked(type(MultiSigTransaction).creationCode))
            ));
        return address(uint160(uint256(hash)));
    }

    /**
     * @dev When utilizing create2 via assembly, failing calls will return the 0x0 address
     * @dev Consuming methods must handle this logic gracefully
     */
    function _create2(bytes32 salt, bytes memory bytecode) private returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
    }
}

interface IMultiSigWallet {
    event Confirmation(address indexed sender, uint256 indexed transactionId);
    event Revocation(address indexed sender, uint256 indexed transactionId);
    event Submission(uint256 indexed transactionId);
    event Execution(uint256 indexed transactionId);
    event Deposit(address indexed sender, uint256 value);
    event OwnerAddition(address indexed owner);
    event OwnerRemoval(address indexed owner);
    event RequirementChange(uint256 required);

    error OnlyWallet();
    error OwnerExists();
    error OwnerDoesNotExist();
    error InvalidArgument();

    error InsufficientConfirmations();
    error ExecutionError();

    struct Transaction {
        address[] destinations;
        uint256[] values;
        bytes[] datas;
        bool executed;
    }

    function addOwner(address owner) external;
    function removeOwner(address owner) external;
    function replaceOwner(address owner, address newOwner) external;
    function changeRequirement(uint256 _required) external;
    function submitTransaction(address[] memory destinations, uint256[] memory values, bytes[] memory datas) external returns (uint256 transactionId);
    function confirmTransaction(uint256 transactionId) external;
    function revokeConfirmation(uint256 transactionId) external;
    function executeTransaction(uint256 transactionId) external payable;
    function transactions(uint256 transactionId) external view returns (IMultiSigWallet.Transaction memory);
    function confirmations(uint256 transactionId, address account) external view returns (bool);
    function isConfirmed(uint256 transactionId) external view returns (bool);
    function getConfirmationCount(uint256 transactionId) external view returns (uint256 count);
    function getTransactionCount(bool pending, bool executed) external view returns (uint256 count);
    function getOwners() external view returns (address[] memory owners);
    function getConfirmations(uint256 transactionId) external view returns (address[] memory confirmationAddresses);
    function getTransactionIds(uint256 from, uint256 to, bool pending, bool executed) external view returns (uint256[] memory transactionIds);
}

contract MultiSigWallet is IMultiSigWallet, MultiSigHelper {

    uint256 constant public MAX_OWNER_COUNT = 50;
    uint256 constant public MAX_TRANSACTION_ACTIONS = 10;

    // Storage
    mapping(address => bool) public isOwner;
    address[] public owners;
    uint256 public required;
    uint256 public transactionCount;

    modifier onlyWallet() {
        if (msg.sender == address(this)) revert OnlyWallet();
        _;
    }

    modifier ownerDoesNotExist(address owner) {
        if (isOwner[owner]) revert OwnerExists();
        _;
    }

    modifier ownerExists(address owner) {
        if (!isOwner[owner]) revert OwnerDoesNotExist();
        _;
    }

    modifier validRequirement(uint256 ownerCount, uint256 _required) {
        if (ownerCount > MAX_OWNER_COUNT) revert InvalidArgument();
        if (_required > ownerCount) revert InvalidArgument();
        if (_required == 0) revert InvalidArgument();
        if (ownerCount == 0) revert InvalidArgument();
        _;
    }

    receive() external payable {
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value);
        }
    }


    /// @dev Contract constructor sets initial owners and required number of confirmations.
    /// @param _owners List of initial owners.
    /// @param _required Number of required confirmations.
    constructor(address[] memory _owners, uint256 _required) validRequirement(_owners.length, _required) {
        uint256 ownersLength = _owners.length; // Gas savings
        for (uint256 i; i < ownersLength; ++i) {
            address newOwner = _owners[i];
            if (isOwner[newOwner] || newOwner == address(0)) revert InvalidArgument();
            isOwner[newOwner] = true;
        }
        owners = _owners;
        required = _required;
    }

    /// @dev Allows to add a new owner. Transaction has to be sent by wallet.
    /// @param owner Address of new owner.
    function addOwner(address owner)
    public
    onlyWallet
    ownerDoesNotExist(owner)
    validRequirement(owners.length + 1, required)
    {
        if (owner == address(0)) revert InvalidArgument();
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAddition(owner);
    }

    /// @dev Allows to remove an owner. Transaction has to be sent by wallet.
    /// @param owner Address of owner.
    function removeOwner(address owner)
    public
    onlyWallet
    ownerExists(owner)
    {
        isOwner[owner] = false;
        uint256 ownersLengthWithoutLastOwner = owners.length - 1; // Gas savings
        for (uint256 i; i < ownersLengthWithoutLastOwner; ++i) {
            if (owners[i] == owner) {
                owners[i] = owners[ownersLengthWithoutLastOwner];
                break;
            }
        }
        owners.pop(); // Remove last owner to shrink owners array
        if (required > owners.length) {
            changeRequirement(owners.length);
        }
        emit OwnerRemoval(owner);
    }

    /// @dev Allows to replace an owner with a new owner. Transaction has to be sent by wallet.
    /// @param owner Address of owner to be replaced.
    /// @param newOwner Address of new owner.
    function replaceOwner(address owner, address newOwner)
    public
    onlyWallet
    ownerExists(owner)
    ownerDoesNotExist(newOwner)
    {
        uint256 ownersLength = owners.length; // Gas savings
        for (uint256 i; i < ownersLength; ++i) {
            if (owners[i] == owner) {
                owners[i] = newOwner;
                break;
            }
        }
        isOwner[owner] = false;
        isOwner[newOwner] = true;
        emit OwnerRemoval(owner);
        emit OwnerAddition(newOwner);
    }

    /// @dev Allows to change the number of required confirmations. Transaction has to be sent by wallet.
    /// @param _required Number of required confirmations.
    function changeRequirement(uint256 _required)
    public
    onlyWallet
    validRequirement(owners.length, _required)
    {
        required = _required;
        emit RequirementChange(_required);
    }

    /// @dev Allows an owner to submit and confirm a transaction.
    /// @param destinations Transaction target addresses.
    /// @param values Transaction ether values.
    /// @param datas Transaction data payloads.
    /// @return transactionId Returns transaction ID.
    function submitTransaction(address[] memory destinations, uint256[] memory values, bytes[] memory datas)
    public
    returns (uint256 transactionId)
    {
        transactionId = _addTransaction(destinations, values, datas);
        confirmTransaction(transactionId);
    }

    /// @dev Allows an owner to confirm a transaction.
    /// @param transactionId Transaction ID.
    function confirmTransaction(uint256 transactionId)
    public
    ownerExists(msg.sender)
    {
        address transactionContract = MultiSigHelper.locateTransaction(transactionId);
        IMultiSigTransaction(transactionContract).confirm(msg.sender);
        emit Confirmation(msg.sender, transactionId);
    }

    /// @dev Allows any owner (or previous owner) to revoke a confirmation for a transaction.
    /// @param transactionId Transaction ID.
    function revokeConfirmation(uint256 transactionId)
    public
    {
        address transactionContract = MultiSigHelper.locateTransaction(transactionId);
        IMultiSigTransaction(transactionContract).revoke(msg.sender);
        emit Revocation(msg.sender, transactionId);
    }

    /// @dev Allows any owner to execute a confirmed transaction.
    /// @param transactionId Transaction ID.
    function executeTransaction(uint256 transactionId)
    public
    payable
    ownerExists(msg.sender)
    {
        if (isConfirmed(transactionId)) {
            address transactionContract = MultiSigHelper.locateTransaction(transactionId);
            IMultiSigWallet.Transaction memory transaction = IMultiSigTransaction(transactionContract).getTransaction();
            uint256 transactionExecutions = transaction.destinations.length;
            for (uint256 i; i < transactionExecutions; ++i) {
                (bool success, bytes memory returnData) = transaction.destinations[i].call{value: transaction.values[i]}(transaction.datas[i]);
                if (!success) {
                    revert ExecutionError();
                }
            }
            IMultiSigTransaction(transactionContract).setExecuted();
            emit Execution(transactionId);
        } else {
            revert InsufficientConfirmations();
        }
    }

    /// @dev Returns transaction information and provides legacy compatibility.
    /// @dev transactionId Transaction ID.
    function transactions(uint256 transactionId) external view returns (IMultiSigWallet.Transaction memory) {
        address transactionContract = MultiSigHelper.locateTransaction(transactionId);
        return IMultiSigTransaction(transactionContract).getTransaction();
    }

    /// @dev Returns confirmation information about a transaction and provides legacy compatibility.
    /// @param transactionId Transaction ID.
    /// @param account Signer address to lookup.
    function confirmations(uint256 transactionId, address account) external view returns (bool) {
        address transactionContract = MultiSigHelper.locateTransaction(transactionId);
        return IMultiSigTransaction(transactionContract).confirmation(account);
    }

    /// @dev Returns the confirmation status of a transaction.
    /// @param transactionId Transaction ID.
    /// @return Confirmation status.
    function isConfirmed(uint256 transactionId)
    public
    view
    returns (bool)
    {
        return getConfirmationCount(transactionId) >= required;
    }


    /// @dev Adds a new transaction to the transaction mapping, if transaction does not exist yet.
    /// @param destinations Transaction target addresses.
    /// @param values Transaction ether values.
    /// @param datas Transaction data payloads.
    /// @return transactionId Returns transaction ID.
    function _addTransaction(address[] memory destinations, uint256[] memory values, bytes[] memory datas)
    internal
    returns (uint256 transactionId)
    {
        if (destinations.length != values.length || values.length != datas.length) revert InvalidArgument();
        if (datas.length > MAX_TRANSACTION_ACTIONS) revert InvalidArgument();
        transactionId = transactionCount;
        address transactionContract = MultiSigHelper.createTransaction(transactionId);
        IMultiSigTransaction(transactionContract).setTransaction(Transaction({
            destinations : destinations,
            values : values,
            datas : datas,
            executed : false
        }));
        transactionCount += 1;
        emit Submission(transactionId);
    }


    /// @dev Returns number of confirmations of a transaction.
    /// @param transactionId Transaction ID.
    /// @return count Number of confirmations.
    function getConfirmationCount(uint256 transactionId)
    public
    view
    returns (uint256 count)
    {
        address transactionContract = MultiSigHelper.locateTransaction(transactionId);
        return IMultiSigTransaction(transactionContract).getConfirmations().length;
    }

    /// @dev Returns total number of transactions after filers are applied.
    /// @param pending Include pending transactions.
    /// @param executed Include executed transactions.
    /// @return count Total number of transactions after filters are applied.
    function getTransactionCount(bool pending, bool executed)
    public
    view
    returns (uint256 count)
    {
        for (uint256 txId; txId < transactionCount; ++txId) {
            address transactionContract = MultiSigHelper.locateTransaction(txId);
            IMultiSigWallet.Transaction memory transaction = IMultiSigTransaction(transactionContract).getTransaction();
            if (pending && !transaction.executed || executed && transaction.executed) {
                count += 1;
            }
        }
    }

    /// @dev Returns list of owners.
    /// @return List of owner addresses.
    function getOwners()
    public
    view
    returns (address[] memory)
    {
        return owners;
    }

    /// @dev Returns array of owners (present or past) which confirmed transaction.
    /// @param transactionId Transaction ID.
    /// @return confirmationAddresses Returns array of owner addresses.
    function getConfirmations(uint256 transactionId)
    public
    view
    returns (address[] memory confirmationAddresses)
    {
        address transactionContract = MultiSigHelper.locateTransaction(transactionId);
        return IMultiSigTransaction(transactionContract).getConfirmations();
    }

    /// @dev Returns list of transaction IDs in defined range.
    /// @param from Index start position of transaction array.
    /// @param to Index end position of transaction array.
    /// @param pending Include pending transactions.
    /// @param executed Include executed transactions.
    /// @return transactionIds Returns array of transaction IDs.
    function getTransactionIds(uint256 from, uint256 to, bool pending, bool executed)
    public
    view
    returns (uint256[] memory transactionIds)
    {
        if (to <= from) revert InvalidArgument();

        uint256[] memory transactionIdsTemp = new uint256[](to - from);
        uint256 txIdCount;

        // Populate oversized array
        for (uint256 txId = from; txId < to; ++txId) {
            address transactionContract = MultiSigHelper.locateTransaction(txId);
            IMultiSigWallet.Transaction memory transaction = IMultiSigTransaction(transactionContract).getTransaction();
            if (pending && !transaction.executed || executed && transaction.executed) {
                transactionIdsTemp[txIdCount] = txId;
                txIdCount += 1;
            }
        }

        // Populate correctly sized array
        transactionIds = new uint256[](txIdCount);
        for (uint256 i; i < txIdCount; ++i) {
            transactionIds[i] = transactionIdsTemp[i];
        }
    }
}
