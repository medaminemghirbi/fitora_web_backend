class ActivityTemplateSerializer
  def initialize(template)
    @template = template
  end

  def as_json(*)
    {
      id: template.id,
      key: template.key,
      family: template.family,
      emoji: template.emoji,
      names: template.names,
      session_format: template.session_format,
      duration: template.duration,
      capacity: template.capacity
    }
  end

  private

  attr_reader :template
end
