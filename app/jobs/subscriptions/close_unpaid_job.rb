module Subscriptions
  # Closes access for every gym whose paid period ran out more than
  # GRACE_DAYS ago. Runs nightly.
  #
  # Idempotent: it only ever moves `active` from true to false, so a missed
  # night caught up late, or two runs in a row, land in the same place. That
  # is why access could stop being a computed answer — nothing depends on
  # this having run at the right minute.
  class CloseUnpaidJob < ApplicationJob
    queue_as :default

    def perform
      Subscription.close_unpaid!
    end
  end
end
