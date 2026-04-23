(define-constant ERR_FORBIDDEN (err u403))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_TOO_EARLY (err u500))
(define-constant ERR_INSUFFICIENT_FUNDS (err u501))
(define-constant ERR_INSUFFICIENT_REWARDS (err u502))
(define-constant ERR_NO_STACKING (err u503))
(define-constant ERR_UNEXPECTED (err u999))

(define-constant POX_INFO (unwrap-panic (contract-call? 'ST000000000000000000002AMW42H.pox-4 get-pox-info)))
(define-data-var rewards-admin principal tx-sender)
(define-data-var reward-balance uint u0)
(define-data-var last-reward-id uint u0)

;; Principals that have ever been admin, used to exclude dust recipients from
;; per-user invariants (withdraw-dust books the reclaimed amount under
;; distributions[{reward-id, admin}]).
(define-map was-admin principal bool)
(map-set was-admin tx-sender true)

(define-map rewards
  uint ;; reward id
  {
    cycle: uint,
    amount-sbtc: uint,
    total-stacked: uint,
  }
)

(define-map remaining-sbtc-by-reward-id
  uint ;; reward-id
  uint ;; unspent amount of sbtc for this reward
)

(define-map distributions
  {
    reward-id: uint,
    user: principal,
  }
  uint ;; amount of sbtc distributed to the user for this reward
)

(define-data-var ctx-reward {
  cycle: uint,
  reward-id: uint,
  amount-sbtc: uint,
  total-stacked: uint,
} {
  cycle: u0,
  reward-id: u0,
  amount-sbtc: u0,
  total-stacked: u0,
})

(define-private (transfer-memo
    (amount uint)
    (sender principal)
    (recipient principal)
    (memo (buff 32))
  )
  (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer
    amount sender recipient (some memo)
  )
)

(define-read-only (get-contract-balance-sbtc)
  (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    get-balance-available current-contract
  ))
)

(define-public (distribute-rewards-many
    (users (list 200 principal))
    (reward-id uint)
  )
  (let ((unspent (unwrap! (map-get? remaining-sbtc-by-reward-id reward-id) ERR_NOT_FOUND)))
    (try! (set-ctx-reward reward-id))
    (match (fold distribute-reward-internal users (ok unspent))
      remaining-sbtc (begin
        (map-set remaining-sbtc-by-reward-id reward-id remaining-sbtc)
        (ok true)
      )
      error (err error)
    )
  )
)

(define-public (distribute-rewards
    (user principal)
    (reward-id uint)
  )
  (let ((unspent (unwrap! (map-get? remaining-sbtc-by-reward-id reward-id) ERR_NOT_FOUND)))
    (try! (set-ctx-reward reward-id))
    (match (distribute-reward-internal user (ok unspent))
      remaining-sbtc (begin
        (map-set remaining-sbtc-by-reward-id reward-id remaining-sbtc)
        (ok true)
      )
      error (err error)
    )
  )
)

;; distribute a share of the current reward slice to the user
(define-private (distribute-reward-internal
    (user principal)
    (unspent-result (response uint uint))
  )
  (match unspent-result
    unspent
    ;; distribute up to unspent rewards
    (let (
        (reward (var-get ctx-reward))
        (reward-id (get reward-id reward))
        (cycle (get cycle reward))
        (user-stacked (default-to u0 (get-user-stacked cycle user)))
        (share-sbtc (calculate-share (get amount-sbtc reward) user-stacked
          (get total-stacked reward)
        ))
        (current-reward-balance (var-get reward-balance))
      )
      ;; if the user already received rewards, just continue
      (asserts!
        (is-none (map-get? distributions {
          reward-id: reward-id,
          user: user,
        }))
        (ok unspent)
      )
      ;; check that there is enough sbtc to transfer
      (asserts! (>= unspent share-sbtc) ERR_INSUFFICIENT_FUNDS)
      (asserts! (>= current-reward-balance share-sbtc) ERR_INSUFFICIENT_REWARDS)
      (if (> share-sbtc u0)
        (begin
          (try! (as-contract?
            ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              "sbtc-token" share-sbtc
            ))
            (try! (transfer-memo share-sbtc tx-sender user 0x72657761726473))
          ))
          (var-set reward-balance (- (var-get reward-balance) share-sbtc))
          (map-set distributions {
            reward-id: reward-id,
            user: user,
          }
            share-sbtc
          )
          (ok (- unspent share-sbtc))
        )
        (ok unspent)
      )
    )
    error-unspent
    (err error-unspent)
  )
)

(define-private (add-rewards
    (amount uint)
    (cycle uint)
  )
  (let (
      (reserved-balance (var-get reward-balance))
      (new-reserved-balance (+ reserved-balance amount))
      (balance (get-contract-balance-sbtc))
      (reward-id (+ (var-get last-reward-id) u1))
      (total-stacked (unwrap! (get-total-stacked cycle) ERR_NOT_FOUND))
    )
    ;; rewards can only be added after the end of the reward phase of the cycle
    (asserts!
      (> burn-block-height
        (-
          (+ (get first-burnchain-block-height POX_INFO)
            (* (get reward-cycle-length POX_INFO) (+ cycle u1))
          )
          (get prepare-cycle-length POX_INFO)
        ))
      ERR_TOO_EARLY
    )
    ;; amount must be less or equal than the unallocated balance
    (asserts! (<= new-reserved-balance balance) ERR_INSUFFICIENT_FUNDS)
    (asserts! (> total-stacked u0) ERR_NO_STACKING)
    (var-set reward-balance new-reserved-balance)
    (var-set last-reward-id reward-id)
    (map-set remaining-sbtc-by-reward-id reward-id amount)
    (asserts!
      (map-insert rewards reward-id {
        cycle: cycle,
        amount-sbtc: amount,
        total-stacked: total-stacked,
      })
      ERR_UNEXPECTED
    )
    (ok reward-id)
  )
)
;; used during reward distribution to improve performance
(define-private (set-ctx-reward (reward-id uint))
  (let ((reward-details (unwrap! (map-get? rewards reward-id) ERR_NOT_FOUND)))
    (var-set ctx-reward (merge { reward-id: reward-id } reward-details))
    (ok true)
  )
)

;;
;; Reward admin functions
;;

;; Security method: reward admin can withdraw sbtc from the contract unconditionally
(define-private (withdraw-sbtc (amount uint))
  (let ((reward-admin tx-sender))
    (asserts! (is-rewards-admin) ERR_FORBIDDEN)
    ;; send with memo "withdraw" as ascii in hex
    (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
        amount
      ))
      (try! (transfer-memo amount current-contract reward-admin 0x7769746864726177))
    )
  )
)

;; Method 1: reward admin deposits sbtc
(define-public (deposit-rewards
    (amount uint)
    (cycle uint)
  )
  (begin
    (try! (transfer-memo amount tx-sender current-contract 0x6465706f736974))
    (add-rewards amount cycle)
  )
)

(define-public (withdraw-dust (reward-id uint))
  (let (
      (admin tx-sender)
      (reserved-reward-balance (var-get reward-balance))
      (unspent-sbtc (unwrap! (map-get? remaining-sbtc-by-reward-id reward-id) ERR_NOT_FOUND))
      (reward-details (unwrap! (map-get? rewards reward-id) ERR_NOT_FOUND))
      (reward-cycle-id (get cycle reward-details))
      (current-cycle (/ (- burn-block-height (get first-burnchain-block-height POX_INFO))
        (get reward-cycle-length POX_INFO)
      ))
      (prior-admin-distribution (default-to u0
        (map-get? distributions {
          reward-id: reward-id,
          user: admin,
        })
      ))
    )
    (asserts! (>= reserved-reward-balance unspent-sbtc) ERR_UNEXPECTED)
    (asserts! (> current-cycle (+ u2 reward-cycle-id)) ERR_TOO_EARLY)
    (and
      (> unspent-sbtc u0)
      (try! (withdraw-sbtc unspent-sbtc))
    )
    (map-set distributions {
      reward-id: reward-id,
      user: admin,
    }
      (+ prior-admin-distribution unspent-sbtc)
    )
    (map-set remaining-sbtc-by-reward-id reward-id u0)
    (var-set reward-balance (- reserved-reward-balance unspent-sbtc))
    (ok true)
  )
)

(define-public (withdraw-excess-sbtc)
  (let (
      (reward-admin tx-sender)
      (reserved-reward-balance (var-get reward-balance))
      (contract-balance (get-contract-balance-sbtc))
      (excess (if (> contract-balance reserved-reward-balance)
        (- contract-balance reserved-reward-balance)
        u0
      ))
    )
    (asserts! (is-rewards-admin) ERR_FORBIDDEN)
    ;; send with memo "withdraw-excess" as ascii in hex
    (asserts! (> excess u0) ERR_TOO_EARLY)
    (as-contract?
      ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token"
        excess
      ))
      (try! (transfer-memo excess current-contract reward-admin
        0x77697468647261782d657863657373
      ))
    )
  )
)

;; Change admin
(define-public (set-rewards-admin (new-admin principal))
  (begin
    (asserts! (is-rewards-admin) ERR_FORBIDDEN)
    (map-set was-admin new-admin true)
    (ok (var-set rewards-admin new-admin))
  )
)

;;
;;  Read-only functions
;;

;; TODO use mainnet implementation
;; for get-user-stacked

(define-private (get-user-stacked
    (cycle uint)
    (user principal)
  )
  (contract-call? .pox4-self-service-multi-v2 get-user-stacked cycle user)
)

(define-read-only (calculate-share
    (total-reward-amount-sbtc uint)
    (user-stacked uint)
    (total-stacked uint)
  )
  (/ (* total-reward-amount-sbtc user-stacked) total-stacked)
)

;;
;; TODO use mainnet implementation
;; for get-total-stacked
;;
(define-read-only (get-total-stacked (cycle-id uint))
  (get-total-stacked-dummy cycle-id)
)

(define-public (get-total-stacked-dummy (cycle-id uint))
  (ok (+ u250000000000000 u500000000000000))
)

(define-public (get-total-stacked-testnet (cycle-id uint))
  (ok (contract-call? .pox4-self-service-multi-v2 get-total-stacked cycle-id))
)

(define-read-only (is-rewards-admin)
  (is-eq contract-caller (var-get rewards-admin))
)

(define-read-only (get-reward-balance)
  (var-get reward-balance)
)

(define-read-only (get-unspent-balance (reward-id uint))
  (map-get? remaining-sbtc-by-reward-id reward-id)
)

(define-read-only (get-reward-details (reward-id uint))
  (map-get? rewards reward-id)
)

(define-read-only (get-last-reward-id)
  (var-get last-reward-id)
)

(define-read-only (get-distribution
    (reward-id uint)
    (user principal)
  )
  (map-get? distributions {
    reward-id: reward-id,
    user: user,
  })
)

;;[#env(simnet)]
;;
;; Rendezvous invariants.
;;;;

;; Call-count map updated by Rendezvous after each public-function call.
(define-map context
  (string-ascii 100)
  { called: uint }
)
;; [#env(simnet)]
(define-public (update-context
    (function-name (string-ascii 100))
    (called uint)
  )
  (ok (map-set context function-name { called: called }))
)
;; [#env(simnet)]
(define-constant FUZZ_REWARD_IDS (list
  u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 u11 u12 u13 u14 u15 u16 u17 u18 u19 u20 u21
  u22 u23 u24 u25 u26 u27 u28 u29 u30 u31 u32 u33 u34 u35 u36 u37 u38 u39
  u40 u41 u42 u43 u44 u45 u46 u47 u48 u49 u50 u51 u52 u53 u54 u55 u56 u57
  u58 u59 u60 u61 u62 u63 u64 u65 u66 u67 u68 u69 u70 u71 u72 u73 u74 u75
  u76 u77 u78 u79 u80 u81 u82 u83 u84 u85 u86 u87 u88 u89 u90 u91 u92 u93
  u94 u95 u96 u97 u98 u99 u100
))

;; [#env(simnet)]
;; Devnet deployer + wallet_1..wallet_8 + faucet, the principals Rendezvous
;; draws from when generating principal arguments.
(define-constant FUZZ_PRINCIPALS (list
  'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM
  'ST1SJ3DTE5DN7X54YDH5D64R3BCB6A2AG2ZQ8YPD5
  'ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG
  'ST2JHG361ZXG51QTKY2NQCVBPPRRE2KZB1HR05NNC
  'ST2NEB84ASENDXKYGJPQW86YXQCEFEX2ZQPG87ND
  'ST2REHHS5J3CERCRBEPMGH7921Q6PYKAADT7JP2VB
  'ST3AM1A56AK2C1XAFJ4115ZSV26EB49BVQ10MGCS0
  'ST3PF13W7Z0RRM42A8VZRVFQ75SV1K26RXEP8YGKJ
  'ST3NBRSFKX28FQ2ZJ1MAKX58HKHSDGNV5N7R21XCP
  'STNHKEPYEPJ8ET55ZZ0M5A34J0R3N5FM2CMMMAZ6
))

;; [#env(simnet)]
(define-private (fuzz-sum-remaining
    (rid uint)
    (acc uint)
  )
  (+ acc (default-to u0 (map-get? remaining-sbtc-by-reward-id rid)))
)

;; [#env(simnet)]
(define-private (fuzz-sum-amount
    (rid uint)
    (acc uint)
  )
  (match (map-get? rewards rid)
    r (+ acc (get amount-sbtc r))
    acc
  )
)

;; [#env(simnet)]
(define-private (fuzz-sum-distrib-user
    (user principal)
    (acc {
      rid: uint,
      sum: uint,
    })
  )
  {
    rid: (get rid acc),
    sum: (+ (get sum acc)
      (default-to u0
        (map-get? distributions {
          reward-id: (get rid acc),
          user: user,
        })
      )),
  }
)

;; [#env(simnet)]
(define-private (fuzz-distrib-sum-for-rid (rid uint))
  (get sum
    (fold fuzz-sum-distrib-user FUZZ_PRINCIPALS {
      rid: rid,
      sum: u0,
    })
  )
)

;; [#env(simnet)]
(define-private (fuzz-sum-distrib-for-rid
    (rid uint)
    (acc uint)
  )
  (+ acc (fuzz-distrib-sum-for-rid rid))
)

;; [#env(simnet)]
(define-private (fuzz-sum-stake-user
    (user principal)
    (acc {
      cycle: uint,
      sum: uint,
    })
  )
  {
    cycle: (get cycle acc),
    sum: (+ (get sum acc)
      (default-to u0
        (contract-call? .pox4-self-service-multi-v2 get-user-stacked
          (get cycle acc) user
        ))
    ),
  }
)

;; [#env(simnet)]
;; Invariant 2: reward-balance equals sum(remaining-sbtc-by-reward-id).
;; Catches the withdraw-dust double-drain: repeated calls reduce reward-balance
;; while leaving remaining-sbtc-by-reward-id untouched.
(define-read-only (invariant-reward-balance-matches-remaining)
  (if (> (var-get last-reward-id) u100)
    true
    (is-eq (var-get reward-balance) (fold fuzz-sum-remaining FUZZ_REWARD_IDS u0))
  )
)

;; [#env(simnet)]
(define-private (fuzz-check-distributed-matches
    (rid uint)
    (ok-so-far bool)
  )
  (and
    ok-so-far
    (match (map-get? rewards rid)
      r (is-eq
        (- (get amount-sbtc r)
          (default-to u0 (map-get? remaining-sbtc-by-reward-id rid))
        )
        (fuzz-distrib-sum-for-rid rid)
      )
      true
    )
  )
)

;; [#env(simnet)]
;; Invariant 3: for every reward-id, (amount-sbtc - remaining) equals the sum
;; of distributions across the known principal set. withdraw-dust books the
;; reclaimed amount into distributions[{reward-id, admin}] so the identity
;; holds across admin dust reclaims as well.
(define-read-only (invariant-distributed-matches-distributions)
  (fold fuzz-check-distributed-matches FUZZ_REWARD_IDS true)
)

;; [#env(simnet)]
(define-private (fuzz-check-stake-sum-le-total
    (rid uint)
    (ok-so-far bool)
  )
  (if (not ok-so-far)
    false
    (match (map-get? rewards rid)
      r (<=
        (get sum
          (fold fuzz-sum-stake-user FUZZ_PRINCIPALS {
            cycle: (get cycle r),
            sum: u0,
          })
        )
        (get total-stacked r)
      )
      true
    )
  )
)

;; [#env(simnet)]
;; Invariant 6: for every reward-id, sum of per-user stake for its cycle is
;; <= the total-stacked snapshot captured when the reward was created.
(define-read-only (invariant-user-stake-sum-le-total)
  (fold fuzz-check-stake-sum-le-total FUZZ_REWARD_IDS true)
)

;; [#env(simnet)]
;; Invariant 19: whole-system sBTC conservation for the payout contract.
;;   sum(rewards.amount-sbtc) == sum(remaining) + sum(distributions)
;; withdraw-dust books the reclaimed amount under distributions[{rid, admin}]
;; so it stays balanced. withdraw-excess-sbtc drains the unbooked balance
;; above reward-balance and is not reflected in any reward map; gate on it.
(define-read-only (invariant-sbtc-conservation)
  (let ((excess-called (default-to u0
      (get called (map-get? context "withdraw-excess-sbtc"))
    )))
    (if (> excess-called u0)
      true
      (is-eq (fold fuzz-sum-amount FUZZ_REWARD_IDS u0)
        (+ (fold fuzz-sum-remaining FUZZ_REWARD_IDS u0)
          (fold fuzz-sum-distrib-for-rid FUZZ_REWARD_IDS u0)
        ))
    )
  )
)

;; [#env(simnet)]
;; Invariant 1: reward-balance is never above the contract's own sBTC balance.
;; A violation means accounting lost track of the real token balance.
(define-read-only (invariant-reward-balance-leq-sbtc-balance)
  (<= (var-get reward-balance) (get-contract-balance-sbtc))
)

;; [#env(simnet)]
(define-private (fuzz-check-distrib-user-leq-share
    (user principal)
    (acc {
      rid: uint,
      amount: uint,
      total-stacked: uint,
      cycle: uint,
      ok: bool,
    })
  )
  (if (or (not (get ok acc)) (default-to false (map-get? was-admin user)))
    acc
    (let (
        (dist (default-to u0
          (map-get? distributions {
            reward-id: (get rid acc),
            user: user,
          })))
        (stacked (default-to u0
          (contract-call? .pox4-self-service-multi-v2 get-user-stacked
            (get cycle acc) user
          )))
        (share (calculate-share (get amount acc) stacked (get total-stacked acc)))
      )
      (merge acc { ok: (<= dist share) })
    )
  )
)

;; [#env(simnet)]
(define-private (fuzz-check-distrib-leq-share
    (rid uint)
    (ok-so-far bool)
  )
  (and ok-so-far
    (match (map-get? rewards rid)
      r (get ok
          (fold fuzz-check-distrib-user-leq-share FUZZ_PRINCIPALS {
            rid: rid,
            amount: (get amount-sbtc r),
            total-stacked: (get total-stacked r),
            cycle: (get cycle r),
            ok: true,
          }))
      true
    )
  )
)

;; [#env(simnet)]
;; Invariant 4: each recorded distribution is within the user's pro-rata share.
;; Skips principals that have ever been admin, since withdraw-dust books the
;; reclaimed amount into distributions[{reward-id, admin}] above the share.
(define-read-only (invariant-distribution-leq-share)
  (fold fuzz-check-distrib-leq-share FUZZ_REWARD_IDS true)
)

;; [#env(simnet)]
(define-private (fuzz-check-distrib-user-leq-amount
    (user principal)
    (acc {
      rid: uint,
      amount: uint,
      ok: bool,
    })
  )
  (if (not (get ok acc))
    acc
    (let ((dist (default-to u0
        (map-get? distributions {
          reward-id: (get rid acc),
          user: user,
        }))))
      (merge acc { ok: (<= dist (get amount acc)) })
    )
  )
)

;; [#env(simnet)]
(define-private (fuzz-check-distrib-leq-amount
    (rid uint)
    (ok-so-far bool)
  )
  (and ok-so-far
    (match (map-get? rewards rid)
      r (get ok
          (fold fuzz-check-distrib-user-leq-amount FUZZ_PRINCIPALS {
            rid: rid,
            amount: (get amount-sbtc r),
            ok: true,
          }))
      true
    )
  )
)

;; [#env(simnet)]
;; Invariant 5: no (reward-id, user) distribution exceeds the reward's total
;; amount. Bounds both the distribute-rewards path and accumulated dust.
(define-read-only (invariant-distribution-leq-amount)
  (fold fuzz-check-distrib-leq-amount FUZZ_REWARD_IDS true)
)

;; [#env(simnet)]
(define-private (fuzz-check-distrib-user-delegated
    (user principal)
    (acc {
      rid: uint,
      cycle: uint,
      ok: bool,
    })
  )
  (if (or (not (get ok acc)) (default-to false (map-get? was-admin user)))
    acc
    (let (
        (dist (default-to u0
          (map-get? distributions {
            reward-id: (get rid acc),
            user: user,
          })))
        (stacked (default-to u0
          (contract-call? .pox4-self-service-multi-v2 get-user-stacked
            (get cycle acc) user
          )))
      )
      (merge acc { ok: (or (is-eq dist u0) (> stacked u0)) })
    )
  )
)

;; [#env(simnet)]
(define-private (fuzz-check-distrib-delegated
    (rid uint)
    (ok-so-far bool)
  )
  (and ok-so-far
    (match (map-get? rewards rid)
      r (get ok
          (fold fuzz-check-distrib-user-delegated FUZZ_PRINCIPALS {
            rid: rid,
            cycle: (get cycle r),
            ok: true,
          }))
      true
    )
  )
)

;; [#env(simnet)]
;; Invariant 20: any recipient of a non-zero distribution has positive stake
;; recorded on the pool for the reward's cycle, i.e. they went through the
;; delegate-stx path. Skips principals that have ever been admin since they
;; can receive dust without being a stacker.
(define-read-only (invariant-distribution-implies-stacked)
  (fold fuzz-check-distrib-delegated FUZZ_REWARD_IDS true)
)

;; [#env(simnet)]
;; Cross-contract invariant 21: reserved rewards can never exceed sBTC
;; actually held across the payout contract plus the deposit vault.
;; Catches any accounting path that books rewards before their sBTC has
;; arrived (or loses track of the balance owed by the vault to payout).
(define-read-only (invariant-reward-balance-leq-system-sbtc)
  (let (
      (payout-balance (get-contract-balance-sbtc))
      (vault-balance (unwrap!
        (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          get-balance-available .deposit-vault
        ) false
      ))
    )
    (<= (var-get reward-balance) (+ payout-balance vault-balance))
  )
)
