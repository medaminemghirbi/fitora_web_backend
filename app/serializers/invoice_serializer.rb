class InvoiceSerializer
  def initialize(invoice)
    @invoice = invoice
  end

  def as_json(*)
    return nil if invoice.nil?

    {
      id: invoice.id,
      number: invoice.number,
      period_start: invoice.period_start,
      period_end: invoice.period_end,
      # Frozen at issue — never today's tariff.
      amount: invoice.amount,
      currency: invoice.currency,
      billing_period: invoice.billing_period,
      plan: invoice.plan,
      trial: invoice.trial,
      issued_at: invoice.issued_at,
      issued_by: invoice.issued_by&.full_name,
      notes: invoice.notes
    }
  end

  private

  attr_reader :invoice
end
