;; BidChain: Decentralized Auction Platform
;; Features:
;; - Create and manage auctions
;; - Place bids with bid validation
;; - Finalize auctions and transfer funds
;; - Immutable auction records

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-OWNER (err u100))
(define-constant ERR-AUCTION-NOT-FOUND (err u101))
(define-constant ERR-AUCTION-INACTIVE (err u102))
(define-constant ERR-BID-TOO-LOW (err u103))
(define-constant ERR-AUCTION-NOT-ENDED (err u104))
(define-constant ERR-AUCTION-ENDED (err u105))
(define-constant ERR-INVALID-BLOCK-RANGE (err u106))
(define-constant ERR-UNAUTHORIZED (err u107))
(define-constant ERR-TRANSFER-FAILED (err u108))

;; Auction parameters
(define-data-var auction-id uint u0)

;; Auction structure
(define-map auctions
  { id: uint }
  {
    seller: principal,
    item: (string-utf8 100),
    start-block: uint,
    end-block: uint,
    highest-bidder: principal,
    highest-bid: uint,
    is-active: bool
  }
)

;; Bid tracking - tracks both current and refunded bids
(define-map bids
  { auction-id: uint, bidder: principal }
  { bid-amount: uint }
)

;; Initialize contract with contract owner
(define-read-only (is-owner (user principal))
  (is-eq user CONTRACT-OWNER))

;; Auction management functions
(define-public (create-auction 
  (item (string-utf8 100)) 
  (start-block uint) 
  (end-block uint)
)
  (begin
    ;; Anyone can create auctions now
    
    ;; Validate block range
    (asserts! (> end-block start-block) ERR-INVALID-BLOCK-RANGE)
    (asserts! (>= start-block block-height) ERR-INVALID-BLOCK-RANGE)

    ;; Increment auction ID
    (var-set auction-id (+ (var-get auction-id) u1))

    ;; Store auction details
    (map-set auctions 
      { id: (var-get auction-id) }
      {
        seller: tx-sender,
        item: item,
        start-block: start-block,
        end-block: end-block,
        highest-bidder: tx-sender,
        highest-bid: u0,
        is-active: true
      }
    )
    (ok (var-get auction-id))
  )
)

;; Place a bid on an auction
(define-public (place-bid (auction-id-arg uint) (bid-amount uint))
  (let 
    (
      (auction (unwrap! (map-get? auctions { id: auction-id-arg }) ERR-AUCTION-NOT-FOUND))
      (current-bid (default-to u0 (get bid-amount (map-get? bids { auction-id: auction-id-arg, bidder: tx-sender }))))
      (previous-highest-bidder (get highest-bidder auction))
      (previous-highest-bid (get highest-bid auction))
    )
    (begin
      ;; Check if auction is active
      (asserts! (get is-active auction) ERR-AUCTION-INACTIVE)

      ;; Check if auction has started and not ended
      (asserts! (>= block-height (get start-block auction)) ERR-AUCTION-INACTIVE)
      (asserts! (< block-height (get end-block auction)) ERR-AUCTION-ENDED)

      ;; Ensure the bid is higher than the current highest bid
      (asserts! (> bid-amount previous-highest-bid) ERR-BID-TOO-LOW)

      ;; Transfer the bid amount from the bidder to the contract
      (try! (stx-transfer? bid-amount tx-sender (as-contract tx-sender)))

      ;; Refund the previous highest bidder if not the seller with initial 0 bid
      (if (and (not (is-eq previous-highest-bidder (get seller auction))) (> previous-highest-bid u0))
          (try! (as-contract (stx-transfer? previous-highest-bid (as-contract tx-sender) previous-highest-bidder)))
          true)

      ;; Update the highest bidder and bid amount
      (map-set auctions 
        { id: auction-id-arg }
        (merge auction 
          {
            highest-bidder: tx-sender,
            highest-bid: bid-amount
          }
        )
      )

      ;; Store the bid
      (map-set bids 
        { auction-id: auction-id-arg, bidder: tx-sender }
        { bid-amount: bid-amount }
      )

      (ok true))
  )
)

;; Finalize an auction
(define-public (finalize-auction (auction-id-arg uint))
  (let 
    (
      (auction (unwrap! (map-get? auctions { id: auction-id-arg }) ERR-AUCTION-NOT-FOUND))
    )
    (begin
      ;; Check if auction is active
      (asserts! (get is-active auction) ERR-AUCTION-INACTIVE)

      ;; Check if auction has ended
      (asserts! (>= block-height (get end-block auction)) ERR-AUCTION-NOT-ENDED)

      ;; Only seller or contract owner can finalize the auction
      (asserts! (or (is-eq tx-sender (get seller auction)) (is-owner tx-sender)) ERR-UNAUTHORIZED)

      ;; Mark auction as inactive
      (map-set auctions 
        { id: auction-id-arg }
        (merge auction 
          {
            is-active: false
          }
        )
      )

      ;; Transfer the highest bid to the seller
      (if (> (get highest-bid auction) u0)
          (try! (as-contract (stx-transfer? (get highest-bid auction) (as-contract tx-sender) (get seller auction))))
          true)

      (ok true))
  )
)

;; Allow bidders to claim refunds if auction is finalized with no winning bid
(define-public (claim-refund (auction-id-arg uint))
  (let
    (
      (auction (unwrap! (map-get? auctions { id: auction-id-arg }) ERR-AUCTION-NOT-FOUND))
      (bidder-info (unwrap! (map-get? bids { auction-id: auction-id-arg, bidder: tx-sender }) ERR-AUCTION-NOT-FOUND))
    )
    (begin
      ;; Ensure auction is no longer active
      (asserts! (not (get is-active auction)) ERR-AUCTION-NOT-ENDED)
      
      ;; Ensure bidder has a bid
      (asserts! (> (get bid-amount bidder-info) u0) ERR-BID-TOO-LOW)
      
      ;; Bidder wasn't the winner (already received funds)
      (asserts! (not (is-eq tx-sender (get highest-bidder auction))) ERR-UNAUTHORIZED)
      
      ;; Transfer the bid amount back to the bidder
      (try! (as-contract (stx-transfer? (get bid-amount bidder-info) (as-contract tx-sender) tx-sender)))
      
      ;; Reset the bid to prevent double-claims
      (map-set bids 
        { auction-id: auction-id-arg, bidder: tx-sender }
        { bid-amount: u0 }
      )
      
      (ok true)
    )
  )
)

;; Cancel an auction (only allowed before any bids are placed)
(define-public (cancel-auction (auction-id-arg uint))
  (let 
    (
      (auction (unwrap! (map-get? auctions { id: auction-id-arg }) ERR-AUCTION-NOT-FOUND))
    )
    (begin
      ;; Check if auction is active
      (asserts! (get is-active auction) ERR-AUCTION-INACTIVE)
      
      ;; Only the seller can cancel their auction
      (asserts! (is-eq tx-sender (get seller auction)) ERR-UNAUTHORIZED)
      
      ;; Can only cancel if no bids have been placed
      (asserts! (is-eq (get highest-bid auction) u0) ERR-UNAUTHORIZED)
      
      ;; Mark auction as inactive
      (map-set auctions 
        { id: auction-id-arg }
        (merge auction 
          {
            is-active: false
          }
        )
      )
      
      (ok true)
    )
  )
)

;; Utility functions
(define-read-only (get-auction (auction-id-arg uint))
  (map-get? auctions { id: auction-id-arg }))

(define-read-only (get-last-auction-id)
  (var-get auction-id))

(define-read-only (get-bid-info (auction-id-arg uint) (bidder principal))
  (map-get? bids { auction-id: auction-id-arg, bidder: bidder }))

;; Contract initialization
(map-set auctions 
  { id: u0 }
  {
    seller: CONTRACT-OWNER,
    item: (concat u"" u"Initial Auction"),  ;; Force UTF-8 string type
    start-block: u0,
    end-block: u100,
    highest-bidder: CONTRACT-OWNER,
    highest-bid: u0,
    is-active: false
  }
)

