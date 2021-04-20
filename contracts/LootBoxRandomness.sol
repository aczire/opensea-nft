pragma solidity ^0.5.11;


import "multi-token-standard/contracts/utils/SafeMath.sol";


/*
  DESIGN NOTES:
  - We assume Class 0 is common!
  - Because this is a library we use a state struct rather than member
    variables. This struct is passes as the first argument to any functions that
    need it. This can make some function signatures look strange.
  - Because this is a library we cannot call owner(). We could include an owner
    field in the state struct, but this would add maintenance overhead for
    users of this library who have to make sure they change that field when
    changing the owner() of the contract that uses this library. We therefore
    append an _owner parameter to the argument list of functions that need to
    access owner(), which makes some function signatures (particularly _mint)
    look weird but is better than hiding a dependency on an easily broken
    state field.
  - We also cannot call onlyOwner or whenNotPaused. Users of this library should
    not expose any of the methods in this library, and should wrap any code that
    uses methods that set, reset, or open anything in onlyOwner().
    Code that calls _mint should also be wrapped in nonReentrant() and should
    ensure perform the equivalent checks to _canMint() in
    CreatureAccessoryFactory.
 */


contract Factory {
    function mint(uint256 _optionId, address _toAddress, uint256 _amount, bytes calldata _data) external;
    function balanceOf(address _owner, uint256 _optionId) public view returns (uint256);
}


/**
 * @title LootBoxRandomness
 * LootBoxRandomness- support for a randomized and openable lootbox.
 */
library LootBoxRandomness {
  using SafeMath for uint256;

  // Event for logging lootbox opens
  event LootBoxOpened(uint256 indexed optionId, address indexed buyer, uint256 boxesPurchased, uint256 itemsMinted);
  event Warning(string message, address account);

  uint256 constant INVERSE_BASIS_POINT = 10000;
  
  // NOTE: Price of the lootbox is set via sell orders on OpenSea
  struct OptionSettings {
    // Number of items to send per open.
    // Set to 0 to disable this Option.
    uint256 maxQuantityPerOpen;
    // Probability in basis points (out of 10,000) of receiving each class (descending)
    uint16[] classProbabilities;
    // Whether to enable `guarantees` below
    bool hasGuaranteedClasses;
    // Number of items you're guaranteed to get, for each class
    uint16[] guarantees;
  }

  struct LootBoxRandomnessState {
      address factoryAddress;
      uint256 numOptions;
      uint256 numClasses;
      mapping (uint256 => OptionSettings) optionToSettings;
      mapping (uint256 => uint256[]) classToTokenIds;
      uint256 seed;
  }

  //////
  // INITIALIZATION FUNCTIONS FOR OWNER
  //////

  /**
   * @dev Set up the fields of the state that should have initial values.
   */
  function initState(
    LootBoxRandomnessState storage _state,
    address _factoryAddress,
    uint256 _numOptions,
    uint256 _numClasses,
    uint256 _seed
  ) public {
      _state.factoryAddress = _factoryAddress;
      _state.numOptions = _numOptions;
      _state.numClasses = _numClasses;
      _state.seed = _seed;
  }
  
  /**
   * @dev If the tokens for some class are pre-minted and owned by the
   * contract owner, they can be used for a given class by setting them here
   */
  function setClassForTokenId(
    LootBoxRandomnessState storage _state,
    uint256 _tokenId,
    uint256 _classId
  ) public {
    require(_classId < _state.numClasses, "_class out of range");
    _addTokenIdToClass(_state, _classId, _tokenId);
  }

  /**
   * @dev Alternate way to add token ids to a class
   * Note: resets the full list for the class instead of adding each token id
   */
  function setTokenIdsForClass(
    LootBoxRandomnessState storage _state,
    uint256 _classId,
    uint256[] memory _tokenIds
  ) public {
    require(_classId < _state.numClasses, "_class out of range");
    _state.classToTokenIds[_classId] = _tokenIds;
  }

  /**
   * @dev Remove all token ids for a given class, causing it to fall back to
   * creating/minting into the nft address
   */
  function resetClass(
    LootBoxRandomnessState storage _state,
    uint256 _classId
  ) public {require(
    _classId < _state.numClasses, "_class out of range");
    delete _state.classToTokenIds[_classId];
  }

  /**
   * @dev Set token IDs for each rarity class. Bulk version of `setTokenIdForClass`
   * @param _tokenIds List of token IDs to set for each class, specified above in order
   */
  //Requires ABIEncoderV2
  /*function setTokenIdsForClasses(
    LootBoxRandomnessState storage _state,
    uint256[][] memory _tokenIds
  ) public {
    require(_tokenIds.length == _state.numClasses, "wrong _tokenIds length");
    for (uint256 i = 0; i < _tokenIds.length; i++) {
      setTokenIdsForClass(_state, i, _tokenIds[i]);
    }
    }*/

  /**
   * @dev Set the settings for a particular lootbox option
   * @param _option The Option to set settings for
   * @param _maxQuantityPerOpen Maximum number of items to mint per open.
   *                            Set to 0 to disable this option.
   * @param _classProbabilities Array of probabilities (basis points, so integers out of 10,000)
   *                            of receiving each class (the index in the array).
   *                            Should add up to 10k and be descending in value.
   * @param _guarantees         Array of the number of guaranteed items received for each class
   *                            (the index in the array).
   */
  function setOptionSettings(
    LootBoxRandomnessState storage _state,
    uint256 _option,
    uint256 _maxQuantityPerOpen,
    uint16[] memory _classProbabilities,
    uint16[] memory _guarantees
  ) public {
    require(_option < _state.numOptions, "_option out of range");
    // Allow us to skip guarantees and save gas at mint time
    // if there are no classes with guarantees
    bool hasGuaranteedClasses = false;
    for (uint256 i = 0; i < _guarantees.length; i++) {
      if (_guarantees[i] > 0) {
        hasGuaranteedClasses = true;
      }
    }

    OptionSettings memory settings = OptionSettings({
      maxQuantityPerOpen: _maxQuantityPerOpen,
      classProbabilities: _classProbabilities,
      hasGuaranteedClasses: hasGuaranteedClasses,
      guarantees: _guarantees
    });

    _state.optionToSettings[uint256(_option)] = settings;
  }

  /**
   * @dev Improve pseudorandom number generator by letting the owner set the seed manually,
   * making attacks more difficult
   * @param _newSeed The new seed to use for the next transaction
   */
  function setSeed(
    LootBoxRandomnessState storage _state,
    uint256 _newSeed
  ) public {
    _state.seed = _newSeed;
  }

  ///////
  // MAIN FUNCTIONS
  //////

  /**
   * @dev Main minting logic for lootboxes
   * This is called via safeTransferFrom when CreatureAccessoryLootBox extends
   * CreatureAccessoryFactory.
   * NOTE: prices and fees are determined by the sell order on OpenSea.
   * WARNING: Make sure msg.sender can mint!
   */
  function _mint(
    LootBoxRandomnessState storage _state,
    uint256 _optionId,
    address _toAddress,
    uint256 _amount,
    bytes memory /* _data */,
    address _owner
  ) internal {
    require(_optionId < _state.numOptions, "_option out of range");
    // Load settings for this box option
    OptionSettings memory settings = _state.optionToSettings[_optionId];

    require(settings.maxQuantityPerOpen > 0, "LootBoxRandomness#_mint: OPTION_NOT_ALLOWED");

    uint256 totalMinted = 0;
    // Iterate over the quantity of boxes specified
    for (uint256 i = 0; i < _amount; i++) {
      // Iterate over the box's set quantity
      uint256 quantitySent = 0;
      if (settings.hasGuaranteedClasses) {
        // Process guaranteed token ids
        for (uint256 classId = 0; classId < settings.guarantees.length; classId++) {
          uint256 quantityOfGuaranteed = settings.guarantees[classId];
          if(quantityOfGuaranteed > 0) {
            _sendTokenWithClass(_state, classId, _toAddress, quantityOfGuaranteed, _owner);
            quantitySent += quantityOfGuaranteed;
          }
        }
      }

      // Process non-guaranteed ids
      while (quantitySent < settings.maxQuantityPerOpen) {
        uint256 quantityOfRandomized = 1;
        uint256 class = _pickRandomClass(_state, settings.classProbabilities);
        _sendTokenWithClass(_state, class, _toAddress, quantityOfRandomized, _owner);
        quantitySent += quantityOfRandomized;
      }

      totalMinted += quantitySent;
    }

    // Event emissions
    emit LootBoxOpened(_optionId, _toAddress, _amount, totalMinted);
  }

  /////
  // HELPER FUNCTIONS
  /////

  // Returns the tokenId sent to _toAddress
  function _sendTokenWithClass(
    LootBoxRandomnessState storage _state,
    uint256 _classId,
    address _toAddress,
    uint256 _amount,
    address _owner
  ) internal returns (uint256) {
    require(_classId < _state.numClasses, "_class out of range");
    Factory factory = Factory(_state.factoryAddress);
    uint256 tokenId = _pickRandomAvailableTokenIdForClass(_state, _classId, _amount, _owner);
    // This may mint, create or transfer. We don't handle that here.
    // We use tokenId as an option ID here.
    factory.mint(tokenId, _toAddress, _amount, "");
    return tokenId;
  }

  function _pickRandomClass(
    LootBoxRandomnessState storage _state,
    uint16[] memory _classProbabilities
  ) internal returns (uint256) {
    uint16 value = uint16(_random(_state).mod(INVERSE_BASIS_POINT));
    // Start at top class (length - 1)
    // skip common (0), we default to it
    for (uint256 i = _classProbabilities.length - 1; i > 0; i--) {
      uint16 probability = _classProbabilities[i];
      if (value < probability) {
        return i;
      } else {
        value = value - probability;
      }
    }
    //FIXME: assumes zero is common!
    return 0;
  }

  function _pickRandomAvailableTokenIdForClass(
    LootBoxRandomnessState storage _state,
    uint256 _classId,
    uint256 _minAmount,
    address _owner
  ) internal returns (uint256) {
    require(_classId < _state.numClasses, "_class out of range");
    uint256[] memory tokenIds = _state.classToTokenIds[_classId];
    require(tokenIds.length > 0, "No token ids for _classId");
    uint256 randIndex = _random(_state).mod(tokenIds.length);
    // Make sure owner() owns or can mint enough
    Factory factory = Factory(_state.factoryAddress);
    for (uint256 i = randIndex; i < randIndex + tokenIds.length; i++) {
      uint256 tokenId = tokenIds[i % tokenIds.length];
      // We use tokenId as an option id here
      if (factory.balanceOf(_owner, tokenId) >= _minAmount) {
        return tokenId;
     }
    }
    revert("LootBoxRandomness#_pickRandomAvailableTokenIdForClass: NOT_ENOUGH_TOKENS_FOR_CLASS");
  }

  /**
   * @dev Pseudo-random number generator
   * NOTE: to improve randomness, generate it with an oracle
   */
  function _random(LootBoxRandomnessState storage _state) internal returns (uint256) {
    uint256 randomNumber = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), msg.sender, _state.seed)));
    _state.seed = randomNumber;
    return randomNumber;
  }

  function _addTokenIdToClass(LootBoxRandomnessState storage _state, uint256 _classId, uint256 _tokenId) internal {
    // This is called by code that has already checked this, sometimes in a
    // loop, so don't pay the gas cost of checking this here.
    //require(_classId < _state.numClasses, "_class out of range");
    _state.classToTokenIds[_classId].push(_tokenId);
  }
}
