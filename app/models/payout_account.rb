# Fitora's own bank details — where a gym sends its subscription payment.
#
# This lives in the environment and nowhere else. It is not a setting, not a
# row, and deliberately not a column: a RIB in the database is a RIB in every
# SQL dump, every staging restore and every backup, for a value that only one
# account ever has and that changes about never. Encrypting a column would
# only move the problem to the key. The environment is the right shape for it.
#
# Read it through PayoutAccount.current, never ENV directly, so the "not
# configured yet" case has exactly one answer.
class PayoutAccount
  # The reference a gym writes on its transfer so we can match it to a gym.
  REFERENCE_PREFIX = "FIT".freeze

  attr_reader :rib, :bank_name, :holder, :swift

  def initialize(rib:, bank_name:, holder:, swift:)
    @rib = rib
    @bank_name = bank_name
    @holder = holder
    @swift = swift
  end

  # nil when no RIB is configured — the caller then shows the generic
  # "settle with Fitora" wording rather than an empty bank card.
  def self.current
    rib = ENV["FITORA_RIB"].to_s.strip
    return nil if rib.blank?

    new(
      rib: rib,
      bank_name: ENV["FITORA_BANK_NAME"].to_s.strip.presence,
      holder: ENV["FITORA_ACCOUNT_HOLDER"].to_s.strip.presence,
      swift: ENV["FITORA_SWIFT"].to_s.strip.presence
    )
  end

  # What the gym writes in the transfer's label. Keeping the gym's name in it
  # is what lets a bank line be matched to a gym without asking.
  def self.reference_for(company)
    return nil if company.blank?

    slug = company.name.to_s.parameterize.upcase.delete("-").first(16)
    slug.presence ? "#{REFERENCE_PREFIX}-#{slug}" : REFERENCE_PREFIX
  end

  def as_json(company: nil)
    {
      rib: rib,
      bank_name: bank_name,
      holder: holder,
      swift: swift,
      reference: self.class.reference_for(company)
    }
  end
end
