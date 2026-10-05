# Singleton row of platform-wide knobs a Fitora superadmin controls. Today just
# the annual-billing discount percentage shown (informationally) on the
# admin's subscription page.
class PlatformSetting < ApplicationRecord
  validates :annual_discount_percent, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  # The one and only row, created on first access.
  def self.current
    first || create!
  end
end
