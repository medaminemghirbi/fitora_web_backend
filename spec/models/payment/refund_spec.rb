require "rails_helper"

RSpec.describe Payment, "#refund!" do
  it "refunds a paid payment" do
    payment = create(:payment, status: :paid)

    payment.refund!

    expect(payment.reload).to be_refunded
  end

  it "rejects refunding a payment that is already refunded" do
    payment = create(:payment, status: :refunded)

    expect { payment.refund! }.to raise_error(ApplicationRecord::Refused, "Only paid payments can be refunded.")
    expect(payment.reload).to be_refunded
  end

  it "rejects refunding a cancelled payment" do
    payment = create(:payment, status: :cancelled)

    expect { payment.refund! }.to raise_error(ApplicationRecord::Refused, "Only paid payments can be refunded.")
    expect(payment.reload.status).to eq("cancelled")
  end

  it "rejects refunding a partial payment" do
    payment = create(:payment, status: :partial)

    expect { payment.refund! }.to raise_error(ApplicationRecord::Refused)
    expect(payment.reload.status).to eq("partial")
  end
end
