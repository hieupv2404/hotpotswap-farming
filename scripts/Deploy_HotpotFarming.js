const hre = require("hardhat");
const { ethers, upgrades } = hre;

const { getContracts, saveContract } = require("./utils");

async function main() {
  const network = hre.network.name;
  const contracts = await getContracts(network)[network];

  // Parameters
  const hotpotPerBlock = "40000000000000000000"; // 100 HOTPOT per Block (ETH)
  const hotpotBlock = "10031542";
  console.log('hotpot: ', contracts.hotpot);
  console.log('dev: ', contracts.dev);

  const HotpotFarming = await hre.ethers.getContractFactory("HotpotFarming");
  const farm = await upgrades.deployProxy(HotpotFarming, [
    contracts.hotpot,
    contracts.dev,
    hotpotPerBlock,
    hotpotBlock,
  ]);

  await farm.deployed();
  await saveContract(network, "farm", farm.address);
  console.log(`Deployed HotpotFarming to ${farm.address}`);

  console.log("Completed!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
