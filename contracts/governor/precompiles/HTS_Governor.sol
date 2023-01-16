pragma solidity >=0.5.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "./IHTS_Governor.sol";

// SPDX-License-Identifier: Apache-2.0
abstract contract HTS_Governor {
    address constant precompileAddress = address(0x167);

    int32 internal constant SUCCESS = 22; // The transaction succeeded

    error NonSuccess();

    function getNonFungibleTokenOwner(address token, int64 serialNumber) internal returns (address) {
        (, bytes memory result) = precompileAddress.call(
            abi.encodeWithSelector(IHTS_Governor.getNonFungibleTokenInfo.selector, token, serialNumber));
        (int32 responseCode, IHTS_Governor.NonFungibleTokenInfo memory tokenInfo) = abi.decode(result, (int32, IHTS_Governor.NonFungibleTokenInfo));
        if (responseCode != SUCCESS) revert NonSuccess();
        return tokenInfo.ownerId;
    }
}
