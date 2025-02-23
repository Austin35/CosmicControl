;; Space Colony Resource Management System
;; Basic version with core oxygen management functionality

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u1))
(define-constant ERR-INVALID-RESOURCE (err u2))
(define-constant ERR-RESOURCE-UNAVAILABLE (err u3))
(define-constant ERR-INVALID-CAPACITY (err u4))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u5))
(define-constant ERR-INVALID-MODULE (err u6))
(define-constant ERR-INVALID-COLONIST (err u7))

;; Resource Types
(define-constant RESOURCE-TYPE-OXYGEN u1)

;; Configuration Constants
(define-constant MAX-CAPACITY u1000000)

;; Data Variables
(define-data-var commander principal tx-sender)
(define-data-var module-count uint u0)
(define-data-var min-oxygen-rate uint u1000)

;; Maps
(define-map modules
    uint
    {
        resource-type: uint,
        module: (string-utf8 64),
        capacity: uint,
        available: uint,
        operational: bool,
        rate: uint
    }
)

(define-map oxygen-chambers
    uint
    {
        chamber-id: uint,
        in-use: bool,
        colonist-id: (optional (string-utf8 32)),
        cycle-end: uint
    }
)

;; Validation Functions
(define-private (validate-module (module (string-utf8 64)))
    (> (len module) u0))

(define-private (validate-capacity (capacity uint))
    (and (> capacity u0) (<= capacity MAX-CAPACITY)))

(define-private (validate-colonist-id (colonist-id (string-utf8 32)))
    (> (len colonist-id) u0))

;; Authorization
(define-private (is-commander)
    (is-eq tx-sender (var-get commander)))

;; Core Functions
(define-public (register-module 
    (module (string-utf8 64))
    (capacity uint)
    (rate uint))
    (begin
        (asserts! (is-commander) ERR-NOT-AUTHORIZED)
        (asserts! (validate-module module) ERR-INVALID-MODULE)
        (asserts! (validate-capacity capacity) ERR-INVALID-CAPACITY)
        
        (let ((module-id (var-get module-count)))
            (map-set modules module-id
                {
                    resource-type: RESOURCE-TYPE-OXYGEN,
                    module: module,
                    capacity: capacity,
                    available: capacity,
                    operational: true,
                    rate: rate
                })
            (var-set module-count (+ module-id u1))
            (ok module-id))))

(define-public (reserve-oxygen 
    (module-id uint)
    (colonist-id (string-utf8 32))
    (duration uint))
    (let (
        (module (unwrap! (map-get? modules module-id) ERR-INVALID-RESOURCE))
        (oxygen-fee (* (get rate module) duration))
        )
        (asserts! (validate-colonist-id colonist-id) ERR-INVALID-COLONIST)
        (asserts! (>= (get available module) u1) ERR-RESOURCE-UNAVAILABLE)
        (asserts! (>= oxygen-fee (var-get min-oxygen-rate)) ERR-INSUFFICIENT-PAYMENT)
        
        (try! (stx-transfer? oxygen-fee tx-sender (var-get commander)))
        
        (map-set oxygen-chambers module-id
            {
                chamber-id: module-id,
                in-use: true,
                colonist-id: (some colonist-id),
                cycle-end: (+ block-height duration)
            })
        
        (map-set modules module-id
            (merge module {available: (- (get available module) u1)}))
        
        (ok true)))

;; Read-only functions
(define-read-only (get-module-details (module-id uint))
    (map-get? modules module-id))

(define-read-only (get-oxygen-status (module-id uint))
    (map-get? oxygen-chambers module-id))
    