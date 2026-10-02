require "rails_helper"

RSpec.describe User, "#permission_keys and #role_summary" do
  it "grants a platform superadmin no role and no permissions" do
    user = create(:user, :superadmin)

    expect(user.role_summary).to be_nil
    expect(user.permission_keys).to eq([])
  end

  it "grants the admin every permission the product exposes, under the company's admin role" do
    user = create(:company).admin

    expect(user.role_summary).to eq(key: "admin", name: "Administrateur")
    expect(user.permission_keys).to match_array(Permission::ALL)
  end

  it "resolves permissions from a custom role assigned to a staff member" do
    company = create(:company)
    custom_role = create(:role, company: company, key: "accountant", name: "Comptable",
                                 permissions: %w[clients payments], builtin: false)
    user = create(:user, :staff)
    create(:staff_member, company: company, user: user, role: :moderator, assigned_role: custom_role)

    expect(user.role_summary).to eq(key: "accountant", name: "Comptable")
    expect(user.permission_keys).to match_array(%w[clients payments])
  end

  it "falls back to the built-in role matching the staff member's enum role when none is explicitly assigned" do
    company = create(:company)
    user = create(:user, :staff)
    create(:staff_member, company: company, user: user, role: :coach)

    expect(user.role_summary).to eq(key: "coach", name: "Coach")
    expect(user.permission_keys).to match_array(%w[checkin])
  end

  it "returns no role and no permissions for a staff user with no company or staff record" do
    user = create(:user, :staff)

    expect(user.role_summary).to be_nil
    expect(user.permission_keys).to eq([])
  end
end
