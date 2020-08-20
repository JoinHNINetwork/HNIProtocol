pragma solidity ^0.5.2;

import '../storage/interfaces/IHNIStore.sol';
import '../utility/DSAuth.sol';

contract HNISetting is DSAuth {
    IHNIStore public HNIStore;

    enum ProcessType {
        CT_DEPOSIT,
        CT_DESTROY,
        CT_CLAIM,
        CT_WITHDRAW
    }

    enum TokenType {
        TT_HNI,
        TT_USDX
    }

    constructor (address _HNIStore) public {
        HNIStore = IHNIStore(_HNIStore);
    }

    // set commission rate.
    function setCommissionRate(ProcessType ct, uint rate) public auth {
        HNIStore.setFeeRate(uint(ct), rate);
    }

    // set type of token.
    function setCommissionToken(TokenType ft, address _tokenID) public auth {
        HNIStore.setTypeToken(uint(ft), _tokenID);
    }

    // set token's medianizer.
    function setCommissionMedian(address _tokenID, address _median) public auth {
        HNIStore.setTokenMedian(_tokenID, _median);
    }

    // set destroy threshold of minimal usdx.
    function setDestroyThreshold(uint _amount) public auth {
        HNIStore.setMinBurnAmount(_amount);
    }

    // update mint section material.
    function updateMintSection(address[] memory _wrappedTokens, uint[] memory _weight) public auth {
        HNIStore.setSection(_wrappedTokens, _weight);
    }
}
