class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # A write the gym's rules turn down — "this session is full", "this is
  # already paid" — with the reason in words the person asking can act on.
  # Raised from a model method, it rolls back the transaction it is in, and
  # ApplicationController answers it with a 422 in the same shape a failed
  # validation gets.
  class Refused < StandardError; end
end
