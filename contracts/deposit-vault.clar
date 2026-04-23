(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_TOO_EARLY (err u500))

(define-constant DEPLOYER tx-sender)
(define-constant POX_INFO (unwrap-panic (contract-call? 'ST000000000000000000002AMW42H.pox-4 get-pox-info)))
(define-constant REWARD_CYCLE_LENGTH (get reward-cycle-length POX_INFO))
(define-constant START_PREPARE_PHASE (- REWARD_CYCLE_LENGTH (get prepare-cycle-length POX_INFO)))
(define-constant INTERMED_MINIMUM u10000000) ;; 0.1 sBTC

(define-read-only (in-prepare-phase)
  (let (
      (block-height-rebased (- burn-block-height (get first-burnchain-block-height POX_INFO)))
      (blocks-in-cycle (mod block-height-rebased REWARD_CYCLE_LENGTH))
    )
    {
      blocks-in-cycle: blocks-in-cycle,
      in-prepare-phase: (> blocks-in-cycle START_PREPARE_PHASE),
      reward-cycle-length: REWARD_CYCLE_LENGTH,
      prepare-phase-length: (get prepare-cycle-length POX_INFO),
      start-prepare-phase: START_PREPARE_PHASE,
      burn-block-height: burn-block-height,
      first-block: (get first-burnchain-block-height POX_INFO),
    }
  )
)

(define-public (transfer)
  (let (
      (block-height-rebased (- burn-block-height (get first-burnchain-block-height POX_INFO)))
      (blocks-in-cycle (mod block-height-rebased REWARD_CYCLE_LENGTH))
      (current-reward-cycle (/ block-height-rebased REWARD_CYCLE_LENGTH))
      (balance (get-contract-balance-sbtc))
    )
    (asserts!
      (or (> blocks-in-cycle START_PREPARE_PHASE) (> balance INTERMED_MINIMUM))
      ERR_TOO_EARLY
    )
    (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
        balance
      ))
      (try! (contract-call? .payout-self-service-sbtc deposit-rewards balance
        current-reward-cycle
      ))
    )
  )
)

(define-read-only (get-contract-balance-sbtc)
  (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    get-balance-available current-contract
  ))
)

;; enrollment of dual stacking

;; enrolls this contract in the dual stacking contract or similar contracts
(define-trait enroll-trait (
  (enroll
    ((optional principal))
    (response bool uint)
  )
))

(define-public (enroll
    (enroll-contract <enroll-trait>)
    (receiver (optional principal))
  )
  (begin
    (asserts! (is-eq tx-sender DEPLOYER) ERR_UNAUTHORIZED)
    (as-contract? () (try! (contract-call? enroll-contract enroll receiver)))
  )
)