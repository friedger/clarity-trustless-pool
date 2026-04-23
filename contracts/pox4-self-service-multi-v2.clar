;; @contract pox-4 Self-Service Pool with multiple signers and multiple distribution options
;; @version 2
;; Changelog: add user data to delegate-stx, add aggregation functions

;; Self-service non-custodial stacking pool
;; The pool locks for 1 cycle, amount can be increased at each cycle.
;; Users trust reward admin to receive rewards according to distribution method.
;; Users trust pool admin that their STX are used for specified signer.

;; User calls delegate-stx once.
;; For subsequent cycles, user can call delegate-stx
;; or ask automation, friends, or family to extend stacking using delegate-stack-stx.

;; The self-service function "delegate-stx" does the following:
;; 1. Revokes delegation if necessary.
;; 2. Delegates STX.
;; 3. For first-time users, stacks the caller's STX tokens for 1 cycle.
;;    For stacked users, extends locking and, if needed, increases the amount.
;;    The amount is the minimum of the balance and the delegate amount
;;    minus some STX as a buffer.
;;    The STX buffer is left unlocked for users to call revoke-delegate-stx.

;; The pool operator's function "delegate-stack-stx" does
;; step 3 (for stacked users).
;; This function can be called by anyone when less than 1050 blocks are
;; left until the cycle start. This gives the stacker 1 week to unlock
;; the STX if wanted before it can be locked again for friends and family (or enemies).

;; Commit admins are trusted users who can commit the partially stacked STX
;; at the end of each cycle.
;; The commit transaction contains a signature from the selected signer node.

;;
;; Data storage
;;

;; Map of admins that can change the pox-address
(define-map reward-admins
  principal
  bool
)
(map-set reward-admins tx-sender true)
(define-data-var active bool false)
(define-data-var pool-pox-address {
  hashbytes: (buff 32),
  version: (buff 1),
} {
  version: 0x,
  hashbytes: 0x,
})
(define-data-var stx-buffer uint u1000000) ;; 1 STX

(define-constant POX_INFO (unwrap-panic (contract-call? 'ST000000000000000000002AMW42H.pox-4 get-pox-info)))
;; Half cycle lenght is 1050 for mainnet
(define-constant HALF_CYCLE_LENGTH (/ (get reward-cycle-length POX_INFO) u2))

(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_FORBIDDEN (err u403))
(define-constant ERR_TOO_EARLY (err u500))
(define-constant ERR_TOO_MANY_SIGNERS (err u501))
(define-constant ERR_DECREASE_FORBIDDEN (err u503))
(define-constant ERR_POX_ADDRESS_DEACTIVATED (err u504))
;; Error code 3 is used by pox-4 contract for already stacking errors
(define-constant ERR_ALREADY_STACKING (err u603))
;; Error code 9 is used by pox-4 contract for permission denied errors
(define-constant ERR_STACKING_PERMISSION_DENIED (err u609))
;; Allowed contract-callers handling a user's stacking activity.
(define-map allowance-contract-callers
  {
    sender: principal,
    contract-caller: principal,
  }
  { until-burn-ht: (optional uint) }
)

;; Map of reward cyle to block height of last commit
(define-map last-aggregation
  uint
  uint
)

(define-map locked
  {
    cycle: uint,
    stacker: principal,
  }
  uint
)

(define-read-only (get-last-aggregation (cycle uint))
  (map-get? last-aggregation cycle)
)

(define-map pox-addr-indices
  uint
  (list 10 uint)
)

(define-read-only (get-pox-addr-index (cycle uint))
  (map-get? pox-addr-indices cycle)
)

;;
;; Helper functions for pox-4 calls
;;

;; Revokes and delegates stx
(define-private (delegate-stx-inner
    (amount-ustx uint)
    (delegate-to principal)
    (until-burn-ht (optional uint))
  )
  (let ((result-revoke ;; Calls revoke and ignores result
      (contract-call? 'ST000000000000000000002AMW42H.pox-4 revoke-delegate-stx)
    ))
    ;; Calls delegate-stx, converts any error to uint
    (match (contract-call? 'ST000000000000000000002AMW42H.pox-4 delegate-stx amount-ustx
      delegate-to until-burn-ht none
    )
      success (ok success)
      error (err (* u1000 (to-uint error)))
    )
  )
)

;; Tries to lock delegated stx (delegate-stack-stx).
;; If user already stacked then extend and increase
(define-private (lock-delegated-stx (user principal))
  (let (
      (start-burn-ht (+ burn-block-height u1))
      (pox-address (var-get pool-pox-address))
      (buffer-amount (var-get stx-buffer))
      (user-account (stx-account user))
      (allowed-amount (min (get-delegated-amount user)
        (+ (get locked user-account) (get unlocked user-account))
      ))
      ;; Amount to lock must be leq allowed-amount and geq locked amount.
      ;; Increase the locked amount if possible, but leave a buffer for revoke tx fees if possible.
      ;; Decreasing the locked amount requires a cool down cycle.
      (amount-ustx (if (> allowed-amount buffer-amount)
        (max (get locked user-account) (- allowed-amount buffer-amount))
        allowed-amount
      ))
    )
    (asserts! (var-get active) ERR_POX_ADDRESS_DEACTIVATED)
    (match (contract-call? 'ST000000000000000000002AMW42H.pox-4 delegate-stack-stx user
      amount-ustx pox-address start-burn-ht u1
    )
      stacker-details (begin
        (map-set locked {
          cycle: (current-pox-reward-cycle),
          stacker: user,
        }
          amount-ustx
        )
        (ok stacker-details)
      )
      error (if (is-eq error 3) ;; check whether user is already stacked
        (delegate-stack-extend-increase user amount-ustx pox-address)
        (err (* u1000 (to-uint error)))
      )
    )
  )
)

(define-private (lock-delegated-stx-fold
    (user principal)
    (result (list 30
      (response {
        lock-amount: uint,
        stacker: principal,
        unlock-burn-height: uint,
      }
        uint
      )
    ))
  )
  (let ((stack-result (lock-delegated-stx user)))
    (unwrap-panic (as-max-len? (append result stack-result) u30))
  )
)

;; Calls pox-4 delegate-stack-extend and delegate-stack-increase.
;; parameter amount-ustx must be lower or equal the stx balance and the delegated amount
(define-private (delegate-stack-extend-increase
    (user principal)
    (amount-ustx uint)
    (pox-address {
      hashbytes: (buff 32),
      version: (buff 1),
    })
  )
  (let (
      (status (stx-account user))
      (locked-amount (get locked status))
    )
    (asserts! (>= amount-ustx locked-amount) ERR_DECREASE_FORBIDDEN)
    (match (maybe-extend-for-next-cycle user pox-address status)
      success-extend (let (
          (unlock-burn-height (get unlock-burn-height success-extend))
          (current-cycle (current-pox-reward-cycle))
        )
        (if (is-eq amount-ustx locked-amount)
          ;; do not increase
          (begin
            (asserts! (> unlock-burn-height (get unlock-height status))
              ERR_ALREADY_STACKING
            )
            (map-set locked {
              cycle: current-cycle,
              stacker: user,
            }
              amount-ustx
            )
            (ok {
              lock-amount: locked-amount,
              stacker: user,
              unlock-burn-height: unlock-burn-height,
            })
          )
          ;; else increase
          (let ((increase-by (- amount-ustx locked-amount)))
            (match (contract-call? 'ST000000000000000000002AMW42H.pox-4
              delegate-stack-increase user pox-address increase-by
            )
              success-increase (begin
                (map-set locked {
                  cycle: current-cycle,
                  stacker: user,
                }
                  amount-ustx
                )
                (ok {
                  lock-amount: amount-ustx,
                  stacker: user,
                  unlock-burn-height: unlock-burn-height,
                })
              )
              error-increase (err (* u1000000000 (to-uint error-increase)))
            )
          )
        )
      )
      error (err (* u1000000 (to-uint error)))
    )
  )
)

;; Tries to extend the user's locking to the next cycle
;; if not yet locked until the end of the next cycle.
(define-private (maybe-extend-for-next-cycle
    (user principal)
    (pox-address {
      hashbytes: (buff 32),
      version: (buff 1),
    })
    (status {
      locked: uint,
      unlocked: uint,
      unlock-height: uint,
    })
  )
  (let (
      (current-cycle (current-pox-reward-cycle))
      (unlock-height (get unlock-height status))
    )
    (if (not-locked-for-cycle unlock-height (+ u1 current-cycle))
      (contract-call? 'ST000000000000000000002AMW42H.pox-4 delegate-stack-extend
        user pox-address u1
      )
      ;; one cycle only
      (ok {
        stacker: user,
        unlock-burn-height: unlock-height,
      })
    )
  )
)

;;
;; Public functions
;;

;; @desc User calls this function to delegate and lock their tokens to the self-service pool.
;; Users can revoke delegation and stx tokens will unlock at the end of the locking period.
;;
;; @param amount-ustx; amount to delegate. Can be higher than current stx balance.
;; @param user-data; indicative data for pool operator.
(define-public (delegate-stx
    (amount-ustx uint)
    (user-data (buff 2048))
  )
  (let ((user tx-sender))
    ;; Must be called directly by the tx-sender or by an allowed contract-caller
    (asserts! (check-caller-allowed) ERR_STACKING_PERMISSION_DENIED)
    (print {
      a: "delegate-stx",
      payload: user-data,
    })
    ;; Do 1. and 2.
    (try! (delegate-stx-inner amount-ustx current-contract none))
    ;; Do 3.
    (as-contract? () (try! (lock-delegated-stx user)))
  )
)

;; Stacks the delegated amount for the given user for the next cycle.
;; This function can be called by automation, friends or family for user that have delegated once.
;; This function can be called only after the current cycle is half through
(define-public (delegate-stack-stx (user principal))
  (let ((current-cycle (current-pox-reward-cycle)))
    (asserts! (can-lock-now current-cycle) ERR_TOO_EARLY)
    ;; Do 3.
    (as-contract? () (try! (lock-delegated-stx user)))
  )
)

;; Stacks the delegated amount for the given users for the next cycle.
;; This function can be called by automation, friends or family for users that have delegated once.
;; This function can be called only after the current cycle is half through
(define-public (delegate-stack-stx-many (users (list 30 principal)))
  (let ((current-cycle (current-pox-reward-cycle)))
    (asserts! (can-lock-now current-cycle) ERR_TOO_EARLY)
    ;; Do 3. for users
    (as-contract? () (fold lock-delegated-stx-fold users (list)))
  )
)

;; Calls stack aggregation increase.
(define-public (stack-aggregation-increase
    (current-cycle uint)
    (index uint)
    (signer-sig (optional (buff 65)))
    (signer-key (buff 33))
    (max-amount uint)
    (auth-id uint)
  )
  (let ((reward-cycle (+ u1 current-cycle)))
    (as-contract? ()
      (try! (to-uint-err (contract-call? 'ST000000000000000000002AMW42H.pox-4
        stack-aggregation-increase (var-get pool-pox-address) reward-cycle
        index signer-sig signer-key max-amount auth-id
      )))
    )
  )
)

;; Calls stack aggregation commit.
(define-public (stack-aggregation-commit
    (current-cycle uint)
    (signer-sig (optional (buff 65)))
    (signer-key (buff 33))
    (max-amount uint)
    (auth-id uint)
  )
  (let ((reward-cycle (+ u1 current-cycle)))
    (as-contract? ()
      (try! (match (contract-call? 'ST000000000000000000002AMW42H.pox-4
        stack-aggregation-commit-indexed (var-get pool-pox-address)
        reward-cycle signer-sig signer-key max-amount auth-id
      )
        index (let ((reward-index-set (default-to (list) (map-get? pox-addr-indices reward-cycle))))
          (map-set pox-addr-indices reward-cycle
            (unwrap! (as-max-len? (append reward-index-set index) u10) (err u999))
          )
          (map-set last-aggregation reward-cycle burn-block-height)
          (ok index)
        )
        error (err (to-uint error))
      ))
    )
  )
)

(define-public (recover
    (current-cycle uint)
    (signer-sig (optional (buff 65)))
    (signer-key (buff 33))
    (max-amount uint)
    (auth-id uint)
  )
  (let ((reward-cycle (+ u1 current-cycle)))
    (secp256k1-recover?
      (contract-call? 'ST000000000000000000002AMW42H.pox-4
        get-signer-key-message-hash (var-get pool-pox-address) reward-cycle
        "agg-commit" u1 max-amount auth-id
      )
      (default-to 0x signer-sig)
    )
  )
)

;;
;; Admin functions
;;

(define-public (set-active (is-active bool))
  (begin
    (asserts! (default-to false (map-get? reward-admins contract-caller))
      ERR_UNAUTHORIZED
    )
    (ok (var-set active is-active))
  )
)

(define-public (set-pool-pox-address (pox-addr {
  hashbytes: (buff 32),
  version: (buff 1),
}))
  (begin
    (asserts! (default-to false (map-get? reward-admins contract-caller))
      ERR_UNAUTHORIZED
    )
    (ok (var-set pool-pox-address pox-addr))
  )
)

(define-public (set-pool-pox-address-active (pox-addr {
  hashbytes: (buff 32),
  version: (buff 1),
}))
  (begin
    (asserts! (default-to false (map-get? reward-admins contract-caller))
      ERR_UNAUTHORIZED
    )
    (var-set pool-pox-address pox-addr)
    (ok (var-set active true))
  )
)

(define-public (set-stx-buffer (amount-ustx uint))
  (begin
    (asserts! (default-to false (map-get? reward-admins contract-caller))
      ERR_UNAUTHORIZED
    )
    (ok (var-set stx-buffer amount-ustx))
  )
)

;; reward admin can add other reward admins, but cannot remove them or change their permissions
(define-public (set-reward-admin
    (new-admin principal)
    (enable bool)
  )
  (begin
    (asserts! (default-to false (map-get? reward-admins contract-caller))
      ERR_UNAUTHORIZED
    )
    (asserts! (not (is-eq contract-caller new-admin)) ERR_FORBIDDEN)
    (ok (map-set reward-admins new-admin enable))
  )
)

;;
;; Read-only functions
;;

;; What's the reward cycle number of the burnchain block height?
;; Will runtime-abort if height is less than the first burnchain block (this is intentional)
(define-read-only (burn-height-to-reward-cycle (height uint))
  (/ (- height (get first-burnchain-block-height POX_INFO))
    (get reward-cycle-length POX_INFO)
  )
)

;; What's the block height at the start of a given reward cycle?
(define-read-only (reward-cycle-to-burn-height (cycle uint))
  (+ (get first-burnchain-block-height POX_INFO)
    (* cycle (get reward-cycle-length POX_INFO))
  )
)

;; What's the current PoX reward cycle?
(define-read-only (current-pox-reward-cycle)
  (burn-height-to-reward-cycle burn-block-height)
)

;; Returns currently delegated amount for a given user
(define-read-only (get-delegated-amount (user principal))
  (default-to u0
    (get amount-ustx
      (contract-call? 'ST000000000000000000002AMW42H.pox-4 get-delegation-info
        user
      ))
  )
)

(define-read-only (not-locked-for-cycle
    (unlock-burn-height uint)
    (cycle uint)
  )
  (<= unlock-burn-height (reward-cycle-to-burn-height cycle))
)

(define-read-only (is-admin-enabled (admin principal))
  (map-get? reward-admins admin)
)

(define-read-only (get-pool-pox-address)
  (var-get pool-pox-address)
)

(define-read-only (can-lock-now (cycle uint))
  (> burn-block-height (+ (reward-cycle-to-burn-height cycle) HALF_CYCLE_LENGTH))
)

(define-read-only (get-total-stacked (cycle-id uint))
  (fold get-total-stacked-inner
    (default-to (list) (map-get? pox-addr-indices cycle-id)) {
    cycle-id: cycle-id,
    total-stacked: u0,
  })
)

(define-read-only (get-total-stacked-inner
    (reward-set-index uint)
    (result {
      cycle-id: uint,
      total-stacked: uint,
    })
  )
  (let (
      (cycle-id (get cycle-id result))
      (total-stacked (match (contract-call? 'ST000000000000000000002AMW42H.pox-4
        get-reward-set-pox-address (get cycle-id result) reward-set-index
      )
        info (get total-ustx info)
        u0
      ))
    )
    {
      cycle-id: cycle-id,
      total-stacked: total-stacked,
    }
  )
)

(define-read-only (get-user-stacked
    (cycle uint)
    (user principal)
  )
  (some u20000000000)
  ;; (map-get? locked {
  ;;   cycle: cycle,
  ;;   stacker: user,
  ;; })
)

;; Returns minimum
(define-private (min
    (amount-1 uint)
    (amount-2 uint)
  )
  (if (< amount-1 amount-2)
    amount-1
    amount-2
  )
)

;; Returns maximum
(define-private (max
    (amount-1 uint)
    (amount-2 uint)
  )
  (if (> amount-1 amount-2)
    amount-1
    amount-2
  )
)

(define-read-only (to-uint-err (result (response bool int)))
  (match result
    success (ok success)
    err-val (err (to-uint err-val))
  )
)

;;
;; Functions about allowance of delegation/stacking contract calls
;;

;; Give a contract-caller authorization to call stacking methods
;;  normally, stacking methods may only be invoked by _direct_ transactions
;;   (i.e., the tx-sender issues a direct contract-call to the stacking methods)
;;  by issuing an allowance, the tx-sender may call through the allowed contract
(define-public (allow-contract-caller
    (caller principal)
    (until-burn-ht (optional uint))
  )
  (begin
    (asserts! (is-eq tx-sender contract-caller) ERR_STACKING_PERMISSION_DENIED)
    (ok (map-set allowance-contract-callers {
      sender: tx-sender,
      contract-caller: caller,
    } { until-burn-ht: until-burn-ht }
    ))
  )
)

;; Revokes contract-caller authorization to call stacking methods
(define-public (disallow-contract-caller (caller principal))
  (begin
    (asserts! (is-eq tx-sender contract-caller) ERR_STACKING_PERMISSION_DENIED)
    (ok (map-delete allowance-contract-callers {
      sender: tx-sender,
      contract-caller: caller,
    }))
  )
)

;; Verifies that the contract caller has allowance to handle the tx-sender's stacking
(define-read-only (check-caller-allowed)
  (or
    (is-eq tx-sender contract-caller)
    (let (
        (caller-allowed ;; if not in the caller map, return false
          (unwrap!
            (map-get? allowance-contract-callers {
              sender: tx-sender,
              contract-caller: contract-caller,
            })
            false
          ))
        (expires-at
          ;; if until-burn-ht not set, then return true (because no expiry)
          (unwrap! (get until-burn-ht caller-allowed) true)
        )
      )
      ;; is the caller allowance still valid
      (< burn-block-height expires-at)
    )
  )
)

;; Returns the burn height at which a particular contract is allowed to stack for a particular principal.
;; The result is (some (some X)) if X is the burn height at which the allowance terminates.
;; The result is (some none) if the caller is allowed indefinitely.
;; The result is none if there is no allowance record.
(define-read-only (get-allowance-contract-callers
    (sender principal)
    (calling-contract principal)
  )
  (map-get? allowance-contract-callers {
    sender: sender,
    contract-caller: calling-contract,
  })
)
