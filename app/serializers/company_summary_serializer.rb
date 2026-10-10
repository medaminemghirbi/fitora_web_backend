# The lightweight shape used everywhere a caller just needs to list/pick
# one of an admin's companies (the navbar switcher, the admin's own user
# payload) — CompanySerializer is the full, heavier shape for "the
# currently active company's own settings screen."
class CompanySummarySerializer
  def initialize(company, active: nil)
    @company = company
    @active = active
  end

  def as_json(*)
    return nil if company.nil?

    {
      id: company.id,
      name: company.name,
      logo_url: logo_url,
      currency: company.currency,
      active: active
    }
  end

  private

  attr_reader :company, :active

  # The logo on show: none on Starter (Company#brand_logo).
  def logo_url
    logo = company.brand_logo
    return nil if logo.nil?

    Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true)
  end
end
