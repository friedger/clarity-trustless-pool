(define-public (test-calculate-share)
  (begin
    ;; user stacks 1% and gets 1% of the reward
    (asserts!
      (is-eq u1
        (contract-call? .payout-self-service-sbtc calculate-share u100 u1000
          u100000
        ))
      (err "calculate-share failed")
    )
    (ok true)
  )
)
