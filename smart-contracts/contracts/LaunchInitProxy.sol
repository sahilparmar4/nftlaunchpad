// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

contract LaunchInitProxy {
    address public immutable logic;

    constructor(address _logic, bytes memory _initData) {
        logic = _logic;
        (bool _ok, bytes memory returnData) = _logic.delegatecall(
            _initData
        );
        require(_ok, string(returnData));
    }

     fallback() external payable {
        address _impl = logic;
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let result := delegatecall(gas(), _impl, ptr, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(ptr, 0, size)

            switch result
                case 0 {
                    revert(ptr, size)
                }
                default {
                    return(ptr, size)
                }
        }
    }

     receive() external payable {}
}
