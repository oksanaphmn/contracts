// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

import "./EnglishAuctionsStorage.sol";

// ====== External imports ======
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

// ====== Internal imports ======

import "../extension/ERC2771ContextConsumer.sol";

import "../../extension/interface/IPlatformFee.sol";

import "../extension/ReentrancyGuard.sol";
import "../extension/PermissionsEnumerable.sol";
import { CurrencyTransferLib } from "../../lib/CurrencyTransferLib.sol";

contract EnglishAuctions is IEnglishAuctions, ReentrancyGuard, ERC2771ContextConsumer {
    /*///////////////////////////////////////////////////////////////
                        Constants / Immutables
    //////////////////////////////////////////////////////////////*/

    /// @dev Only lister role holders can create auctions, when auctions are restricted by lister address.
    bytes32 private constant LISTER_ROLE = keccak256("LISTER_ROLE");
    /// @dev Only assets from NFT contracts with asset role can be auctioned, when auctions are restricted by asset address.
    bytes32 private constant ASSET_ROLE = keccak256("ASSET_ROLE");

    /// @dev The max bps of the contract. So, 10_000 == 100 %
    uint64 public constant MAX_BPS = 10_000;

    /// @dev The address of the native token wrapper contract.
    address private immutable nativeTokenWrapper;

    /*///////////////////////////////////////////////////////////////
                              Modifiers
    //////////////////////////////////////////////////////////////*/

    modifier onlyListerRole() {
        require(Permissions(address(this)).hasRoleWithSwitch(LISTER_ROLE, _msgSender()), "!LISTER_ROLE");
        _;
    }

    modifier onlyAssetRole(address _asset) {
        require(Permissions(address(this)).hasRoleWithSwitch(ASSET_ROLE, _asset), "!ASSET_ROLE");
        _;
    }

    /// @dev Checks whether caller is a auction creator.
    modifier onlyAuctionCreator(uint256 _auctionId) {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();

        require(data.auctions[_auctionId].auctionCreator == _msgSender(), "!Creator");
        _;
    }

    /// @dev Checks whether an auction exists.
    modifier onlyExistingAuction(uint256 _auctionId) {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        require(data.auctions[_auctionId].assetContract != address(0), "DNE");
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            Constructor logic
    //////////////////////////////////////////////////////////////*/

    constructor(address _nativeTokenWrapper) {
        nativeTokenWrapper = _nativeTokenWrapper;
    }

    /*///////////////////////////////////////////////////////////////
                            External functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Auction ERC721 or ERC1155 NFTs.
    function createAuction(AuctionParameters calldata _params)
        external
        onlyListerRole
        onlyAssetRole(_params.assetContract)
        returns (uint256 auctionId)
    {
        auctionId = _getNextAuctionId();
        address auctionCreator = _msgSender();
        TokenType tokenType = _getTokenType(_params.assetContract);

        _validateNewAuction(_params, tokenType);

        Auction memory auction = Auction({
            auctionId: auctionId,
            auctionCreator: auctionCreator,
            assetContract: _params.assetContract,
            tokenId: _params.tokenId,
            quantity: _params.quantity,
            currency: _params.currency,
            minimumBidAmount: _params.minimumBidAmount,
            buyoutBidAmount: _params.buyoutBidAmount,
            timeBufferInSeconds: _params.timeBufferInSeconds,
            bidBufferBps: _params.bidBufferBps,
            startTimestamp: _params.startTimestamp,
            endTimestamp: _params.endTimestamp,
            tokenType: tokenType
        });

        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        data.auctions[auctionId] = auction;

        require(auction.buyoutBidAmount >= auction.minimumBidAmount, "RESERVE");
        _transferAuctionTokens(auctionCreator, address(this), auction);

        emit NewAuction(auctionCreator, auctionId, auction);
    }

    function bidInAuction(uint256 _auctionId, uint256 _bidAmount)
        external
        payable
        nonReentrant
        onlyExistingAuction(_auctionId)
    {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        Auction memory _targetAuction = data.auctions[_auctionId];

        require(
            _targetAuction.endTimestamp > block.timestamp && _targetAuction.startTimestamp <= block.timestamp,
            "inactive auction."
        );

        Bid memory newBid = Bid({ auctionId: _auctionId, bidder: _msgSender(), bidAmount: _bidAmount });

        _handleBid(_targetAuction, newBid);
    }

    function collectAuctionPayout(uint256 _auctionId)
        external
        nonReentrant
        onlyExistingAuction(_auctionId)
        onlyAuctionCreator(_auctionId)
    {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        Auction memory _targetAuction = data.auctions[_auctionId];
        Bid memory _winningBid = data.winningBid[_auctionId];

        require(_targetAuction.endTimestamp <= block.timestamp, "auction still active.");
        require(_winningBid.bidder != address(0), "no bids were made.");

        _closeAuctionForAuctionCreator(_targetAuction, _winningBid);
    }

    function collectAuctionTokens(uint256 _auctionId) external nonReentrant onlyExistingAuction(_auctionId) {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        Auction memory _targetAuction = data.auctions[_auctionId];
        Bid memory _winningBid = data.winningBid[_auctionId];

        require(_targetAuction.endTimestamp <= block.timestamp, "auction still active.");
        require(_msgSender() == _winningBid.bidder, "not bidder");

        _closeAuctionForBidder(_targetAuction, _winningBid);
    }

    /// @dev Cancels an auction.
    function cancelAuction(uint256 _auctionId) external onlyExistingAuction(_auctionId) onlyAuctionCreator(_auctionId) {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        Auction memory _targetAuction = data.auctions[_auctionId];
        Bid memory _winningBid = data.winningBid[_auctionId];

        require(_winningBid.bidder == address(0), "bids already made");

        delete data.auctions[_auctionId];

        _transferAuctionTokens(address(this), _targetAuction.auctionCreator, _targetAuction);

        emit AuctionClosed(_targetAuction.auctionId, _msgSender(), true, _targetAuction.auctionCreator, address(0));
    }

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    function isNewWinningBid(uint256 _auctionId, uint256 _bidAmount)
        external
        view
        onlyExistingAuction(_auctionId)
        returns (bool)
    {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        Auction memory _targetAuction = data.auctions[_auctionId];
        Bid memory _currentWinningBid = data.winningBid[_auctionId];

        return
            _isNewWinningBid(
                _targetAuction.minimumBidAmount,
                _currentWinningBid.bidAmount,
                _bidAmount,
                _targetAuction.bidBufferBps
            );
    }

    function totalAuctions() external view returns (uint256) {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        return data.totalAuctions;
    }

    function getAuction(uint256 _auctionId)
        external
        view
        onlyExistingAuction(_auctionId)
        returns (Auction memory _auction)
    {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        _auction = data.auctions[_auctionId];
    }

    function getAllAuctions(uint256 _startId, uint256 _endId) external view returns (Auction[] memory _allAuctions) {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        require(_startId < _endId && _endId < data.totalAuctions, "invalid range");

        Auction[] memory _auctions = new Auction[](_endId - _startId + 1);
        uint256 _auctionCount;

        for (uint256 i = _startId; i <= _endId; i += 1) {
            _auctions[i] = data.auctions[i];
            if (_auctions[i].assetContract != address(0)) {
                _auctionCount += 1;
            }
        }

        _allAuctions = new Auction[](_auctionCount);
        for (uint256 i = _startId; i <= _endId; i += 1) {
            if (_auctions[i].assetContract != address(0)) {
                _allAuctions[i] = _auctions[i];
            }
        }
    }

    function getAllValidAuctions(uint256 _startId, uint256 _endId)
        external
        view
        returns (Auction[] memory _validAuctions)
    {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        require(_startId < _endId && _endId < data.totalAuctions, "invalid range");

        Auction[] memory _auctions = new Auction[](_endId - _startId + 1);
        uint256 _auctionCount;

        for (uint256 i = _startId; i <= _endId; i += 1) {
            _auctions[i] = data.auctions[i];
            if (
                _auctions[i].startTimestamp <= block.timestamp &&
                _auctions[i].endTimestamp > block.timestamp &&
                _auctions[i].assetContract != address(0)
            ) {
                _auctionCount += 1;
            }
        }

        _validAuctions = new Auction[](_auctionCount);
        for (uint256 i = _startId; i <= _endId; i += 1) {
            if (
                _auctions[i].startTimestamp <= block.timestamp &&
                _auctions[i].endTimestamp > block.timestamp &&
                _auctions[i].assetContract != address(0)
            ) {
                _validAuctions[i] = _auctions[i];
            }
        }
    }

    function getWinningBid(uint256 _auctionId)
        external
        view
        onlyExistingAuction(_auctionId)
        returns (
            address _bidder,
            address _currency,
            uint256 _bidAmount
        )
    {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        Auction memory _targetAuction = data.auctions[_auctionId];
        Bid memory _currentWinningBid = data.winningBid[_auctionId];

        _bidder = _currentWinningBid.bidder;
        _currency = _targetAuction.currency;
        _bidAmount = _currentWinningBid.bidAmount;
    }

    function isAuctionExpired(uint256 _auctionId) external view onlyExistingAuction(_auctionId) returns (bool) {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        return data.auctions[_auctionId].endTimestamp >= block.timestamp;
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the next auction Id.
    function _getNextAuctionId() internal returns (uint256 id) {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        id = data.totalAuctions;
        data.totalAuctions += 1;
    }

    /// @dev Returns the interface supported by a contract.
    function _getTokenType(address _assetContract) internal view returns (TokenType tokenType) {
        if (IERC165(_assetContract).supportsInterface(type(IERC1155).interfaceId)) {
            tokenType = TokenType.ERC1155;
        } else if (IERC165(_assetContract).supportsInterface(type(IERC721).interfaceId)) {
            tokenType = TokenType.ERC721;
        } else {
            revert("token must be ERC1155 or ERC721.");
        }
    }

    /// @dev Checks whether the auction creator owns and has approved marketplace to transfer auctioned tokens.
    function _validateNewAuction(AuctionParameters memory _params, TokenType _tokenType) internal view {
        require(_params.quantity > 0, "zero quantity.");
        require(_params.quantity == 1 || _tokenType == TokenType.ERC1155, "invalid quantity.");
        require(_params.timeBufferInSeconds > 0, "zero time-buffer.");
        require(_params.bidBufferBps > 0, "zero bid-buffer.");
        require(
            _params.startTimestamp >= block.timestamp && _params.startTimestamp < _params.endTimestamp,
            "invalid timestamps."
        );

        _validateOwnershipAndApproval(
            _msgSender(),
            _params.assetContract,
            _params.tokenId,
            _params.quantity,
            _tokenType
        );
    }

    /// @dev Validates that `_tokenOwner` owns and has approved Marketplace to transfer NFTs.
    function _validateOwnershipAndApproval(
        address _tokenOwner,
        address _assetContract,
        uint256 _tokenId,
        uint256 _quantity,
        TokenType _tokenType
    ) internal view {
        address market = address(this);
        bool isValid;

        if (_tokenType == TokenType.ERC1155) {
            isValid =
                IERC1155(_assetContract).balanceOf(_tokenOwner, _tokenId) >= _quantity &&
                IERC1155(_assetContract).isApprovedForAll(_tokenOwner, market);
        } else if (_tokenType == TokenType.ERC721) {
            isValid =
                IERC721(_assetContract).ownerOf(_tokenId) == _tokenOwner &&
                (IERC721(_assetContract).getApproved(_tokenId) == market ||
                    IERC721(_assetContract).isApprovedForAll(_tokenOwner, market));
        }

        require(isValid, "!BALNFT");
    }

    /// @dev Processes an incoming bid in an auction.
    function _handleBid(Auction memory _targetAuction, Bid memory _incomingBid) internal {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        Bid memory currentWinningBid = data.winningBid[_targetAuction.auctionId];
        uint256 currentBidAmount = currentWinningBid.bidAmount;
        uint256 incomingBidAmount = _incomingBid.bidAmount;
        address _nativeTokenWrapper = nativeTokenWrapper;

        // Close auction and execute sale if there's a buyout price and incoming bid amount is buyout price.
        if (_targetAuction.buyoutBidAmount > 0 && incomingBidAmount >= _targetAuction.buyoutBidAmount) {
            _closeAuctionForBidder(_targetAuction, _incomingBid);
        } else {
            /**
             *      If there's an exisitng winning bid, incoming bid amount must be bid buffer % greater.
             *      Else, bid amount must be at least as great as minimum bid amount
             */
            require(
                _isNewWinningBid(
                    _targetAuction.minimumBidAmount,
                    currentBidAmount,
                    incomingBidAmount,
                    _targetAuction.bidBufferBps
                ),
                "not winning bid."
            );

            // Update the winning bid and auction's end time before external contract calls.
            data.winningBid[_targetAuction.auctionId] = _incomingBid;

            if (_targetAuction.endTimestamp - block.timestamp <= _targetAuction.timeBufferInSeconds) {
                _targetAuction.endTimestamp += _targetAuction.timeBufferInSeconds;
                data.auctions[_targetAuction.auctionId] = _targetAuction;
            }
        }

        // Payout previous highest bid.
        if (currentWinningBid.bidder != address(0) && currentBidAmount > 0) {
            CurrencyTransferLib.transferCurrencyWithWrapper(
                _targetAuction.currency,
                address(this),
                currentWinningBid.bidder,
                currentBidAmount,
                _nativeTokenWrapper
            );
        }

        // Collect incoming bid
        CurrencyTransferLib.transferCurrencyWithWrapper(
            _targetAuction.currency,
            _incomingBid.bidder,
            address(this),
            incomingBidAmount,
            _nativeTokenWrapper
        );

        emit NewBid(_targetAuction.auctionId, _incomingBid.bidder, _incomingBid.bidAmount);
    }

    /// @dev Checks whether an incoming bid is the new current highest bid.
    function _isNewWinningBid(
        uint256 _minimumBidAmount,
        uint256 _currentWinningBidAmount,
        uint256 _incomingBidAmount,
        uint256 _bidBufferBps
    ) internal pure returns (bool isValidNewBid) {
        if (_currentWinningBidAmount == 0) {
            isValidNewBid = _incomingBidAmount >= _minimumBidAmount;
        } else {
            isValidNewBid = (_incomingBidAmount > _currentWinningBidAmount &&
                ((_incomingBidAmount - _currentWinningBidAmount) * MAX_BPS) / _currentWinningBidAmount >=
                _bidBufferBps);
        }
    }

    /// @dev Closes an auction for the winning bidder; distributes auction items to the winning bidder.
    function _closeAuctionForBidder(Auction memory _targetAuction, Bid memory _winningBid) internal {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        _targetAuction.endTimestamp = uint64(block.timestamp);

        data.winningBid[_targetAuction.auctionId] = _winningBid;
        data.auctions[_targetAuction.auctionId] = _targetAuction;

        _transferAuctionTokens(address(this), _winningBid.bidder, _targetAuction);

        emit AuctionClosed(
            _targetAuction.auctionId,
            _msgSender(),
            false,
            _targetAuction.auctionCreator,
            _winningBid.bidder
        );
    }

    /// @dev Closes an auction for an auction creator; distributes winning bid amount to auction creator.
    function _closeAuctionForAuctionCreator(Auction memory _targetAuction, Bid memory _winningBid) internal {
        EnglishAuctionsStorage.Data storage data = EnglishAuctionsStorage.englishAuctionsStorage();
        uint256 payoutAmount = _winningBid.bidAmount;

        _targetAuction.quantity = 0;
        _targetAuction.endTimestamp = uint64(block.timestamp);
        data.auctions[_targetAuction.auctionId] = _targetAuction;

        data.winningBid[_targetAuction.auctionId] = _winningBid;

        _payout(address(this), _targetAuction.auctionCreator, _targetAuction.currency, payoutAmount, _targetAuction);

        emit AuctionClosed(
            _targetAuction.auctionId,
            _msgSender(),
            false,
            _targetAuction.auctionCreator,
            _winningBid.bidder
        );
    }

    /// @dev Transfers tokens for auction.
    function _transferAuctionTokens(
        address _from,
        address _to,
        Auction memory _auction
    ) internal {
        if (_auction.tokenType == TokenType.ERC1155) {
            IERC1155(_auction.assetContract).safeTransferFrom(_from, _to, _auction.tokenId, _auction.quantity, "");
        } else if (_auction.tokenType == TokenType.ERC721) {
            IERC721(_auction.assetContract).safeTransferFrom(_from, _to, _auction.tokenId, "");
        }
    }

    /// @dev Pays out stakeholders in auction.
    function _payout(
        address _payer,
        address _payee,
        address _currencyToUse,
        uint256 _totalPayoutAmount,
        Auction memory _targetAuction
    ) internal {
        (address platformFeeRecipient, uint16 platformFeeBps) = IPlatformFee(address(this)).getPlatformFeeInfo();
        uint256 platformFeeCut = (_totalPayoutAmount * platformFeeBps) / MAX_BPS;

        uint256 royaltyCut;
        address royaltyRecipient;

        // Distribute royalties. See Sushiswap's https://github.com/sushiswap/shoyu/blob/master/contracts/base/BaseExchange.sol#L296
        try IERC2981(_targetAuction.assetContract).royaltyInfo(_targetAuction.tokenId, _totalPayoutAmount) returns (
            address royaltyFeeRecipient,
            uint256 royaltyFeeAmount
        ) {
            if (royaltyFeeRecipient != address(0) && royaltyFeeAmount > 0) {
                require(royaltyFeeAmount + platformFeeCut <= _totalPayoutAmount, "fees exceed the price");
                royaltyRecipient = royaltyFeeRecipient;
                royaltyCut = royaltyFeeAmount;
            }
        } catch {}

        // Distribute price to token owner
        address _nativeTokenWrapper = nativeTokenWrapper;

        CurrencyTransferLib.transferCurrencyWithWrapper(
            _currencyToUse,
            _payer,
            platformFeeRecipient,
            platformFeeCut,
            _nativeTokenWrapper
        );
        CurrencyTransferLib.transferCurrencyWithWrapper(
            _currencyToUse,
            _payer,
            royaltyRecipient,
            royaltyCut,
            _nativeTokenWrapper
        );
        CurrencyTransferLib.transferCurrencyWithWrapper(
            _currencyToUse,
            _payer,
            _payee,
            _totalPayoutAmount - (platformFeeCut + royaltyCut),
            _nativeTokenWrapper
        );
    }
}
