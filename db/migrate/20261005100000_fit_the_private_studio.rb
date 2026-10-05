# What an EMS, Pilates, yoga or personal-training studio needs that a gym
# never asked for. All additive, all nullable or defaulted, so every
# existing row keeps meaning exactly what it meant.
#
#   contract_types.validity_days     — "10 séances, valables 8 semaines": a
#                                      carnet's own lifetime, used when the
#                                      formule's billing_period is `custom`.
#   contract_periods.paused_at       — a membership on hold (injury,
#                                      pregnancy, holidays). Resuming pushes
#                                      expires_at back by the time held.
#   bookings.trial                   — a first session sold without a
#                                      contract, so a studio can count how
#                                      many trials it turned into members.
#   bookings.reminder_sent_at        — the automatic reminder went out; the
#                                      scan never sends it twice.
#   memberships.health_notes         — contraindications the coach must
#                                      know before an EMS or Pilates session.
#   memberships.waiver_signed_on     — when the member signed the studio's
#                                      health declaration.
#   recurring_schedules.space_id     — a weekly 1:1 slot belongs to a cabin
#                                      as much as to a coach.
class FitThePrivateStudio < ActiveRecord::Migration[8.1]
  def change
    add_column :contract_types, :validity_days, :integer
    add_check_constraint :contract_types, "validity_days IS NULL OR validity_days > 0",
                         name: "contract_types_validity_days_positive"

    add_column :contract_periods, :paused_at, :datetime

    add_column :bookings, :trial, :boolean, null: false, default: false
    add_column :bookings, :reminder_sent_at, :datetime
    add_index :bookings, :client_id, where: "trial", name: "index_bookings_on_client_id_when_trial"

    add_column :memberships, :health_notes, :text
    add_column :memberships, :waiver_signed_on, :date

    add_reference :recurring_schedules, :space, type: :uuid, foreign_key: true
  end
end
