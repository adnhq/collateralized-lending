// SPDX-License-Identifier: MIT
// ERC20 stablecoin mockup based on DAI 

pragma solidity =0.8.7;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol";

contract Stablecoin is ERC20 {

    modifier auth() {
        _authenticate();
        _;
    }

    string public constant version = "1";

    bytes32 public constant PERMIT_TYPEHASH = 0xea2aa0a1be11a07ed86d755c93467f4f82362b452371d1ba94d1715123511acb; 
    // keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");
    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping (address => uint) public auths; 
    mapping (address => uint) public nonces;

    event Authorization(address authFrom, address authTo, uint authType, uint authTime);

    constructor(
        string memory name_, 
        string memory symbol_
    ) ERC20(name_, symbol_) {
        auths[msg.sender] = 1;

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name_)),
            keccak256(bytes(version)),
            block.chainid,
            address(this)
        ));
    }

    function _authenticate() private view { require(auths[msg.sender] == 1, "unauthorized"); }

    function rely(address account) external auth {
        auths[account] = 1;

        emit Authorization(msg.sender, account, 1, block.timestamp);
    }

    function deny(address account) external auth {
        auths[account] = 0;

        emit Authorization(msg.sender, account, 0, block.timestamp);
    }

    function mint(address account, uint amount) external auth {
        _mint(account, amount);
    }

    function burn(address account, uint amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    // --- Alias ---
    function push(address to, uint amount) external {
        transferFrom(msg.sender, to, amount);
    }

    function pull(address from, uint amount) external {
        transferFrom(from, msg.sender, amount);
    }

    function move(address from, address to, uint amount) external {
        transferFrom(from, to, amount);
    }

    /// @notice Approve via signature
    function permit(
        address holder, address spender, uint256 nonce, uint256 expiry, bool allowed, 
        uint8 v, bytes32 r, bytes32 s
    ) external {
        bytes32 digest =
            keccak256(abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH,
                                     holder,
                                     spender,
                                     nonce,
                                     expiry,
                                     allowed))
        ));

        require(holder != address(0), "holder invalid");
        require(holder == ecrecover(digest, v, r, s), "permit invalid");
        require(expiry == 0 || block.timestamp <= expiry, "permit expired");
        require(nonce == nonces[holder]++, "nonce invalid");

        _approve(holder, spender, allowed ? type(uint256).max : 0);
    }

}
