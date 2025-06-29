(define-constant signer-key 0x03cd2cfdbd2ad9332828a7a13ef62cb999e063421c708e863a7ffed71fb61c88c9)
(define-constant amount u10000)
;; same as in signature.ts
(define-constant pox-addr {
  version: 0x00,
  hashbytes: 0x7321b74e2b6a7e949e6c4ad313035b1665095017,
})

;; @name test the delegation flow
;; @format-ignore
(define-public (test-delegation)
  (begin
    ;; @caller deployer
    (unwrap! (contract-call? .pox4-self-service-multi set-pool-pox-address-active {version: 0x00, hashbytes: 0x7321b74e2b6a7e949e6c4ad313035b1665095017}) (err u1000))
    ;; @caller wallet_1
    (unwrap! (contract-call? 'ST000000000000000000002AMW42H.pox-4 allow-contract-caller .pox4-self-service-multi none) (err u2000))
    ;; @caller wallet_1
    (unwrap! (contract-call? .pox4-self-service-multi allow-contract-caller .pox4-self-service-multi_flow_test none) (err u3000))
    ;; @caller wallet_1
    (try! (delegate-stx))
    ;; @caller wallet_1
    (try! (aggregate-commit))
    (ok true)
  )
)
(define-public (delegate-stx)
  (let ((user-data (unwrap! (to-consensus-buff? {
      v: 1,
      rewards: "sbtc",
    })
      (err u99999)
    )))
    (unwrap!
      (contract-call? .pox4-self-service-multi delegate-stx u1000000000000
        user-data
      )
      (match (contract-call? .pox4-self-service-multi delegate-stx u1000000000000
        user-data
      )
        success (ok true)
        error (err error)
      ))
    (ok true)
  )
)

(define-public (aggregate-commit)
  (begin
    (unwrap! (aggregate-commit-internal)
      (match (aggregate-commit-internal)
        success (ok true)
        error (err (to-uint error))
      ))
    (ok true)
  )
)

(define-private (aggregate-commit-internal)
  (contract-call? .pox4-self-service-multi stack-aggregation-commit u0
    (some 0xee088eb40553ca5cddcd7eb18a48f76b5047bfa3b0a3da60446d69226d345c0a49a5a709e74a7a21933fce837e5fee86caaca2dbc4f42391d7710380ad023caf00)
    signer-key u1000000000000000 u123
  )
)
