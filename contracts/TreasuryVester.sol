// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

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

    uint32 private constant MAX_SUPPLY = 242_000_000 * uint32(10)**DECIMALS; // two-hundred-and-fourty- million
    uint32 private constant INITIAL_SUPPLY = 12_000_000 * uint32(10)**DECIMALS; // twelve million (airdrop supply)
    uint256 private constant DECIMALS = 8; // eight
    uint256 private constant SUPPLY_KEY = 16; // 4th bit (counting from 0) flipped, i.e. 10000 binary.
    uint256 private constant STEPS_TO_SLASH = 30; // increment index from vestingAmounts array every 30 distributions

    uint256 private constant MAX_RECIPIENTS = 20;
    uint256 private constant VESTING_CLIFF = 1 days;
    uint256 public lastDistributedTime;

    int64 public constant DENOMINATOR = 10_000; // ten-thousand

    address immutable PNG;

    bool public initialSupplyTransferredOut;

    uint256 public distributionCount; // num of times distribute func was executed.

    // daily amount distributed on each month. e.g., first 30 distributions will distribute 191666666666666 each, bar dust. ~230m total.
    int64[30] public vestingAmounts = [ int64(191666666666666), 107333333333333, 61333333333333, 40633333333333, 29900000000000, 28366666666666, 26833333333333, 25300000000000, 23766666666666, 22233333333333, 20700000000000, 19166666666666, 18016666666666, 16866666666666, 15716666666666, 14566666666666, 13416666666666, 12266666666666, 11116666666666, 9966666666666, 9200000000000, 8433333333335, 7666666666668, 6900000000000, 6133333333335, 5366666666668, 4600000000000, 3833333333335, 3066666666668, 2300000000000 ];

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
        token.symbol = "PBAR";
        token.treasury = address(this); // also associates token?
        token.tokenKeys = keys;
        //token.tokenSupplyType = true; // Finite.
        //token.maxSupply = MAX_SUPPLY; // IHederaTokenService expects this value to fit uint32?!
        token.expiry = createAutoRenewExpiry(address(this), 90 days);

        // Create the token.
        (int256 responseCode, address tokenId) = createFungibleToken(token, INITIAL_SUPPLY, DECIMALS);
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
        bytes[] memory serialNumbers = new bytes[](0);
        (int256 responseCode,,) = mintToken(PNG, uint64(amount), serialNumbers);
        require(responseCode == HederaResponseCodes.SUCCESS, "Mint failed");
    }
}
