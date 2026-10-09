// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical Uniswap V2 factory, ported to Solidity 0.8.25.
// Logic is byte-faithful to uniswap/v2-core@master; CREATE2 pair derivation
// keeps the canonical salt (keccak256(token0, token1)).
pragma solidity 0.8.25;

import "./interfaces/IUniswapV2Factory.sol";
import "./UniswapV2Pair.sol";

contract UniswapV2Factory is IUniswapV2Factory {
    address public override feeTo;
    address public override feeToSetter;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    // keccak256 of the pair init code THIS factory deploys. The canonical
    // upstream INIT_CODE_PAIR_HASH constant (0x96e8ac…) is invalid for any
    // recompiled port — the metadata hash varies with build environment —
    // so the hash lives here: it is always consistent with createPair().
    bytes32 public immutable override pairInitCodeHash;

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
        pairInitCodeHash = keccak256(type(UniswapV2Pair).creationCode);
    }

    function allPairsLength() external view override returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, "UniswapV2: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "UniswapV2: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "UniswapV2: PAIR_EXISTS"); // single check is sufficient
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, "UniswapV2: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, "UniswapV2: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }
}
