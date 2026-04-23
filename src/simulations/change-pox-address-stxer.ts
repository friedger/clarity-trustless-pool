import {
  AnchorMode,
  PostConditionMode,
  boolCV,
  bufferCV,
  noneCV,
  principalCV,
  someCV,
  tupleCV,
  uintCV,
} from "@stacks/transactions";
import { SimulationBuilder } from "stxer";
import fs from "fs";
import { hexToBytes } from "@stacks/common";

const contract_name = "pox4-multi-pool-v1";
const deployer = "SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4";
const contract_id = `${deployer}.${contract_name}`;
const common_params = {
  publicKey: "",
  postConditionMode: PostConditionMode.Allow,
  anchorMode: AnchorMode.Any,
  fee: 100,
};

function setPoolPoxAddress(
  sender: string,
  nonce: number,
  hashbytes: string,
  version: number
) {
  return {
    contract_id,
    function_name: "set-pool-pox-address",
    function_args: [
      tupleCV({
        hashbytes: bufferCV(hexToBytes(hashbytes)),
        version: bufferCV(new Uint8Array([version])),
      }),
    ],
    nonce: nonce++,
    sender,
    ...common_params,
  };
}

function allowContractCaller(sender: string, nonce: number) {
  return {
    contract_id: "SP000000000000000000002Q6VF78.pox-4",
    function_name: "allow-contract-caller",
    function_args: [principalCV(contract_id), noneCV()],
    nonce: nonce++,
    sender,
    ...common_params,
  };
}

function delegateStx(sender: string, nonce: number, amount: number) {
  return {
    contract_id,
    function_name: "delegate-stx",
    function_args: [uintCV(amount), bufferCV(new Uint8Array(0))],
    nonce: nonce++,
    sender,
    ...common_params,
  };
}

function stackAggregationCommit(
  sender: string,
  nonce: number,
  cycle: number,
  signerSig: string,
  signerKey: string,
  amount: number,
  authId: number
) {
  return {
    contract_id,
    function_name: "stack-aggregation-commit",
    function_args: [
      uintCV(cycle),
      someCV(bufferCV(hexToBytes(signerSig))),
      bufferCV(hexToBytes(signerKey)),
      uintCV(amount),
      uintCV(authId),
    ],
    nonce: nonce++,
    sender,
    ...common_params,
  };
}

function main(block_height: number) {
  return SimulationBuilder.new()
    .useBlockHeight(block_height)
    .addContractCall(
      setPoolPoxAddress(
        "SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4",
        34,
        "83ed66860315e334010bbfb76eb3eef887efee0a",
        4
      )
    )
    .addContractCall(
      allowContractCaller("SP34EBMKMRR6SXX65GRKJ1FHEXV7AGHJ2D8ASQ5M3", 81842)
    )
    .addContractCall(
      delegateStx(
        "SP34EBMKMRR6SXX65GRKJ1FHEXV7AGHJ2D8ASQ5M3",
        81842,
        1000_000_000
      )
    )
    .addContractCall(
      // using tx 0x8c66b9db89864ecd76bcb5d1d13b3f0e73f915298aaa3235163dcf7894831213
      stackAggregationCommit(
        "SPMPMA1V6P430M8C91QS1G9XJ95S59JS1TZFZ4Q4",
        35,
        117,
        "f44fa4344bb0ce9e77a527ba2b020ff5470e96914b01bbc617c2ee34b99a928602b461a2bbd7394ad0030aaeefdb29dddd41bbf47f8d025c8dce0f2ecf41593f00",
        "023d6e4adbd5e7bedd5a1e1b85940e1e8c6c34924fd0d584e5e15d84c8572083d9",
        100_000_000_000_000,
        27_361_725
      )
    )
    .run()
    .catch(console.error);
}

const block_height = 3313873; // before prepare phase of cycle 118

main(block_height).catch(console.error);
