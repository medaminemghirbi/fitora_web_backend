FactoryBot.define do
  factory :activity_template do
    sequence(:key) { |n| "discipline_#{n}" }
    family { "wellness" }
    emoji { "🌀" }
    names { { "fr" => "Pilates Reformer", "en" => "Reformer Pilates", "ar" => "بيلاتس ريفورمر" } }
    session_format { :small_group }
    duration { 50 }
    capacity { 6 }
  end
end
