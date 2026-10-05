# The activity catalogue a gym picks from when it opens (ActivityTemplate).
# Keyed, so re-running it updates a template in place rather than adding a
# second one; a template dropped from this list is left alone (gyms may
# still point at it) — deactivate it instead.
#
#   key, family, emoji, format, minutes, places, { fr, en, ar }
catalogue = [
  [ "musculation", "fitness", "🏋️", :collective, 60, 20, { fr: "Musculation", en: "Weight training", ar: "كمال الأجسام" } ],
  [ "renforcement", "fitness", "💪", :collective, 45, 15, { fr: "Renforcement musculaire", en: "Strength class", ar: "تقوية العضلات" } ],
  [ "crossfit", "fitness", "🔥", :collective, 60, 12, { fr: "CrossFit", en: "CrossFit", ar: "كروس فيت" } ],
  [ "hiit", "fitness", "⏱️", :collective, 45, 12, { fr: "HIIT", en: "HIIT", ar: "تدريب متقطع عالي الكثافة" } ],
  [ "cycling", "fitness", "🚴", :collective, 45, 15, { fr: "Cycling", en: "Indoor cycling", ar: "دراجة داخلية" } ],
  [ "cardio", "fitness", "🏃", :collective, 45, 15, { fr: "Cardio training", en: "Cardio", ar: "تمارين القلب" } ],
  [ "coaching_prive", "fitness", "🎯", :individual, 60, 1, { fr: "Coaching privé", en: "Personal training", ar: "تدريب خاص" } ],
  [ "yoga", "wellness", "🧘", :collective, 60, 14, { fr: "Yoga", en: "Yoga", ar: "يوغا" } ],
  [ "pilates_reformer", "wellness", "🌀", :small_group, 50, 6, { fr: "Pilates Reformer", en: "Reformer Pilates", ar: "بيلاتس ريفورمر" } ],
  [ "pilates_sol", "wellness", "🤸", :collective, 50, 12, { fr: "Pilates sol", en: "Mat Pilates", ar: "بيلاتس على البساط" } ],
  [ "stretching", "wellness", "🙆", :collective, 45, 15, { fr: "Stretching", en: "Stretching", ar: "تمارين التمدد" } ],
  [ "meditation", "wellness", "🕊️", :collective, 30, 15, { fr: "Méditation", en: "Meditation", ar: "تأمل" } ],
  [ "boxe", "combat", "🥊", :collective, 60, 16, { fr: "Boxe", en: "Boxing", ar: "ملاكمة" } ],
  [ "kickboxing", "combat", "🦵", :collective, 60, 16, { fr: "Kick-boxing", en: "Kickboxing", ar: "كيك بوكسينغ" } ],
  [ "mma", "combat", "🤼", :collective, 60, 12, { fr: "MMA", en: "MMA", ar: "فنون القتال المختلطة" } ],
  [ "karate", "combat", "🥋", :collective, 60, 20, { fr: "Karaté", en: "Karate", ar: "كاراتيه" } ],
  [ "judo", "combat", "🥋", :collective, 60, 20, { fr: "Judo", en: "Judo", ar: "جودو" } ],
  [ "ems", "tech", "⚡", :individual, 25, 1, { fr: "EMS", en: "EMS training", ar: "التحفيز الكهربائي للعضلات" } ],
  [ "aquagym", "aquatic", "🌊", :collective, 45, 15, { fr: "Aquagym", en: "Aqua aerobics", ar: "رياضة مائية" } ],
  [ "natation", "aquatic", "🏊", :small_group, 45, 8, { fr: "Natation", en: "Swimming lessons", ar: "سباحة" } ],
  [ "zumba", "dance", "💃", :collective, 60, 20, { fr: "Zumba", en: "Zumba", ar: "زومبا" } ],
  [ "danse", "dance", "🕺", :collective, 60, 15, { fr: "Danse", en: "Dance", ar: "رقص" } ],
  [ "barre", "dance", "🩰", :collective, 50, 12, { fr: "Barre au sol", en: "Barre", ar: "تمارين البار" } ],
  [ "escalade", "outdoor", "🧗", :small_group, 90, 8, { fr: "Escalade", en: "Climbing", ar: "تسلق" } ],
  [ "running", "outdoor", "👟", :collective, 60, 20, { fr: "Running club", en: "Running club", ar: "نادي الجري" } ]
]

catalogue.each_with_index do |(key, family, emoji, format, duration, capacity, names), position|
  template = ActivityTemplate.find_or_initialize_by(key: key)
  template.update!(family: family, emoji: emoji, session_format: format, duration: duration, capacity: capacity,
                   names: names.stringify_keys, position: position)
end
