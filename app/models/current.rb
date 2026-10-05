# Per-request state that a model has no other honest way to reach.
#
# Deliberately tiny, and deliberately not a back door for passing the current
# user around: a method that needs to know who is acting should be told, as
# an argument. The one thing here is the exception, because it is invisible
# by design.
#
# When a Fitora superadmin impersonates an admin
# (Api::V1::Superadmin::CompaniesController#impersonate), current_user IS the
# admin for the whole session — that is the point, so the superadmin sees exactly
# what the admin sees. The consequence is that every audit log written during
# that session would otherwise name the admin for something the superadmin did.
# AuditLog.record! reads this to say who was really at the keyboard.
class Current < ActiveSupport::CurrentAttributes
  attribute :impersonator
end
