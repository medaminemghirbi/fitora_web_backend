# A problem report from the admin's "Contact" tab (modules marketplace
# page), with optional file/video attachments — reviewed by a Fitora superadmin
# from a cross-company inbox rather than per-company like module requests.
class SupportTicket < ApplicationRecord
  ALLOWED_ATTACHMENT_TYPES = %w[
    image/jpeg image/png image/webp image/gif
    application/pdf
    video/mp4 video/quicktime video/webm
  ].freeze
  MAX_ATTACHMENT_SIZE = 100.megabytes
  MAX_ATTACHMENTS = 5

  belongs_to :company
  belongs_to :created_by, class_name: "User"

  has_many_attached :attachments

  enum :status, { open: 0, resolved: 1 }
  # `upgrade` is a plan request from the admin's subscription page.
  enum :kind, { general: 0, upgrade: 1 }

  # Digits with the usual separators, an optional leading "+" or "(+". The digit count
  # is checked apart: "+216 22 123 456" and "22123456" are both fine.
  PHONE_FORMAT = /\A\(?\+?[\d\s().-]+\z/
  PHONE_DIGITS = 8..15

  before_validation { self.contact_phone = contact_phone.to_s.strip.presence }

  validates :subject, :message, presence: true
  # Fitora calls back to set a plan up — payment is arranged off-app — so a
  # plan request without a number goes nowhere.
  validates :contact_phone, presence: true, if: :upgrade?
  validate :contact_phone_is_a_number
  validate :attachments_are_valid

  scope :recent, -> { order(created_at: :desc) }

  private

  def contact_phone_is_a_number
    return if contact_phone.blank?

    digits = contact_phone.count("0-9")
    return if contact_phone.match?(PHONE_FORMAT) && PHONE_DIGITS.cover?(digits)

    errors.add(:contact_phone, "is not a valid phone number")
  end

  def attachments_are_valid
    return unless attachments.attached?

    if attachments.count > MAX_ATTACHMENTS
      errors.add(:attachments, "cannot include more than #{MAX_ATTACHMENTS} files")
    end

    attachments.each do |file|
      unless file.content_type.in?(ALLOWED_ATTACHMENT_TYPES)
        errors.add(:attachments, "must be an image, a video, or a PDF")
        break
      end
    end

    attachments.each do |file|
      if file.blob.byte_size > MAX_ATTACHMENT_SIZE
        errors.add(:attachments, "must each be smaller than #{MAX_ATTACHMENT_SIZE / 1.megabyte}MB")
        break
      end
    end
  end
end
