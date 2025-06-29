(define-constant err-not-found (err u404))
(define-constant err-too-early (err u500))

(define-constant this-contract (as-contract tx-sender))
(define-constant pox-info (unwrap-panic (contract-call? 'ST000000000000000000002AMW42H.pox-4 get-pox-info)))
(define-constant reward-cycle-length (get reward-cycle-length pox-info))
(define-constant start-prepare-phase (- reward-cycle-length (get prepare-cycle-length pox-info)))
(define-constant intermed-minimum u10000000) ;; 0.1 sBTC

(define-read-only (in-prepare-phase)
(let ((block-height-rebased (- burn-block-height (get first-burnchain-block-height pox-info)))
    (blocks-in-cycle (mod block-height-rebased  reward-cycle-length))
    (current-reward-cycle (/ block-height-rebased reward-cycle-length))
    )
    {blocks-in-cycle: blocks-in-cycle, in-prepare-phase: (> blocks-in-cycle start-prepare-phase), 
    reward-cycle-length: reward-cycle-length, 
    prepare-phase-lenght: (get prepare-cycle-length pox-info),
    start-prepare-phase: start-prepare-phase,
    burn-block-height: burn-block-height,
    first-block: (get first-burnchain-block-height pox-info)}))

(define-public (transfer (reward-set-index uint))
(let ((block-height-rebased (- burn-block-height (get first-burnchain-block-height pox-info)))
    (blocks-in-cycle (mod block-height-rebased  reward-cycle-length))
    (current-reward-cycle (/ block-height-rebased reward-cycle-length))
    (balance (unwrap! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token 
            get-balance this-contract) err-not-found)
    ))
    (asserts! (or (> blocks-in-cycle start-prepare-phase) (> balance intermed-minimum)) err-too-early)
    (as-contract 
        (contract-call? .payout-self-service-sbtc
        deposit-rewards 
        balance
        current-reward-cycle
        reward-set-index))))
