# Happy Path

## Flow

1. Launch sBTC emily notification (spox) binary.
1. Deploy pool contract.
1. Lauch Pool binary.
1. Pool binary initializes contract with pox address as sbtc deposit address of deposit contract using signer private key.
1. Pool binary sets signature for next cycle.
1. Alice delegates to Pool and locks STX.
1. Pool binary commits for next cycle to signer A (permissionless) before prepare phase.
1. Bob delegates to Pool and locks STX.
1. Pool binary commits for next cycle to signer B (permissionless) before prepare phase.
1. spox binary notifies about rewards, sbtc signer transfer to deposit contract
1. Pool binary transfers rewards to distribution contract (permissionless) during prepare phase.
1. Pool binary distributes rewards to users (permissionless) after transfer.
