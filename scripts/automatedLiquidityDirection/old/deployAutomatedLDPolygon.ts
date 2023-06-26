import { ethers, upgrades } from "hardhat";
import { AlluoStrategyHandler, AlluoVoteExecutor, AlluoVoteExecutorUtils, BeefyStrategy, BeefyStrategyUniversal, Exchange, IBeefyBoost, IBeefyVaultV6, IERC20, IERC20Metadata, IExchange, IPriceFeedRouter, IPriceFeedRouterV2, IWrappedEther, LiquidityHandler, PseudoMultisigWallet } from "../../typechain-types";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { LiquidityHandlerCurrent, SpokePoolMock } from "../../typechain";
import { reset } from "@nomicfoundation/hardhat-network-helpers";

async function main() {
    let alluoVoteExecutor: AlluoVoteExecutor;
    let alluoStrategyHandler: AlluoStrategyHandler;
    let alluoVoteExecutorUtils: AlluoVoteExecutorUtils;
    let signers: SignerWithAddress[];
    let admin: SignerWithAddress;
    let pseudoMultiSig: PseudoMultisigWallet
    let spokePool: string;
    let _recipient: string;
    let _recipientChainId: string;
    let _relayerFeePct: number;
    let _slippageTolerance: number;
    let _exchange: Exchange;
    let priceRouter: IPriceFeedRouterV2;
    let weth: IWrappedEther;
    let usdc: IERC20Metadata;
    let beefyStrategy: BeefyStrategyUniversal;
    let ldo: IERC20Metadata;
    let liquidityHandler: LiquidityHandlerCurrent;

    let beefyVault: IBeefyVaultV6;
    let beefyBoost: IBeefyBoost;
    let beefyVaultLp: IERC20Metadata;
    // await reset(process.env.POLYGON_FORKING_URL,
    //     42567675);

    //Set admin to me
    admin = await ethers.getSigner("0xABfE4d45c6381908F09EF7c501cc36E38D34c0d4");

    //For test
    // signers = await ethers.getSigners();
    // admin = signers[0];


    // Step 1: Deploy pseudoMultisig wallet
    const PseudoMultisig = await ethers.getContractFactory("PseudoMultisigWallet");
    pseudoMultiSig = await PseudoMultisig.deploy(false) as PseudoMultisigWallet
    await pseudoMultiSig.deployed();
    console.log("PseudoMultisig deployed to:", pseudoMultiSig.address);

    // Deploy new strategyHandler
    // Setup params first
    let strategyHandlerFactory = await ethers.getContractFactory("AlluoStrategyHandler");
    //
    //
    //
    _exchange = await ethers.getContractAt(
        "Exchange",
        "0xeE0674C1E7d0f64057B6eCFe845DC2519443567F"
    ) as unknown as Exchange;
    priceRouter = await ethers.getContractAt("contracts/interfaces/IPriceFeedRouterV2.sol:IPriceFeedRouterV2", "0x82220c7Be3a00ba0C6ed38572400A97445bdAEF2") as IPriceFeedRouterV2;

    weth = await ethers.getContractAt(
        "contracts/interfaces/IWrappedEther.sol:IWrappedEther",
        "0x7ceb23fd6bc0add59e62ac25578270cff1b9f619"
    ) as IWrappedEther;

    usdc = await ethers.getContractAt(
        "IERC20Metadata",
        "0x2791bca1f2de4661ed88a30c99a7a9449aa84174") as IERC20Metadata;

    spokePool = "0x9295ee1d8C5b022Be115A2AD3c30C72E34e7F096"    //Temp just for simulation
    _recipient = "0xa420b2d1c0841415A695b81E5B867BCD07Dff8C9"
    _recipientChainId = "10";
    _relayerFeePct = 757873726198165;
    _slippageTolerance = 300;
    //
    //



    //  Deploy utils and strategyHandler
    let utilsFactory = await ethers.getContractFactory("AlluoVoteExecutorUtils");
    alluoVoteExecutorUtils = (await upgrades.deployProxy(utilsFactory, [
        ethers.constants.AddressZero,
        ethers.constants.AddressZero,
        admin.address
    ], {
        initializer: "initialize"
    })) as AlluoVoteExecutorUtils;

    console.log("Utils deployed to: ", alluoVoteExecutorUtils.address);
    // Careful of who admin is
    alluoStrategyHandler = (await upgrades.deployProxy(strategyHandlerFactory, [admin.address, spokePool, _recipient, _recipientChainId, _relayerFeePct, _slippageTolerance, _exchange.address, alluoVoteExecutorUtils.address])) as AlluoStrategyHandler;
    console.log("StrategyHandler deployed to: ", alluoStrategyHandler.address);
    await alluoVoteExecutorUtils.setStorageAddresses(alluoStrategyHandler.address, ethers.constants.AddressZero);
    await alluoStrategyHandler.changeNumberOfAssets(4);
    await alluoStrategyHandler.setTokenToAssetId(weth.address, 2);
    await alluoStrategyHandler.setTokenToAssetId(usdc.address, 0);

    liquidityHandler = await ethers.getContractAt("LiquidityHandler", "0x937F7125994a91d5E2Ce31846b97578131056Bb4") as LiquidityHandlerCurrent;
    //
    //
    //
    // Now deploy AlluoVoteExecutor
    //


    let voteExecutorFactory = await ethers.getContractFactory("AlluoVoteExecutor");

    let _anyCallAddress = "0x8efd012977DD5C97E959b9e48c04eE5fcd604374"
    alluoVoteExecutor = (await upgrades.deployProxy(voteExecutorFactory, [
        pseudoMultiSig.address, _exchange.address, priceRouter.address, liquidityHandler.address, alluoStrategyHandler.address, "0xc22DB2874725B84e99EC0a644fdD042EA3F6F899", alluoVoteExecutorUtils.address, "0xdEBbFE665359B96523d364A19FceC66B0E43860D", 0, 1, true
    ])) as AlluoVoteExecutor;

    await alluoVoteExecutor.setAnyCall(_anyCallAddress);
    await alluoStrategyHandler.grantRole(await alluoStrategyHandler.DEFAULT_ADMIN_ROLE(), alluoVoteExecutor.address);


    // Deploy the beefy strategyUSD
    let beefyStrategyFactory = await ethers.getContractFactory("BeefyStrategyUniversal");
    beefyStrategy = await upgrades.deployProxy(
        beefyStrategyFactory,
        [
            admin.address,
            alluoVoteExecutor.address,
            alluoStrategyHandler.address,
            priceRouter.address,
            _exchange.address,
            weth.address
        ],
        { kind: 'uups' }
    ) as BeefyStrategyUniversal;

    // Now set liquidity direction for all beefy strategies on all chains
    // MAI-USDC Optimism
    let entryData1 = await beefyStrategy.encodeData("0x01D9cfB8a9D43013a1FdC925640412D8d2D900F0", ethers.constants.AddressZero, 0, usdc.address)
    let exitData1 = entryData1
    let rewardsData1 = entryData1
    await alluoStrategyHandler.setLiquidityDirection("BeefyMaiUsdcOptimism", 1, beefyStrategy.address, usdc.address, 0, 10, entryData1, exitData1, rewardsData1);

    // DOLA-MAI Optimism
    let entryData2 = await beefyStrategy.encodeData("0xa9913D2DA71768CD13eA75B05D9E91A3120E2f08", ethers.constants.AddressZero, 0, usdc.address)
    let exitData2 = entryData2
    let rewardsData2 = entryData2
    await alluoStrategyHandler.setLiquidityDirection("BeefyDolaMaiOptimism", 2, beefyStrategy.address, usdc.address, 0, 10, entryData2, exitData2, rewardsData2);


    // mooStargateUSDT Polygon
    let polygonUSDCAddress = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
    let entryData3 = await beefyStrategy.encodeData("0x1C480521100c962F7da106839a5A504B5A7457a1", ethers.constants.AddressZero, 0, polygonUSDCAddress)
    let exitData3 = entryData3
    let rewardsData3 = entryData3
    await alluoStrategyHandler.setLiquidityDirection("BeefyMooStargateUsdtPolygon", 3, beefyStrategy.address, polygonUSDCAddress, 0, 137, entryData3, exitData3, rewardsData3);

    // mooStargateUSDC Polygon
    let entryData4 = await beefyStrategy.encodeData("0x2F4BBA9fC4F77F16829F84181eB7C8b50F639F95", ethers.constants.AddressZero, 0, polygonUSDCAddress)
    let exitData4 = entryData4
    let rewardsData4 = entryData4
    await alluoStrategyHandler.setLiquidityDirection("BeefyMooStargateUsdcPolygon", 4, beefyStrategy.address, polygonUSDCAddress, 0, 137, entryData4, exitData4, rewardsData4);


    // Try swap eth -- usdc
    // Let signer1 get some usdc through the exchange
    // let gnosis = await ethers.getImpersonatedSigner("0x2580f9954529853Ca5aC5543cE39E9B5B1145135")
    // await _exchange.connect(gnosis).createMinorCoinEdge([
    //     { swapProtocol: 6, pool: "0x2F4BBA9fC4F77F16829F84181eB7C8b50F639F95", fromCoin: "0x2F4BBA9fC4F77F16829F84181eB7C8b50F639F95", toCoin: usdc.address },
    //     { swapProtocol: 5, pool: "0x1C480521100c962F7da106839a5A504B5A7457a1", fromCoin: "0x1C480521100c962F7da106839a5A504B5A7457a1", toCoin: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F" }
    // ]);
    // console.log("Gothere")
    // await _exchange.connect(signers[0]).exchange("0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE", usdc.address, ethers.utils.parseEther("10"), 0, { value: ethers.utils.parseEther("10") })
    // let signerBalanceUsdc = await usdc.balanceOf(signers[0].address);
    // await usdc.connect(signers[0]).transfer(beefyStrategy.address, signerBalanceUsdc)
    // let directionData = await alluoStrategyHandler.liquidityDirection(3);
    // // Deposit through the strategy
    // await beefyStrategy.connect(admin).invest(directionData.entryData, signerBalanceUsdc)
    // let beefyLp = await ethers.getContractAt("IERC20Metadata", "0x1C480521100c962F7da106839a5A504B5A7457a1")
    // console.log("Beefy strategy invested", await beefyLp.balanceOf(beefyStrategy.address))

    // // Check view function
    // console.log("Current value in usdc", await beefyStrategy.getDeployedAmount(directionData.entryData))
    // // Try exit now
    // await beefyStrategy.connect(admin).exitAll(directionData.exitData, 10000, usdc.address, signers[0].address, false, false)
    // console.log("Beefy strategy exited", await beefyLp.balanceOf(beefyStrategy.address))



    // Lets test it on test net
    // Set all the internal details  after both are deployed


    // await alluoStrategyHandler.addToActiveDirections(1);
    // await alluoStrategyHandler.changeAssetInfo(2, [31337, 69, 96], [weth.address, weth.address, weth.address], usdc.address);

    // await alluoVoteExecutor.connect(admin).setExecutorInternalIds([0, 1, 2], [alluoVoteExecutor.address, signers[9].address, signers[10].address], [0, 69, 96]);
    // await alluoVoteExecutor.connect(admin).setUniversalExecutorBalances([[0, 0, ethers.utils.parseEther("100"), 0], [0, 0, ethers.utils.parseEther("50"), 0], [0, 0, ethers.utils.parseEther("50"), 0]]);
    // await alluoVoteExecutor.connect(admin).setCrossChainInformation(signers[0].address, signers[1].address, signers[2].address, 99, 59, 10, 3, 0)

}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

//npx hardhat run scripts/deploy/deployHandler.ts --network polygon
//npx hardhat verify 0xb647c6fe9d2a6e7013c7e0924b71fa7926b2a0a3 --network polygon