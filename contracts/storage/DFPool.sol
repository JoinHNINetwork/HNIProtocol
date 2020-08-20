pragma solidity ^0.5.2;

import '../token/interfaces/IERC20Token.sol';
import '../utility/DSMath.sol';
import '../utility/DSAuth.sol';
import '../utility/Utils.sol';

contract HNIPool is DSMath, DSAuth, Utils {

    address HNIcol;

    constructor (address _HNIcol) public {
        HNIcol = _HNIcol;
    }

    function transferFromSender(address _tokenID, address _from, uint _amount)
        public
        auth
        returns (bool)
    {
        uint _balance = IERC20Token(_tokenID).balanceOf(address(this));
        IERC20Token(_tokenID).transferFrom(_from, address(this), _amount);
        assert(sub(IERC20Token(_tokenID).balanceOf(address(this)), _balance) == _amount);
        return true;
    }

    function transferOut(address _tokenID, address _to, uint _amount)
        public
        validAddress(_to)
        auth
        returns (bool)
    {
        uint _balance = IERC20Token(_tokenID).balanceOf(_to);
        IERC20Token(_tokenID).transfer(_to, _amount);
        assert(sub(IERC20Token(_tokenID).balanceOf(_to), _balance) == _amount);
        return true;
    }

    function transferToCol(address _tokenID, uint _amount)
        public
        auth
        returns (bool)
    {
        require(HNIcol != address(0), "TransferToCol: collateral address empty.");
        uint _balance = IERC20Token(_tokenID).balanceOf(HNIcol);
        IERC20Token(_tokenID).transfer(HNIcol, _amount);
        assert(sub(IERC20Token(_tokenID).balanceOf(HNIcol), _balance) == _amount);
        return true;
    }

    function transferFromSenderToCol(address _tokenID, address _from, uint _amount)
        public
        auth
        returns (bool)
    {
        require(HNIcol != address(0), "TransferFromSenderToCol: collateral address empty.");
        uint _balance = IERC20Token(_tokenID).balanceOf(HNIcol);
        IERC20Token(_tokenID).transferFrom(_from, HNIcol, _amount);
        assert(sub(IERC20Token(_tokenID).balanceOf(HNIcol), _balance) == _amount);
        return true;
    }

    function approveToEngine(address _tokenIdx, address _engineAddress) public auth {
        IERC20Token(_tokenIdx).approve(_engineAddress, uint(-1));
    }
}
