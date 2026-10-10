# The public-within-the-app subset of Company — safe for any authenticated
# member (admin or staff) to read, unlike CompanySerializer's full profile
# (phone/email/address/etc.), which stays admin-only.
class CompanyBrandingSerializer
  def initialize(company)
    @company = company
  end

  def as_json(*)
    return nil if company.nil?

    {
      name: company.name,
      primary_color: company.brand_color,
      logo_url: logo_url,
      # Tenant-wide display settings every member's shell needs: the app
      # language and the currency symbol shown next to amounts.
      locale: company.locale,
      currency: company.currency,
      currency_symbol: company.currency_symbol
    }
  end

  private

  attr_reader :company

  # The logo on show: none on Starter (Company#brand_logo).
  def logo_url
    logo = company.brand_logo
    return nil if logo.nil?

    Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true)
  end
end
