module Receipts
  # An attached image (the gym's logo, its signature) as something Prawn can
  # draw — or nil. Prawn embeds PNG and JPEG only, so a WebP logo is simply
  # left off the document rather than failing it.
  module PrintableImage
    PRINTABLE = %w[image/png image/jpeg].freeze

    def self.io(attachment)
      return nil unless attachment&.attached?
      return nil unless attachment.content_type.in?(PRINTABLE)

      StringIO.new(attachment.download)
    rescue ActiveStorage::FileNotFoundError
      nil
    end
  end
end
