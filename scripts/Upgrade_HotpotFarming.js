const hre = require('hardhat');
const { ethers, upgrades } = hre;

const { getContracts, saveContract } = require('./utils')

async function main() {
    const network = hre.network.name;
    const contracts = await getContracts(network)[network];

    const HotpotFarming = await hre.ethers.getContractFactory("HotpotFarming");
    const farm = await upgrades.upgradeProxy(contracts.farm, HotpotFarming);

    await farm.deployed();
    await saveContract(network, 'farm', farm.address);
    console.log(`Deployed HotpotFarming to ${farm.address}`);

    console.log('Completed!');
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });