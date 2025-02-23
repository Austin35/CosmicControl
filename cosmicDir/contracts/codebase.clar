;; Space Colony Resource Management System

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u1))
(define-constant ERR-INVALID-RESOURCE (err u2))
(define-constant ERR-RESOURCE-UNAVAILABLE (err u3))
(define-constant ERR-INVALID-PARAMS (err u4))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u5))
(define-constant ERR-SENSOR-NOT-FOUND (err u6))
(define-constant ERR-INVALID-CAPACITY (err u7))
(define-constant ERR-INVALID-RATE (err u8))
(define-constant ERR-INVALID-MODULE (err u9))
(define-constant ERR-INVALID-COLONIST (err u10))
(define-constant ERR-INVALID-SENSOR (err u11))

;; Resource Types
(define-constant RESOURCE-TYPE-OXYGEN u1)
(define-constant RESOURCE-TYPE-WATER u2)
(define-constant RESOURCE-TYPE-POWER u3)

;; Configuration Constants
(define-constant MAX-CAPACITY u1000000)
(define-constant MAX-RATE u1000000000)

;; Data Variables
(define-data-var commander principal tx-sender)
(define-data-var module-count uint u0)
(define-data-var min-oxygen-rate uint u1000) ;; in microSTX
(define-data-var power-rate uint u100) ;; cost per kWh in microSTX

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

(define-map water-recyclers
    uint
    {
        recycler-id: uint,
        purity-level: uint,
        last-maintenance: uint,
        needs-service: bool
    }
)

(define-map power-allocation
    {module-id: uint, user: principal}
    {
        allocated: uint,
        consumed: uint,
        last-update: uint
    }
)

(define-map environmental-sensors
    principal
    {
        sensor-id: (string-utf8 32),
        sensor-type: uint,
        module-id: uint,
        operational: bool,
        last-reading: uint,
        authorized: bool
    }
)

;; Validation Functions
(define-private (validate-module (module (string-utf8 64)))
    (> (len module) u0))

(define-private (validate-capacity (capacity uint))
    (and (> capacity u0) (<= capacity MAX-CAPACITY)))

(define-private (validate-rate (rate uint))
    (and (> rate u0) (<= rate MAX-RATE)))

(define-private (validate-colonist-id (colonist-id (string-utf8 32)))
    (> (len colonist-id) u0))

(define-private (validate-sensor-id (sensor-id (string-utf8 32)))
    (> (len sensor-id) u0))

;; Authorization
(define-private (is-commander)
    (is-eq tx-sender (var-get commander)))

(define-private (is-authorized-sensor)
    (match (map-get? environmental-sensors tx-sender)
        sensor (get authorized sensor)
        false))

;; Resource Management Functions
(define-public (register-module 
    (resource-type uint)
    (module (string-utf8 64))
    (capacity uint)
    (rate uint))
    (begin
        (asserts! (is-commander) ERR-NOT-AUTHORIZED)
        (asserts! (validate-module module) ERR-INVALID-MODULE)
        (asserts! (validate-capacity capacity) ERR-INVALID-CAPACITY)
        (asserts! (validate-rate rate) ERR-INVALID-RATE)
        (asserts! (or 
            (is-eq resource-type RESOURCE-TYPE-OXYGEN)
            (is-eq resource-type RESOURCE-TYPE-WATER)
            (is-eq resource-type RESOURCE-TYPE-POWER))
            ERR-INVALID-RESOURCE)
        
        (let ((module-id (var-get module-count)))
            (map-set modules module-id
                {
                    resource-type: resource-type,
                    module: module,
                    capacity: capacity,
                    available: capacity,
                    operational: true,
                    rate: rate
                })
            (var-set module-count (+ module-id u1))
            (ok module-id))))

;; Oxygen Management
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
        
        ;; Process payment
        (try! (stx-transfer? oxygen-fee tx-sender (var-get commander)))
        
        ;; Update oxygen chamber
        (map-set oxygen-chambers module-id
            {
                chamber-id: module-id,
                in-use: true,
                colonist-id: (some colonist-id),
                cycle-end: (+ block-height duration)
            })
        
        ;; Update module availability
        (map-set modules module-id
            (merge module {available: (- (get available module) u1)}))
        
        (ok true)))

;; Water Management
(define-public (update-water-quality
    (module-id uint)
    (purity-level uint))
    (begin
        (asserts! (is-authorized-sensor) ERR-NOT-AUTHORIZED)
        (asserts! (<= purity-level u100) ERR-INVALID-PARAMS)
        (asserts! (is-some (map-get? modules module-id)) ERR-INVALID-RESOURCE)
        
        (match (map-get? water-recyclers module-id)
            recycler (begin
                (map-set water-recyclers module-id
                    (merge recycler {
                        purity-level: purity-level,
                        needs-service: (< purity-level u80),
                        last-maintenance: block-height
                    }))
                (ok true))
            ERR-INVALID-RESOURCE)))

;; Power Management
(define-public (allocate-power
    (module-id uint)
    (amount uint))
    (let (
        (module (unwrap! (map-get? modules module-id) ERR-INVALID-RESOURCE))
        (power-cost (* amount (var-get power-rate)))
        )
        (asserts! (validate-capacity amount) ERR-INVALID-CAPACITY)
        (asserts! (>= (get available module) amount) ERR-RESOURCE-UNAVAILABLE)
        
        ;; Process payment
        (try! (stx-transfer? power-cost tx-sender (var-get commander)))
        
        ;; Update power allocation
        (map-set power-allocation
            {module-id: module-id, user: tx-sender}
            {
                allocated: amount,
                consumed: u0,
                last-update: block-height
            })
        
        (map-set modules module-id
            (merge module {available: (- (get available module) amount)}))
        
        (ok true)))

;; Environmental Sensor Management
(define-public (register-sensor
    (sensor-id (string-utf8 32))
    (sensor-type uint)
    (module-id uint))
    (begin
        (asserts! (is-commander) ERR-NOT-AUTHORIZED)
        (asserts! (validate-sensor-id sensor-id) ERR-INVALID-SENSOR)
        (asserts! (is-some (map-get? modules module-id)) ERR-INVALID-RESOURCE)
        (asserts! (or 
            (is-eq sensor-type RESOURCE-TYPE-OXYGEN)
            (is-eq sensor-type RESOURCE-TYPE-WATER)
            (is-eq sensor-type RESOURCE-TYPE-POWER))
            ERR-INVALID-RESOURCE)
        
        (map-set environmental-sensors tx-sender
            {
                sensor-id: sensor-id,
                sensor-type: sensor-type,
                module-id: module-id,
                operational: true,
                last-reading: block-height,
                authorized: true
            })
        (ok true)))

(define-public (deactivate-sensor (sensor-principal principal))
    (begin
        (asserts! (is-commander) ERR-NOT-AUTHORIZED)
        (asserts! (is-some (map-get? environmental-sensors sensor-principal)) ERR-SENSOR-NOT-FOUND)
        
        (match (map-get? environmental-sensors sensor-principal)
            sensor (begin
                (map-set environmental-sensors sensor-principal
                    (merge sensor {operational: false, authorized: false}))
                (ok true))
            ERR-SENSOR-NOT-FOUND)))

(define-public (update-sensor-reading)
    (match (map-get? environmental-sensors tx-sender)
        sensor (begin
            (map-set environmental-sensors tx-sender
                (merge sensor {last-reading: block-height}))
            (ok true))
        ERR-SENSOR-NOT-FOUND))

;; Read-only functions
(define-read-only (get-module-details (module-id uint))
    (map-get? modules module-id))

(define-read-only (get-oxygen-status (module-id uint))
    (map-get? oxygen-chambers module-id))

(define-read-only (get-water-recycler-status (module-id uint))
    (map-get? water-recyclers module-id))

(define-read-only (get-power-usage (module-id uint) (user principal))
    (map-get? power-allocation {module-id: module-id, user: user}))

(define-read-only (get-sensor-status (sensor-principal principal))
    (map-get? environmental-sensors sensor-principal))