class AttendanceRecord < ApplicationRecord
  belongs_to :booking
  belongs_to :marked_by, class_name: "User", optional: true

  enum :status, { present: 0, absent: 1, late: 2, no_show: 3 }

  validates :booking_id, uniqueness: true

  # Idempotent: marking the same booking twice updates its one record
  # instead of erroring on the unique booking_id index.
  def self.mark!(booking:, status:, marked_by:, checked_in_at: nil, checked_out_at: nil)
    transaction do
      record = lock.find_or_initialize_by(booking: booking)
      record.status = status
      record.marked_by = marked_by
      record.checked_in_at = checked_in_at if checked_in_at
      record.checked_out_at = checked_out_at if checked_out_at
      record.save!
      record
    end
  rescue ActiveRecord::RecordNotUnique
    # Two concurrent first-time marks for the same booking — the loser
    # just updates the row the winner created instead of erroring.
    retry
  end
end
