class PaymentSerializer
  def initialize(payment)
    @payment = payment
  end

  def as_json(*)
    return nil if payment.nil?

    {
      id: payment.id,
      amount: payment.amount,
      currency: payment.currency,
      payment_method: payment.payment_method,
      status: payment.status,
      notes: payment.notes,
      paid_at: payment.paid_at,
      created_at: payment.created_at,
      client: {
        id: payment.client.id,
        full_name: payment.client.full_name,
        phone: payment.client.phone
      },
      company: { id: payment.company.id, name: payment.company.name },
      created_by: payment.created_by && { id: payment.created_by.id, full_name: payment.created_by.full_name },
      product_name: product_name
    }
  end

  private

  attr_reader :payment

  def product_name
    return payment.contract.contract_type.name if payment.contract
    return payment.booking.session.activity.name if payment.booking

    nil
  end
end
