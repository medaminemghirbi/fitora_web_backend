require "rails_helper"

RSpec.describe User do
  it "downcases and strips the email before validation" do
    user = create(:user, :admin, email: "  Test@Example.COM ")
    expect(user.email).to eq("test@example.com")
  end

  it "rejects a locale outside the supported set" do
    user = build(:user, :admin, locale: "de")
    expect(user).not_to be_valid
    expect(user.errors[:locale]).to be_present
  end

  it "requires a minimum password length on create" do
    user = build(:user, :admin, password: "short")
    expect(user).not_to be_valid
    expect(user.errors[:password]).to be_present
  end

  it "does not require re-entering a password on an update that leaves it alone" do
    user = create(:user, :admin)
    reloaded = User.find(user.id)
    reloaded.first_name = "Changed"

    expect(reloaded).to be_valid
  end

  it "builds the full name from first and last name" do
    user = build(:user, first_name: "Jane", last_name: "Doe")
    expect(user.full_name).to eq("Jane Doe")
  end

  describe "role" do
    it "exposes admin/staff/superadmin as predicate methods via the enum" do
      expect(create(:user, :admin)).to be_admin
      expect(create(:user, :staff)).to be_staff
      expect(create(:user, :superadmin)).to be_superadmin
    end
  end

  describe ".active" do
    it "only returns active users" do
      active = create(:user, :admin, active: true)
      inactive = create(:user, :admin, active: false)

      expect(User.active).to include(active)
      expect(User.active).not_to include(inactive)
    end
  end

  describe "#switch_active_company!" do
    it "moves active_company to another of the admin's own companies" do
      admin = create(:user, :admin)
      first = create(:company, admin: admin)
      second = create(:company, admin: admin)

      expect(admin.switch_active_company!(second)).to be true
      expect(admin.reload.active_company).to eq(second)
      expect(first).to be_present # sanity: still exists, just no longer active
    end

    it "refuses to switch onto a company this admin doesn't own" do
      admin = create(:user, :admin)
      other_company = create(:company)

      expect(admin.switch_active_company!(other_company)).to be false
      expect(admin.reload.active_company).not_to eq(other_company)
    end

    it "moves a staff login between the salles it is posted to, and nowhere else" do
      admin = create(:user, :admin)
      first = create(:company, admin: admin)
      second = create(:company, admin: admin)
      stranger = create(:company)
      record = create(:staff_member, company: first, role: :moderator)
      user = record.user
      create(:staff_member, company: second, user: user, role: :moderator)

      expect(user.switch_active_company!(second)).to be true
      expect(user.reload.current_company).to eq(second)
      expect(user.switch_active_company!(stranger)).to be false
      expect(user.reload.current_company).to eq(second)
    end
  end

  describe "#current_company" do
    it "is the admin's active salle" do
      company = create(:company)
      expect(company.admin.reload.current_company).to eq(company)
    end

    it "is a staff login's salle, never one it has been withdrawn from" do
      admin = create(:user, :admin)
      first = create(:company, admin: admin)
      second = create(:company, admin: admin)
      record = create(:staff_member, company: first, role: :moderator)
      user = record.user
      other = create(:staff_member, company: second, user: user, role: :moderator)
      user.update!(active_company: second)
      expect(user.reload.current_company).to eq(second)

      other.destroy!
      expect(user.reload.current_company).to eq(first)
    end
  end

  describe "#workplaces" do
    it "is every salle an admin runs" do
      admin = create(:user, :admin)
      companies = create_list(:company, 2, admin: admin)

      expect(admin.workplaces).to match_array(companies)
    end

    it "is every salle a staff login is posted to and still active in" do
      admin = create(:user, :admin)
      first = create(:company, admin: admin)
      second = create(:company, admin: admin)
      record = create(:staff_member, company: first, role: :moderator)
      create(:staff_member, company: second, user: record.user, role: :moderator, active: false)

      expect(record.user.workplaces).to contain_exactly(first)
    end
  end

  describe "#destroy" do
    it "destroys the company it owns" do
      company = create(:company)
      admin = company.admin

      admin.destroy

      expect(Company.exists?(company.id)).to be false
    end

    it "destroys every company it owns, even when several exist" do
      admin = create(:user, :admin)
      companies = create_list(:company, 3, admin: admin)

      admin.destroy

      expect(Company.where(id: companies.map(&:id))).to be_none
    end

    it "destroys its notifications" do
      user = create(:user, :admin)
      notification = create(:notification, recipient: user)

      user.destroy

      expect(Notification.exists?(notification.id)).to be false
    end
  end
end
