class Payment < ApplicationRecord
  belongs_to :client
  belongs_to :company
  belongs_to :contract_period, optional: true
  belongs_to :booking, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  enum :status, { paid: 0, partial: 1, refunded: 2, cancelled: 3 }
  # `card` is retained so historical rows keep deserialising, but card
  # payments are out of scope for now — SELECTABLE_METHODS is what any new
  # or edited payment may use. See Contract.sell! / Payment.collect!.
  enum :payment_method, { cash: 0, card: 1, bank_transfer: 2, other: 3 }
  SELECTABLE_METHODS = %w[cash bank_transfer other].freeze

  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validates :payment_method, inclusion: { in: SELECTABLE_METHODS },
                             if: :will_save_change_to_payment_method?
  validate :linked_to_exactly_one_payable
  validate :payable_belongs_to_this_gym, if: -> { will_save_change_to_contract_period_id? || will_save_change_to_booking_id? }

  scope :recent, -> { order(created_at: :desc) }

  # Staff taking money for a contract period or a booking ("Encaisser").
  # No part payments: with no amount given it settles the payable in full.
  # An explicit amount is still honoured (e.g. an ad-hoc payment).
  def self.collect!(client:, company:, created_by:, payment_method:, amount: nil, currency: nil, notes: nil,
                    contract_period: nil, booking: nil)
    transaction do
      # Two clicks on "Encaisser" arrive as two requests. The lock queues
      # the second behind the first, which then finds nothing left to pay.
      payable = contract_period || booking
      payable&.lock!
      raise Refused, "This is already paid." if payable&.paid?

      payment = create!(
        client: client, company: company, created_by: created_by,
        amount: amount.presence || contract_period&.final_price || booking&.amount,
        currency: currency || company.currency, payment_method: payment_method, notes: notes,
        status: :paid, paid_at: Time.current,
        contract_period: contract_period, booking: booking
      )

      # A payable is paid once its recorded payments cover its price,
      # unpaid otherwise.
      if payable
        price = contract_period ? contract_period.final_price : booking.amount
        payable.update!(payment_status: payable.payments.reload.paid.sum(:amount) >= price.to_f ? :paid : :unpaid)
      end

      payment
    end
  end

  def refund!
    raise Refused, "Only paid payments can be refunded." unless paid?

    update!(status: :refunded)
  end

  private

  def linked_to_exactly_one_payable
    links = [ contract_period_id, booking_id ].compact
    errors.add(:base, "must be linked to a contract or booking") if links.empty?
  end

  # A person can belong to several gyms, so their periods and bookings span
  # gyms too. Money recorded here may only settle what is owed to this gym.
  def payable_belongs_to_this_gym
    if contract_period && contract_period.contract.company_id != company_id
      errors.add(:contract_period, "belongs to another gym")
    end
    if booking && booking.session.company_id != company_id
      errors.add(:booking, "belongs to another gym")
    end
  end
end
