// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

import "../../extension/interface/ISharedMetadataBatch.sol";
import "../../openzeppelin-presets/utils/EnumerableSet.sol";

/**
 *  @title   Shared Metadata Batch
 *  @notice  Store a batch of shared metadata for NFTs
 */
library SharedMetadataBatchStorage {
    bytes32 public constant SHARED_METADATA_BATCH_STORAGE_POSITION =
        keccak256("shared.metadata.batch.consumer.storage");

    struct Data {
        EnumerableSet.Bytes32Set ids;
        mapping(bytes32 => ISharedMetadataBatch.SharedMetadataWithId) metadata;
    }

    function sharedMetadataBatchStorage() internal pure returns (Data storage sharedMetadataBatchData) {
        bytes32 position = SHARED_METADATA_BATCH_STORAGE_POSITION;
        assembly {
            sharedMetadataBatchData.slot := position
        }
    }
}

abstract contract SharedMetadataBatch is ISharedMetadataBatch {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Set shared metadata for NFTs
    function createSharedMetadata(SharedMetadataInfo calldata metadata) external returns (bytes32 id) {
        require(_canSetSharedMetadata(), "SharedMetadataBatch: cannot set shared metadata");
        id = _createSharedMetadata(metadata);
    }

    /// @notice Get all shared metadata
    function getAllSharedMetadata() external view returns (SharedMetadataWithId[] memory metadata) {
        bytes32[] memory ids = _sharedMetadataBatchStorage().ids.values();
        metadata = new SharedMetadataWithId[](ids.length);

        for (uint256 i = 0; i < ids.length; i += 1) {
            metadata[i] = _sharedMetadataBatchStorage().metadata[ids[i]];
        }
    }

    /// @dev Store shared metadata
    function _createSharedMetadata(SharedMetadataInfo calldata metadata) internal returns (bytes32 id) {
        id = keccak256(abi.encodePacked(metadata.name, metadata.description, metadata.imageURI, metadata.animationURI));
        require(_sharedMetadataBatchStorage().ids.add(id), "SharedMetadataBatch: shared metadata already exists");

        _sharedMetadataBatchStorage().metadata[id] = SharedMetadataWithId(id, metadata);

        emit SharedMetadataUpdated(id, metadata.name, metadata.description, metadata.imageURI, metadata.animationURI);
    }

    /// @dev Get contract storage
    function _sharedMetadataBatchStorage() internal pure returns (SharedMetadataBatchStorage.Data storage data) {
        data = SharedMetadataBatchStorage.sharedMetadataBatchStorage();
    }

    /// @dev Returns whether shared metadata can be set in the given execution context.
    function _canSetSharedMetadata() internal view virtual returns (bool);
}
