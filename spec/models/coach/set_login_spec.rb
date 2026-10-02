require "rails_helper"

RSpec.describe Coach, "#set_login!" do
  it "provisions a new staff login for a coach without one" do
    coach = create(:coach)

    staff_member = coach.set_login!(email: "coach@example.com", password: "password123")

    expect(staff_member).to be_persisted
    expect(staff_member.coach).to eq(coach)
    expect(staff_member.role_key).to eq("coach")
    expect(staff_member).to be_coach
    expect(staff_member.company).to eq(coach.company)
    expect(staff_member.user.email).to eq("coach@example.com")
    expect(staff_member.user.role).to eq("staff")
    expect(coach.reload.staff_member).to eq(staff_member)
  end

  it "resets the linked user's credentials when the coach already has a login" do
    coach = create(:coach)
    coach.set_login!(email: "old@example.com", password: "password123")
    existing_staff_member = coach.reload.staff_member

    staff_member = coach.set_login!(email: "new@example.com", password: "newpassword123")

    expect(staff_member.id).to eq(existing_staff_member.id)
    expect(staff_member.user.email).to eq("new@example.com")
    expect(staff_member.user.authenticate("newpassword123")).to be_truthy
    expect(StaffMember.where(coach: coach).count).to eq(1)
  end

  it "raises the validation error when the email is already taken, and provisions nothing" do
    create(:user, email: "taken@example.com")
    coach = create(:coach)

    expect { coach.set_login!(email: "taken@example.com", password: "password123") }
      .to raise_error(ActiveRecord::RecordInvalid, /Email has already been taken/)
    expect(coach.reload.staff_member).to be_nil
  end
end
