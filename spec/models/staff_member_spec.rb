require "rails_helper"

RSpec.describe StaffMember, type: :model do
  describe "capabilities" do
    it "grants a coach only checkin (attendance-marking) — no client/schedule management" do
      staff = build(:staff_member, role: :coach)

      expect(staff.can?(:checkin)).to be true
      expect(staff.can?(:sessions)).to be false
      expect(staff.can?(:contract_types)).to be false
      expect(staff.can?(:clients)).to be false
      expect(staff.can?(:payments)).to be false
    end

    it "grants a moderator the daily-ops set and the coaches — not the config capabilities" do
      staff = build(:staff_member, role: :moderator)

      expect(staff.can?(:sessions)).to be true
      expect(staff.can?(:bookings)).to be true
      expect(staff.can?(:clients)).to be true
      expect(staff.can?(:contracts)).to be true
      expect(staff.can?(:payments)).to be true
      expect(staff.can?(:checkin)).to be true
      expect(staff.can?(:reports)).to be true

      expect(staff.can?(:coaches)).to be true

      expect(staff.can?(:activities)).to be false
      expect(staff.can?(:contract_types)).to be false
      expect(staff.can?(:settings)).to be false
    end
  end

  describe "role assignment" do
    it "keeps a custom assigned_role instead of syncing it from the enum kind" do
      company = create(:company)
      custom = create(:role, company: company, permissions: %w[payments])
      staff = create(:staff_member, company: company, role: :moderator, assigned_role: custom)

      expect(staff.reload.assigned_role).to eq(custom)
      expect(staff.role_key).to eq(custom.key)
      expect(staff.can?(:payments)).to be true
      expect(staff.can?(:sessions)).to be false
    end
  end

  describe "validations" do
    it "lets a coach be put on any role, including one that is not called coach" do
      company = create(:company)
      coach = create(:coach, company: company)

      staff = build(:staff_member, role: :moderator, company: company, coach: coach)

      # Being a coach is having a Coach row, not holding a role with a
      # particular name — so an admin can build "Coach senior" and use it.
      expect(staff).to be_valid
      expect(staff).to be_coach
    end

    it "is not a coach without a coach of its own" do
      staff = build(:staff_member, role: :moderator)

      expect(staff).not_to be_coach
    end

    it "rejects a role belonging to another company" do
      staff = build(:staff_member, company: create(:company))
      staff.assigned_role = create(:company).roles.find_by(key: "moderator")

      expect(staff).not_to be_valid
      expect(staff.errors[:assigned_role]).to be_present
    end

    it "rejects a coach from a different company" do
      company = create(:company)
      other_org_coach = create(:coach)
      staff = build(:staff_member, role: :coach, company: company, coach: other_org_coach)

      expect(staff).not_to be_valid
    end

    it "only allows one staff record per user in a salle" do
      user = create(:user, :staff)
      record = create(:staff_member, user: user)
      duplicate = build(:staff_member, user: user, company: record.company)

      expect(duplicate).not_to be_valid
    end

    it "lets one login hold a record in each salle it is posted to" do
      user = create(:user, :staff)
      create(:staff_member, user: user)

      expect(build(:staff_member, user: user)).to be_valid
    end
  end
end
