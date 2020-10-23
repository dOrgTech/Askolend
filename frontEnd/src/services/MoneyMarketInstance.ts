import { BigNumber, Contract, providers } from "ethers";
import { Token } from "models";
import { ProtocolProvider } from "web3";

export class MoneyMarketInstanceService {
    contract: Contract;

    constructor(public provider: ProtocolProvider, address: string) {
        this.contract = provider.getContract("MoneyMarketInstance", address)
    }

    get address(): string {
        return this.contract.address;
    }

    getAsset = async (): Promise<string> => {
        return await this.contract.getAssetAdd();
    }

    getHighRisk = async(): Promise<string> => {
        return await this.contract.AHR();
    }

    getLowRisk = async(): Promise<string> => {
        return await this.contract.ALR();
    }

    getAssetName = async(): Promise<string> => {
        return await this.contract.assetName();
    }

    getName = async(): Promise<string> => {
        return await this.contract.name();
    }

    supplyALRPool = async(amount: BigNumber): Promise<providers.TransactionReceipt> => {
        const transactionObject = await this.contract.lendToALRpool(amount);

        return (await this.provider.getProvider()).waitForTransaction(transactionObject.hash)
    }

    supplyAHRPool = async(amount: BigNumber): Promise<providers.TransactionReceipt> => {
        const transactionObject = await this.contract.lendToAHRpool(amount);

        return (await this.provider.getProvider()).waitForTransaction(transactionObject.hash)
    }

    calculateFee = async(amount: BigNumber, fee: BigNumber): Promise<BigNumber> => {
        return await this.contract.calculateFee(amount, fee);
    }

    getAHRFee = async(): Promise<BigNumber> => {
        return await this.contract.fee_AHR();
    }

    getALRFee = async(): Promise<BigNumber> => {
        return await this.contract.fee_ALR();
    }

    getDivisor = async(): Promise<BigNumber> => {
        return await this.contract.divisor();
    }


}