import {
  pox4SignatureMessage,
  poxAddressToTuple,
  StackingClient,
} from "@stacks/stacking";
import { cvToString, privateKeyToPublic } from "@stacks/transactions";

// account 1
const signerPrivateKey =
  "7287ba251d44a4d3fd9276c88ce34c5c52a038955511cccaf77e61068649c17801";

const signerPubKey = privateKeyToPublic(signerPrivateKey);
const poxAddress = "mr1iPkD9N3RJZZxXRk7xF9d36gffa6exNC";

const poxAddressCV = poxAddressToTuple(poxAddress);
console.log("PoX Address CV:", cvToString(poxAddressCV));

const createSignature = (rewardCycle: number): string => {
  const client = new StackingClient({
    address: "ST1SJ3DTE5DN7X54YDH5D64R3BCB6A2AG2ZQ8YPD5",
    network: "testnet",
  });
  const data = {
    topic: "agg-commit",
    authId: 123,
    maxAmount: 1000000000000000,
    poxAddress,
    period: 1,
    rewardCycle,
    signerPrivateKey,
  } as any;
  const signature = client.signPoxSignature(data);
  console.log("sig", pox4SignatureMessage({ ...data, network: "testnet" }));
  return signature;
};

const signature = createSignature(1);
console.log(`Signature:, 0x${signature}`);
console.log(`Public Key: 0x${signerPubKey}`);
