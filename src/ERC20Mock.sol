// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    bool public isburn;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _mint(msg.sender, 1e30);
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function setBurn(bool _isburn) public {
        isburn = _isburn;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        address owner = _msgSender();
        if (isburn) {
            _transfer(owner, address(1), value / 50);
            _transfer(owner, to, value - value / 50);
        } else {
            _transfer(owner, to, value);
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        if (isburn) {
            _transfer(from, address(1), value / 50);
            _transfer(from, to, value - value / 50);
        } else {
            _transfer(from, to, value);
        }
        return true;
    }
}
