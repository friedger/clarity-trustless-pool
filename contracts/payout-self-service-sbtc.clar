(define-constant ERR_FORBIDDEN (err u403))
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_TOO_EARLY (err u500))
(define-constant ERR_INSUFFICIENT_FUNDS (err u501))
(define-constant ERR_INSUFFICIENT_REWARDS (err u502))
(define-constant ERR_UNEXPECTED (err u999))

(define-constant POX_INFO (unwrap-panic (contract-call? 'ST000000000000000000002AMW42H.pox-4 get-pox-info)))
(define-data-var rewards-admin principal tx-sender)
(define-data-var reward-balance uint u0)
(define-data-var last-reward-id uint u0)

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
      (try! (transfer-memo amount tx-sender reward-admin 0x7769746864726177))
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
      (reserved-reward-balance (var-get reward-balance))
      (unspent-sbtc (unwrap! (map-get? remaining-sbtc-by-reward-id reward-id) ERR_NOT_FOUND))
      (reward-details (unwrap! (map-get? rewards reward-id) ERR_NOT_FOUND))
      (reward-cycle-id (get cycle reward-details))
      (current-cycle (/ (- burn-block-height (get first-burnchain-block-height POX_INFO))
        (get reward-cycle-length POX_INFO)
      ))
    )
    (asserts! (>= reserved-reward-balance unspent-sbtc) ERR_UNEXPECTED)
    (asserts! (> current-cycle (+ u2 reward-cycle-id)) ERR_TOO_EARLY)
    (and
      (> unspent-sbtc u0)
      (try! (withdraw-sbtc unspent-sbtc))
    )
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
