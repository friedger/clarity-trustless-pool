(define-constant err-forbidden (err u403))
(define-constant err-not-found (err u404))
(define-constant err-too-early (err u500))
(define-constant err-insufficient-funds (err u501))
(define-constant err-insufficient-rewards (err u502))
(define-constant err-unexpected (err u999))

(define-constant pox-info (unwrap-panic (contract-call? 'ST000000000000000000002AMW42H.pox-4 get-pox-info)))
(define-data-var rewards-admin principal tx-sender)
(define-data-var reward-balance uint u0)
(define-data-var last-reward-id uint u0)

(define-map rewards
  uint
  {
    cycle: uint,
    amount-sbtc: uint,
    total-stacked: uint,
  }
)

(define-map unspent-amounts-sbtc
  uint
  uint
)

(define-map distributions
  {
    cycle: uint,
    user: principal,
  }
  uint
)

(define-data-var ctx-reward {
  cycle: uint,
  reward-id: uint,
  amount-sbtc: uint,
  total-stacked: uint,
  id-header-hash: (buff 32),
} {
  cycle: u0,
  reward-id: u0,
  amount-sbtc: u0,
  total-stacked: u0,
  id-header-hash: 0x,
})
(define-data-var ctx-unspent-amount-sbtc uint u0)

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

(define-private (get-balance (who principal))
  (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    get-balance-available who
  ))
)

(define-public (distribute-rewards-many
    (users (list 200 principal))
    (reward-id uint)
  )
  (let ((unspent (unwrap! (map-get? unspent-amounts-sbtc reward-id) err-not-found)))
    (try! (set-ctx-reward reward-id))
    (match (fold distribute-reward-internal users (ok unspent))
      success (begin
        (map-set unspent-amounts-sbtc reward-id success)
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
  (let ((unspent (unwrap! (map-get? unspent-amounts-sbtc reward-id) err-not-found)))
    (try! (set-ctx-reward reward-id))
    (match (distribute-reward-internal user (ok unspent))
      success (begin
        (map-set unspent-amounts-sbtc reward-id success)
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
        (cycle (get cycle reward))
        (received-rewards (map-get? distributions {
          cycle: cycle,
          user: user,
        }))
        (id-header-hash (get id-header-hash reward))
        (user-stacked (get-user-stacked user id-header-hash))
        (share-sbtc (calculate-share (get amount-sbtc reward) user-stacked
          (get total-stacked reward)
        ))
        (current-reward-balance (var-get reward-balance))
      )
      ;; if the user already received rewards, just continue
      (asserts! (is-none received-rewards) (ok unspent))
      ;; check that there is enough sbtc to transfer
      (asserts! (>= unspent share-sbtc) err-insufficient-funds)
      (asserts! (>= current-reward-balance share-sbtc) err-insufficient-rewards)
      (if (> share-sbtc u0)
        (begin
          (try! (as-contract (transfer-memo share-sbtc tx-sender user 0x72657761726473)))
          (var-set reward-balance (- (var-get reward-balance) share-sbtc))
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
    (reward-set-index uint)
  )
  (let (
      (reserved-balance (var-get reward-balance))
      (new-reserved-balance (+ reserved-balance amount))
      (balance (as-contract (get-balance tx-sender)))
      (reward-id (+ (var-get last-reward-id) u1))
      (total-stacked (unwrap! (get-total-stacked cycle reward-set-index) err-not-found))
    )
    ;; rewards can only be added after the end of the reward phase of the cycle
    (asserts!
      (> burn-block-height
        (- (+ (get first-burnchain-block-height pox-info)
          (* (get reward-cycle-length pox-info) (+ cycle u1))
        ) (get prepare-cycle-length pox-info)))
      err-too-early
    )
    ;; amount must be less or equal than the unallocated balance
    (asserts! (<= new-reserved-balance balance) err-insufficient-funds)
    (var-set reward-balance new-reserved-balance)
    (var-set last-reward-id reward-id)
    (map-set unspent-amounts-sbtc reward-id amount)
    (asserts!
      (map-insert rewards reward-id {
        cycle: cycle,
        amount-sbtc: amount,
        total-stacked: total-stacked,
      })
      err-unexpected
    )
    (ok reward-id)
  )
)

(define-private (remove-all-rewards (reward-id uint))
  (let (
      (reserved-reward-balance (var-get reward-balance))
      (reward-details (unwrap! (map-get? rewards reward-id) err-not-found))
      (unspent-sbtc (unwrap! (map-get? unspent-amounts-sbtc reward-id) err-not-found))
    )
    (asserts! (>= reserved-reward-balance unspent-sbtc) err-unexpected)
    (var-set reward-balance (- reserved-reward-balance unspent-sbtc))
    (map-delete rewards reward-id)
    (map-delete unspent-amounts-sbtc reward-id)
    (ok true)
  )
)

;; used during reward distribution to improve performance
(define-private (set-ctx-reward (reward-id uint))
  (let (
      (reward-details (unwrap! (map-get? rewards reward-id) err-not-found))
      (last-commit (unwrap!
        (contract-call? .pox4-self-service-multi get-last-aggregation
          (get cycle reward-details)
        )
        err-not-found
      ))
      (id-header-hash (unwrap! (get-stacks-block-info? id-header-hash last-commit) err-not-found))
    )
    (var-set ctx-reward
      (merge {
        id-header-hash: id-header-hash,
        reward-id: reward-id,
      }
        reward-details
      ))
    (ok true)
  )
)

;;
;; Reward admin functions
;;

;; Security method: reward admin can withdraw sbtc from the contract unconditionally
(define-public (withdraw-sbtc (amount uint))
  (let ((reward-admin tx-sender))
    (asserts! (is-rewards-admin) err-forbidden)
    ;; send with memo "withdraw" as ascii in hex
    (as-contract (transfer-memo amount tx-sender reward-admin 0x7769746864726177))
  )
)

;; Method 1: reward admin deposits sbtc
(define-public (deposit-rewards
    (amount uint)
    (cycle uint)
    (reward-set-index uint)
  )
  (begin
    (asserts! (is-rewards-admin) err-forbidden)
    (try! (transfer-memo amount tx-sender (as-contract tx-sender) 0x6465706f736974))
    (add-rewards amount cycle reward-set-index)
  )
)

(define-public (withdraw-rewards
    (amount uint)
    (reward-id uint)
  )
  (begin
    (try! (withdraw-sbtc amount))
    (remove-all-rewards reward-id)
  )
)

;; Method 2: wrapped rewards are send to pool directly and
;; allocated by the reward admin to the cycle
(define-public (allocate-funds
    (amount uint)
    (cycle uint)
    (reward-set-index uint)
  )
  (begin
    (asserts! (is-rewards-admin) err-forbidden)
    (add-rewards amount cycle reward-set-index)
  )
)

(define-public (desallocate-funds (reward-id uint))
  (begin
    (asserts! (is-rewards-admin) err-forbidden)
    (remove-all-rewards reward-id)
  )
)

;; Change admin
(define-public (set-rewards-admin (new-admin principal))
  (begin
    (asserts! (is-rewards-admin) err-forbidden)
    (ok (var-set rewards-admin new-admin))
  )
)

;;
;;  Read-only functions
;;

(define-read-only (get-user-stacked
    (user principal)
    (id-header-hash (buff 32))
  )
  ;; (get locked (at-block id-header-hash (stx-account user))))
  ;; DEBUG MODE
  (if (is-eq user 'ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG)
    u250000000000000
    (if (is-eq user 'ST2JHG361ZXG51QTKY2NQCVBPPRRE2KZB1HR05NNC)
      u500000000000000
      u0
    )
  )
)

(define-read-only (calculate-share
    (total-reward-amount-sbtc uint)
    (user-stacked uint)
    (total-stacked uint)
  )
  (/ (* total-reward-amount-sbtc user-stacked) total-stacked)
)

(define-public (get-total-stacked (cycle-id uint) (reward-set-index uint))  
    (ok (+ u250000000000000 u500000000000000))
)


(define-public (get-total-stacked-testnet (cycle-id uint) (reward-set-index uint))  
    (ok (get total-ustx
      (unwrap!
        (contract-call? 'ST000000000000000000002AMW42H.pox-4
          get-reward-set-pox-address cycle-id reward-set-index
        )
        err-not-found
      )))
)

(define-read-only (is-rewards-admin)
  (is-eq contract-caller (var-get rewards-admin))
)

(define-read-only (get-reward-balance)
  (var-get reward-balance)
)

(define-read-only (get-unspent-balance (reward-id uint))
  (map-get? unspent-amounts-sbtc reward-id)
)

(define-read-only (get-reward-details (reward-id uint))
  (map-get? rewards reward-id)
)

(define-read-only (get-last-reward-id)
  (var-get last-reward-id)
)

(define-read-only (get-distribution
    (cycle uint)
    (user principal)
  )
  (map-get? distributions {
    cycle: cycle,
    user: user,
  })
)
