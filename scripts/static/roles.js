const {ethers} = require('hardhat');

module.exports = {
    FUNDER_ROLE: ethers.utils.keccak256(ethers.utils.toUtf8Bytes('FUNDER_ROLE')),
    MINTER_ROLE: ethers.utils.keccak256(ethers.utils.toUtf8Bytes('MINTER_ROLE')),
    POOL_MANAGER_ROLE: ethers.utils.keccak256(ethers.utils.toUtf8Bytes('POOL_MANAGER_ROLE')),
    HARVEST_ROLE: ethers.utils.keccak256(ethers.utils.toUtf8Bytes('HARVEST_ROLE')),
    PAUSE_ROLE: ethers.utils.keccak256(ethers.utils.toUtf8Bytes('PAUSE_ROLE')),
    RECOVERY_ROLE: ethers.utils.keccak256(ethers.utils.toUtf8Bytes('RECOVERY_ROLE')),
    GOVERNOR_ROLE: ethers.utils.keccak256(ethers.utils.toUtf8Bytes('GOVERNOR_ROLE')),
    DEFAULT_ADMIN_ROLE: '0x0000000000000000000000000000000000000000000000000000000000000000',
};
