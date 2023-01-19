import {
  AptosClient,
  AptosAccount,
  CoinClient,
  TokenClient,
  FaucetClient,
  HexString,
  TxnBuilderTypes,
  BCS,
} from "aptos";
import * as fs from "fs";
import { sha3_256 } from "@noble/hashes/sha3";
import { exec } from "child_process";

const NODE_URL = "http://127.0.0.1:8080";
const FAUCET_URL = "http://127.0.0.1:8081";
// const NODE_URL: string = "https://fullnode.devnet.aptoslabs.com/v1/"
// const FAUCET_URL = "https://faucet.devnet.aptoslabs.com"
let merchant: AptosAccount;
let bob: AptosAccount;
let cas: AptosAccount;
let moduleOwner: AptosAccount;
const client = new AptosClient(NODE_URL);
const faucetClient = new FaucetClient(NODE_URL, FAUCET_URL);
const coinClient = new CoinClient(client);
const tokenClient = new TokenClient(client);
const initialFund = 100_000_000;

type MerchantAuthority = {
  init_authority?: string;
  current_authority?: string;
};

type PaymentConfig = {
  payment_account: string;
  merchant_authority: string;
  collect_on_init: boolean;
  amount_to_collect_on_init: number;
  amount_to_collect_per_period: number; // in seconds
  time_interval: number;
  subscription_name: string;
};

function stringToHex(text: string) {
  const encoder = new TextEncoder();
  const encoded = encoder.encode(text);
  return Array.from(encoded, (i) => i.toString(16).padStart(2, "0")).join("");
}

function fetchResourceAccount(initiator: HexString, receiver: HexString) {
  const source = BCS.bcsToBytes(
    TxnBuilderTypes.AccountAddress.fromHex(initiator)
  );
  const seed = BCS.bcsToBytes(TxnBuilderTypes.AccountAddress.fromHex(receiver));

  const originBytes = new Uint8Array(source.length + seed.length + 1);

  originBytes.set(source);
  originBytes.set(seed, source.length);
  originBytes.set([255], source.length + seed.length);

  const hash = sha3_256.create();
  hash.update(originBytes);
  return HexString.fromUint8Array(hash.digest());
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

describe("set up account, mint tokens and publish module", () => {
  it("Is able to fund the accounts", async () => {
    // if (NODE_URL === "")
    const moduleOwnerKeys = {
      address:
        "0x6234710dfe797ec0d6196b1c6a46af2eddb82e94a9258e05e0447c502b9ac441",
      publicKeyHex:
        "0x8946d3c1b4fdadacdb8f5bb18e79b839c913cd9c4ac99a1e5eb9a62dd63a9e9b",
      privateKeyHex: `0xcc4761cc9c3263672e2851b70b249608201a4d3a500d60d2473dd627878fc722`,
    };

    moduleOwner = AptosAccount.fromAptosAccountObject(moduleOwnerKeys);
    merchant = new AptosAccount();
    bob = new AptosAccount();
    cas = new AptosAccount();

    await faucetClient.fundAccount(moduleOwner.address(), initialFund);
    await faucetClient.fundAccount(merchant.address(), initialFund);
    await faucetClient.fundAccount(bob.address(), initialFund);
    await faucetClient.fundAccount(cas.address(), initialFund);
    const merchantBalance = await coinClient.checkBalance(merchant);
    const bobBalance = await coinClient.checkBalance(bob);
    const casBalance = await coinClient.checkBalance(cas);
    expect(Number(merchantBalance)).toBe(initialFund);
    expect(Number(bobBalance)).toBe(initialFund);
    expect(Number(casBalance)).toBe(initialFund);
    console.log("merchant address: ", merchant.address());
    console.log("bob address: ", bob.address());
  });

  it("Publish the package", async () => {
    const packageMetadata = fs.readFileSync(
      "./build/subscription/package-metadata.bcs"
    );
    const moduleData = fs.readFileSync(
      "./build/subscription/bytecode_modules/subscription.mv"
    );
    let txnHash = await client.publishPackage(
      moduleOwner,
      new HexString(packageMetadata.toString("hex")).toUint8Array(),
      [
        new TxnBuilderTypes.Module(
          new HexString(moduleData.toString("hex")).toUint8Array()
        ),
      ]
    );
    console.log("published hash: ", txnHash);
    try {
      await client.waitForTransaction(txnHash, { checkSuccess: true });
    } catch (error) {
      console.log(error);
      throw error;
    }
    const modules = await client.getAccountModules(moduleOwner.address());
    const hasSubscriptionModule = modules.some(
      (m) => m.abi?.name === "subscription"
    );
    expect(hasSubscriptionModule).toBe(true);
  });
});

describe("End to end Transactions", () => {
  it("can initialize merchant", async () => {
    // For a custom transaction, pass the function name with deployed address
    // syntax: deployed_address::module_name::struct_name
    const payload = {
      arguments: [],
      function: `${moduleOwner.address()}::subscription::initialize_merchant_authority`,
      type: "entry_function_payload",
      type_arguments: [],
    };
    try {
      const transaction = await client.generateTransaction(
        merchant.address(),
        payload
      );
      const signature = await client.signTransaction(merchant, transaction);
      const tx = await client.submitTransaction(signature);
      await client.waitForTransaction(tx.hash, { checkSuccess: true });
      const resource = await client.getAccountResource(
        merchant.address(),
        `${moduleOwner.address()}::subscription::MerchantAuthority`
      );
      const resourceData: MerchantAuthority = resource.data;
      expect(resourceData.current_authority).toBe(
        merchant.address().toShortString()
      );
    } catch (error) {
      console.log(error);
      throw error;
    }
  });
});
