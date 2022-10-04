// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

import { IEnglishAuctions } from "../IMarketplace.sol";

library EnglishAuctionsStorage {
    bytes32 public constant ENGLISH_AUCTIONS_STORAGE_POSITION = keccak256("english.auctions.storage");

    struct Data {
        address platformFeeRecipient;
        uint64 platformFeeBps;
        uint256 totalAuctions;
        mapping(uint256 => IEnglishAuctions.Auction) auctions;
        mapping(uint256 => IEnglishAuctions.Bid) winningBid;
    }

    function englishAuctionsStorage() internal pure returns (Data storage englishAuctionsData) {
        bytes32 position = ENGLISH_AUCTIONS_STORAGE_POSITION;
        assembly {
            englishAuctionsData.slot := position
        }
    }
}
