// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import './hts-precompile/HederaResponseCodes.sol';
import './hts-precompile/HederaTokenService.sol';
import "./hts-precompile/ExpiryHelper.sol";

contract TreasuryVester is HederaTokenService, ExpiryHelper, AccessControlEnumerable, Pausable {
    using SafeERC20 for IERC20;

    struct Recipient{
        address account;
        int64 allocation;
    }

    Recipient[] public recipients;

    uint32 private constant DECIMALS = 8; // eight
    int64 private constant MAX_SUPPLY = int64(230_000_000) * int64(uint64(10**DECIMALS)); // two-hundred-and-thirty million
    uint64 private constant INITIAL_SUPPLY = uint64(11_500_000) * uint64(10**DECIMALS); // eleven million and five-hundred thousand (airdrop supply)
    uint256 private constant SUPPLY_KEY = 16; // 4th bit (counting from 0) flipped, i.e. 10000 binary.
    uint256 private constant STEPS_TO_SLASH = 30; // increment index from vestingAmounts array every 30 distributions

    uint256 private constant MAX_RECIPIENTS = 20;
    uint256 private constant VESTING_CLIFF = 1 days;
    uint256 public lastDistributedTime;

    int64 public constant DENOMINATOR = 10_000; // ten-thousand

    address immutable PNG;

    bool public initialSupplyTransferredOut;

    uint256 public distributionCount; // num of times distribute func was executed.

    // daily amount distributed on each month. e.g., first 30 distributions will distribute 182083333333333 each, bar dust. ~218.5M total (max supply - airdrop).
    int64[30] public vestingAmounts = [ int64(182083333333333), 101966666666666, 58266666666666, 38601666666666, 28405000000000, 26948333333333, 25491666666666, 24035000000000, 22578333333333, 21121666666666, 19665000000000, 18208333333333, 17115833333333, 16023333333333, 14930833333333, 13838333333333, 12745833333333, 11653333333333, 10560833333333, 9468333333333, 8740000000000, 8011666666666, 7283333333333, 6555000000000, 5826666666666, 5098333333333, 4370000000000, 3641666666666, 2913333333333, 2185000000000 ];

    event TokensVested(int64 amount);
    event RecipientsChanged(address[] accounts, int64[] allocations);

    modifier daily() {
        require(block.timestamp - lastDistributedTime >= VESTING_CLIFF, "One day has not passed.");
        lastDistributedTime = block.timestamp;
        _;
    }

    constructor(address admin) payable {
        // Ensure contract is initially paused.
        _pause();

        // Assign roles.
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // Create Pangolin token. //
        ////////////////////////////

        // Define the key of this contract.
        IHederaTokenService.KeyValue memory key;
        key.contractId = address(this);

        // Define a supply key which gives this contract minting and burning access.
        IHederaTokenService.TokenKey memory supplyKey;
        supplyKey.keyType = SUPPLY_KEY;
        supplyKey.key = key;

        // Define the key types used in the token. Only supply key used.
        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](1);
        keys[0] = supplyKey;

        // Define the token properties.
        IHederaTokenService.HederaToken memory token;
        token.name = "Pangolin Hedera";
        token.symbol = "PHD";
        token.memo = "https://static.pangolin.exchange/pangolin-hedera-metadata.json";
        token.treasury = address(this);
        token.tokenKeys = keys;
        token.tokenSupplyType = true; // Finite.
        token.maxSupply = MAX_SUPPLY;
        token.expiry = createAutoRenewExpiry(address(this), 90 days);

        // Create the token.
        (int256 responseCode, address tokenId) = createFungibleToken(token, INITIAL_SUPPLY, uint32(DECIMALS));
        require(responseCode == HederaResponseCodes.SUCCESS, "Token creation failed");

        // Set the immutable state variable for the distribution token.
        PNG = tokenId;
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(recipients.length != 0, "No recipients");
        _unpause();
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function transferInitialSupply(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!initialSupplyTransferredOut, "Initial supply already claimed");
        initialSupplyTransferredOut = true;
        IERC20(PNG).safeTransfer(to, INITIAL_SUPPLY);
    }

    // just a single function to overwrite previous recipients with new ones.
    function setRecipients(address[] calldata accounts, int64[] calldata allocations) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 newRecipientsLength = accounts.length;
        require(newRecipientsLength == allocations.length, "Array length mismatch");
        require(newRecipientsLength <= MAX_RECIPIENTS, "Max recipients exceeded");
        require(newRecipientsLength != 0, "Null input");

        delete recipients; // simply nuke the existing recipients

        int64 totalAllocations;
        for (uint256 i; i < newRecipientsLength;) {
            int64 allocation = allocations[i];

            require(allocation > 0, "Invalid allocation");
            recipients.push(
                Recipient({
                    account: accounts[i],
                    allocation: allocation
                })
            );
            totalAllocations += allocation;

            unchecked {
                ++i;
            }
        }
        require(totalAllocations == DENOMINATOR, "Invalid allocation sum");

        emit RecipientsChanged(accounts, allocations);
    }

    function distribute() external daily whenNotPaused {
        int64 vestingAmount = vestingAmounts[distributionCount++ / STEPS_TO_SLASH];

        uint256 tmpRecipientsLength = recipients.length;
        uint256 allTransactors = tmpRecipientsLength + 1; // incl. this address as sender of funds

        address[] memory accountIds = new address[](allTransactors);
        int64[] memory amounts = new int64[](allTransactors);
        int64 actualVestingAmount; // vesting amount excl. dust

        // Populate atomic swap properties.
        for (uint256 i; i < tmpRecipientsLength;) {
            Recipient memory recipient = recipients[i];

            int64 amount = vestingAmount * recipient.allocation / DENOMINATOR;
            actualVestingAmount += amount;
            amounts[i] = amount;
            accountIds[i] = recipient.account;

            unchecked {
                ++i;
            }
        }

        accountIds[tmpRecipientsLength] = address(this);
        amounts[tmpRecipientsLength] = -(actualVestingAmount); // negative to debit from this addr

        _mint(actualVestingAmount);

        int256 responseCode = transferTokens(PNG, accountIds, amounts);
        require(responseCode == HederaResponseCodes.SUCCESS, "Transfer faied");

        emit TokensVested(vestingAmount);
    }

    function _mint(int64 amount) private {
        assert(amount > 0);
        (int256 responseCode,,) = mintToken(PNG, uint64(amount), new bytes[](0));
        require(responseCode == HederaResponseCodes.SUCCESS, "Mint failed");
    }
}
