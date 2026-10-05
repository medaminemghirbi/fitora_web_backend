module Api
  module V1
    # GET /api/v1/activity_templates — the catalogue a salle picks its
    # activities from. Needs no company: it is read while the salle is being
    # created. Every name is sent; the screen shows the one in its language.
    class ActivityTemplatesController < BaseController
      def index
        templates = ActivityTemplate.active.catalogue_order
        render json: { activity_templates: templates.map { |t| ActivityTemplateSerializer.new(t).as_json } }
      end
    end
  end
end
