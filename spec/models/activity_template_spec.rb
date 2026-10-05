require "rails_helper"

RSpec.describe ActivityTemplate do
  it "needs a French name, the one every gym can fall back on" do
    template = build(:activity_template, names: { "en" => "Boxing" })

    expect(template).not_to be_valid
    expect(template.errors[:names]).to be_present
  end

  it "names itself in the asked language, else in French" do
    template = build(:activity_template, names: { "fr" => "Boxe", "en" => "Boxing" })

    expect(template.name_for("en")).to eq("Boxing")
    expect(template.name_for("ar")).to eq("Boxe")
  end

  it "lists the catalogue family by family" do
    combat = create(:activity_template, family: "combat")
    fitness = create(:activity_template, family: "fitness")

    expect(described_class.catalogue_order).to eq([ fitness, combat ])
  end
end

RSpec.describe Company, "#adopt_activities!" do
  let(:company) { create(:company, locale: "en") }
  let(:template) { create(:activity_template) }

  it "copies a template into the gym's own activity, named in the gym's language" do
    activity = company.adopt_activities!(template_ids: [ template.id ]).first

    expect(activity).to have_attributes(
      company: company, activity_template: template, name: "Reformer Pilates", emoji: "🌀",
      session_format: "small_group", duration: 50, capacity: 6
    )
  end

  it "leaves the gym's copy alone when the template changes" do
    activity = company.adopt_activities!(template_ids: [ template.id ]).first
    template.update!(duration: 90)

    expect(activity.reload.duration).to eq(50)
  end

  it "creates the activities the gym names itself" do
    created = company.adopt_activities!(custom: [ { name: "Aerial yoga", emoji: "🪂" }, { name: " " } ])

    expect(created.map(&:name)).to eq([ "Aerial yoga" ])
    expect(created.first.activity_template).to be_nil
  end

  it "refuses an id that is not in the catalogue, and creates nothing" do
    expect { company.adopt_activities!(template_ids: [ template.id, SecureRandom.uuid ]) }
      .to raise_error(ApplicationRecord::Refused)
    expect(company.activities).to be_empty
  end

  it "refuses a template taken out of the catalogue" do
    template.update!(active: false)

    expect { company.adopt_activities!(template_ids: [ template.id ]) }.to raise_error(ApplicationRecord::Refused)
  end
end
