pragma solidity ^0.5.2;

import '../token/interfaces/IDSToken.sol';
import '../token/interfaces/IDSWrappedToken.sol';
import '../storage/interfaces/IHNIStore.sol';
import '../storage/interfaces/IHNIPool.sol';
import '../oracle/interfaces/IMedianizer.sol';
import '../utility/DSAuth.sol';
import '../utility/DSMath.sol';

contract HNIEngine is DSMath, DSAuth {
    IHNIStore public HNIStore;
    IHNIPool public HNIPool;
    IDSToken public usdxToken;
    address public HNICol;
    address public HNIFunds;

    enum ProcessType {
        CT_DEPOSIT,
        CT_DESTROY,
        CT_CLAIM,
        CT_WITHDRAW
    }

    constructor (
        address _usdxToken,
        address _HNIStore,
        address _HNIPool,
        address _HNICol,
        address _HNIFunds)
        public
    {
        usdxToken = IDSToken(_usdxToken);
        HNIStore = IHNIStore(_HNIStore);
        HNIPool = IHNIPool(_HNIPool);
        HNICol = _HNICol;
        HNIFunds = _HNIFunds;
    }

    function getPrice(address oracle) public view returns (uint) {
        bytes32 price = IMedianizer(oracle).read();
        return uint(price);
    }

    function _unifiedCommission(ProcessType ct, uint _feeTokenIdx, address depositor, uint _amount) internal {
        uint rate = HNIStore.getFeeRate(uint(ct));
        if(rate > 0) {
            address _token = HNIStore.getTypeToken(_feeTokenIdx);
            require(_token != address(0), "_UnifiedCommission: fee token not correct.");
            uint HNIPrice = getPrice(HNIStore.getTokenMedian(_token));
            uint HNIFee = div(mul(mul(_amount, rate), WAD), mul(10000, HNIPrice));
            IDSToken(_token).transferFrom(depositor, HNIFunds, HNIFee);
        }
    }

    function deposit(address _depositor, address _srcToken, uint _feeTokenIdx, uint _srcAmount) public auth returns (uint) {
        address _tokenID = HNIStore.getWrappedToken(_srcToken);
        require(HNIStore.getMintingToken(_tokenID), "Deposit: asset is not allowed.");

        uint _amount = IDSWrappedToken(_tokenID).wrap(address(HNIPool), _srcAmount);
        require(_amount > 0, "Deposit: amount is invalid.");
        HNIPool.transferFromSender(_srcToken, _depositor, IDSWrappedToken(_tokenID).reverseByMultiple(_amount));
        _unifiedCommission(ProcessType.CT_DEPOSIT, _feeTokenIdx, _depositor, _amount);

        address[] memory _tokens;
        uint[] memory _mintCW;
        (, , , _tokens, _mintCW) = HNIStore.getSectionData(HNIStore.getMintPosition());

        uint[] memory _tokenBalance = new uint[](_tokens.length);
        uint[] memory _resUSDXBalance = new uint[](_tokens.length);
        uint[] memory _depositorBalance = new uint[](_tokens.length);
        //For stack limit sake.
        uint _misc = uint(-1);

        for (uint i = 0; i < _tokens.length; i++) {
            _tokenBalance[i] = HNIStore.getTokenBalance(_tokens[i]);
            _resUSDXBalance[i] = HNIStore.getResUSDXBalance(_tokens[i]);
            _depositorBalance[i] = HNIStore.getDepositorBalance(_depositor, _tokens[i]);
            if (_tokenID == _tokens[i]){
                _tokenBalance[i] = add(_tokenBalance[i], _amount);
                _depositorBalance[i] = add(_depositorBalance[i], _amount);
            }
            _misc = min(div(_tokenBalance[i], _mintCW[i]), _misc);
        }
        if (_misc > 0) {
            return _convert(_depositor, _tokens, _mintCW, _tokenBalance, _resUSDXBalance, _depositorBalance, _misc);
        }
        /** Just retrieve minting tokens here. If minted balance has USDX, call claim.*/
        /// @dev reuse _tokenBalance[0], _tokenBalance[1] to avoid stack too deep
        _tokenBalance[1] = 0;
        for (uint i = 0; i < _tokens.length; i++) {
            _tokenBalance[0] = min(_depositorBalance[i], _resUSDXBalance[i]);

            if (_tokenBalance[0] == 0) {
                if (_tokenID == _tokens[i]) {
                    HNIStore.setDepositorBalance(_depositor, _tokens[i], _depositorBalance[i]);
                }
                continue;
            }

            HNIStore.setDepositorBalance(_depositor, _tokens[i], sub(_depositorBalance[i], _tokenBalance[0]));
            HNIStore.setResUSDXBalance(_tokens[i], sub(_resUSDXBalance[i], _tokenBalance[0]));
            _tokenBalance[1] = add(_tokenBalance[1], _tokenBalance[0]);
        }

        if (_tokenBalance[1] > 0)
            HNIPool.transferOut(address(usdxToken), _depositor, _tokenBalance[1]);

        _misc = add(_amount, HNIStore.getTokenBalance(_tokenID));
        HNIStore.setTokenBalance(_tokenID, _misc);

        return (_tokenBalance[1]);
    }

    function withdraw(address _depositor, address _srcToken, uint _feeTokenIdx, uint _srcAmount) public auth returns (uint) {
        address _tokenID = HNIStore.getWrappedToken(_srcToken);
        uint _amount = IDSWrappedToken(_tokenID).changeByMultiple(_srcAmount);
        require(_amount > 0, "Withdraw: amount is invalid.");

        uint _depositorBalance = HNIStore.getDepositorBalance(_depositor, _tokenID);
        uint _tokenBalance = HNIStore.getTokenBalance(_tokenID);
        uint _withdrawAmount = min(_amount, min(_tokenBalance, _depositorBalance));

        if (_withdrawAmount <= 0)
            return (0);

        _depositorBalance = sub(_depositorBalance, _withdrawAmount);
        HNIStore.setDepositorBalance(_depositor, _tokenID, _depositorBalance);
        HNIStore.setTokenBalance(_tokenID, sub(_tokenBalance, _withdrawAmount));
        _unifiedCommission(ProcessType.CT_WITHDRAW, _feeTokenIdx, _depositor, _withdrawAmount);
        IDSWrappedToken(_tokenID).unwrap(address(HNIPool), _withdrawAmount);
        uint _srcWithdrawAmount = IDSWrappedToken(_tokenID).reverseByMultiple(_withdrawAmount);
        HNIPool.transferOut(_srcToken, _depositor, _srcWithdrawAmount);

        return (_srcWithdrawAmount);
    }

    function claim(address _depositor, uint _feeTokenIdx) public auth returns (uint) {
        address[] memory _tokens = HNIStore.getMintedTokenList();
        uint _resUSDXBalance;
        uint _depositorBalance;
        uint _depositorMintAmount;
        uint _mintAmount;

        for (uint i = 0; i < _tokens.length; i++) {
            _resUSDXBalance = HNIStore.getResUSDXBalance(_tokens[i]);
            _depositorBalance = HNIStore.getDepositorBalance(_depositor, _tokens[i]);

            _depositorMintAmount = min(_resUSDXBalance, _depositorBalance);
            _mintAmount = add(_mintAmount, _depositorMintAmount);

            if (_depositorMintAmount > 0){
                HNIStore.setResUSDXBalance(_tokens[i], sub(_resUSDXBalance, _depositorMintAmount));
                HNIStore.setDepositorBalance(_depositor, _tokens[i], sub(_depositorBalance, _depositorMintAmount));
            }
        }

        if (_mintAmount <= 0)
            return 0;

        _unifiedCommission(ProcessType.CT_CLAIM, _feeTokenIdx, _depositor, _mintAmount);
        HNIPool.transferOut(address(usdxToken), _depositor, _mintAmount);
        return _mintAmount;
    }

    function destroy(address _depositor, uint _feeTokenIdx, uint _amount) public auth returns (bool) {
        require(_amount > 0 && (_amount % HNIStore.getMinBurnAmount() == 0), "Destroy: amount not correct.");
        require(_amount <= usdxToken.balanceOf(_depositor), "Destroy: exceed max USDX balance.");
        require(_amount <= sub(HNIStore.getTotalMinted(), HNIStore.getTotalBurned()), "Destroy: not enough to burn.");
        address[] memory _tokens;
        uint[] memory _burnCW;
        uint _sumBurnCW;
        uint _burned;
        uint _minted;
        uint _burnedAmount;
        uint _amountTemp = _amount;
        uint _tokenAmount;

        _unifiedCommission(ProcessType.CT_DESTROY, _feeTokenIdx, _depositor, _amount);

        while(_amountTemp > 0) {
            (_minted, _burned, , _tokens, _burnCW) = HNIStore.getSectionData(HNIStore.getBurnPosition());

            _sumBurnCW = 0;
            for (uint i = 0; i < _burnCW.length; i++) {
                _sumBurnCW = add(_sumBurnCW, _burnCW[i]);
            }

            if (add(_burned, _amountTemp) <= _minted){
                HNIStore.setSectionBurned(add(_burned, _amountTemp));
                _burnedAmount = _amountTemp;
                _amountTemp = 0;
            } else {
                _burnedAmount = sub(_minted, _burned);
                _amountTemp = sub(_amountTemp, _burnedAmount);
                HNIStore.setSectionBurned(_minted);
                HNIStore.burnSectionMoveon();
            }

            if (_burnedAmount == 0)
                continue;

            for (uint i = 0; i < _tokens.length; i++) {

                _tokenAmount = div(mul(_burnedAmount, _burnCW[i]), _sumBurnCW);
                IDSWrappedToken(_tokens[i]).unwrap(HNICol, _tokenAmount);
                HNIPool.transferOut(
                    IDSWrappedToken(_tokens[i]).getSrcERC20(),
                    _depositor,
                    IDSWrappedToken(_tokens[i]).reverseByMultiple(_tokenAmount));
                HNIStore.setTotalCol(sub(HNIStore.getTotalCol(), _tokenAmount));
            }
        }

        usdxToken.burn(_depositor, _amount);
        checkUSDXTotalAndColTotal();
        HNIStore.addTotalBurned(_amount);

        return true;
    }

    function oneClickMinting(address _depositor, uint _feeTokenIdx, uint _amount) public auth {
        address[] memory _tokens;
        uint[] memory _mintCW;
        uint _sumMintCW;
        uint _srcAmount;

        (, , , _tokens, _mintCW) = HNIStore.getSectionData(HNIStore.getMintPosition());
        for (uint i = 0; i < _mintCW.length; i++) {
            _sumMintCW = add(_sumMintCW, _mintCW[i]);
        }
        require(_sumMintCW != 0, "OneClickMinting: minting section is empty");
        require(_amount > 0 && _amount % _sumMintCW == 0, "OneClickMinting: amount error");

        _unifiedCommission(ProcessType.CT_DEPOSIT, _feeTokenIdx, _depositor, _amount);

        for (uint i = 0; i < _mintCW.length; i++) {

            _srcAmount = IDSWrappedToken(_tokens[i]).reverseByMultiple(div(mul(_amount, _mintCW[i]), _sumMintCW));
            HNIPool.transferFromSender(IDSWrappedToken(_tokens[i]).getSrcERC20(), _depositor, _srcAmount);
            HNIStore.setTotalCol(add(HNIStore.getTotalCol(), div(mul(_amount, _mintCW[i]), _sumMintCW)));
            IDSWrappedToken(_tokens[i]).wrap(HNICol, _srcAmount);
        }

        HNIStore.addTotalMinted(_amount);
        HNIStore.addSectionMinted(_amount);
        usdxToken.mint(_depositor, _amount);
        checkUSDXTotalAndColTotal();
    }

    function _convert(
        address _depositor,
        address[] memory _tokens,
        uint[] memory _mintCW,
        uint[] memory _tokenBalance,
        uint[] memory _resUSDXBalance,
        uint[] memory _depositorBalance,
        uint _step)
        internal
        returns(uint)
    {
        uint _mintAmount;
        uint _mintTotal;
        uint _depositorMintAmount;
        uint _depositorMintTotal;

        for (uint i = 0; i < _tokens.length; i++) {
            _mintAmount = mul(_step, _mintCW[i]);
            _depositorMintAmount = min(_depositorBalance[i], add(_resUSDXBalance[i], _mintAmount));
            HNIStore.setTokenBalance(_tokens[i], sub(_tokenBalance[i], _mintAmount));
            HNIPool.transferToCol(_tokens[i], _mintAmount);
            HNIStore.setTotalCol(add(HNIStore.getTotalCol(), _mintAmount));
            _mintTotal = add(_mintTotal, _mintAmount);

            if (_depositorMintAmount == 0){
                HNIStore.setResUSDXBalance(_tokens[i], add(_resUSDXBalance[i], _mintAmount));
                continue;
            }

            HNIStore.setDepositorBalance(_depositor, _tokens[i], sub(_depositorBalance[i], _depositorMintAmount));
            HNIStore.setResUSDXBalance(_tokens[i], sub(add(_resUSDXBalance[i], _mintAmount), _depositorMintAmount));
            _depositorMintTotal = add(_depositorMintTotal, _depositorMintAmount);
        }

        HNIStore.addTotalMinted(_mintTotal);
        HNIStore.addSectionMinted(_mintTotal);
        usdxToken.mint(address(HNIPool), _mintTotal);
        checkUSDXTotalAndColTotal();
        HNIPool.transferOut(address(usdxToken), _depositor, _depositorMintTotal);
        return _depositorMintTotal;
    }

    function checkUSDXTotalAndColTotal() public view {
        address[] memory _tokens = HNIStore.getMintedTokenList();
        address _HNICol = HNICol;
        uint _colTotal;
        for (uint i = 0; i < _tokens.length; i++) {
            _colTotal = add(_colTotal, IDSToken(_tokens[i]).balanceOf(_HNICol));
        }
        uint _usdxTotalSupply = usdxToken.totalSupply();
        require(_usdxTotalSupply <= _colTotal,
                "checkUSDXTotalAndColTotal : Amount of the usdx will be greater than collateral.");
        require(_usdxTotalSupply == HNIStore.getTotalCol(),
                "checkUSDXTotalAndColTotal : Usdx and total collateral are not equal.");
    }
}
