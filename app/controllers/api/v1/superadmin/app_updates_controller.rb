module Api
  module V1
    module Superadmin
      # The platform changelog a superadmin edits after each release — version,
      # what's new, screenshots/screen-recordings. Publishing one notifies
      # every other superadmin AND every admin in real time (NotificationChannel)
      # — the team knows the update went out, and every customer sees what's
      # new (Api::V1::AppUpdatesController is their read-only, non-superadmin view).
      class AppUpdatesController < BaseController
        before_action :require_superadmin!

        # GET /api/v1/superadmin/app_updates
        def index
          updates = AppUpdate.includes(:created_by, media_attachments: :blob).recent
          render json: { app_updates: updates.map { |u| AppUpdateSerializer.new(u).as_json } }
        end

        # POST /api/v1/superadmin/app_updates (multipart/form-data — media[] are uploads)
        def create
          update = AppUpdate.new(update_params.merge(created_by: current_user))
          update.media.attach(params[:media]) if params[:media].present?

          if update.save
            notify_recipients(update)
            render json: { app_update: AppUpdateSerializer.new(update).as_json }, status: :created
          else
            render_errors(update)
          end
        end

        private

        def update_params
          params.require(:app_update).permit(:version, :title, :description)
        end

        def notify_recipients(update)
          data = { version: update.version, title: update.title, published_by: current_user.full_name }

          User.superadmin.active.where.not(id: current_user.id).find_each do |superadmin|
            Notification.push(
              recipient: superadmin, kind: "system_update", data: data, url: "/superadmin/updates",
              dedup_key: "system_update-#{update.id}-#{superadmin.id}", subject: update
            )
          end

          # Every customer sees the release notes too, on their own read-only
          # page — superadmins get the editable /superadmin/updates instead.
          User.admin.active.find_each do |admin|
            Notification.push(
              recipient: admin, kind: "system_update", data: data, url: "/admin/updates",
              dedup_key: "system_update-#{update.id}-#{admin.id}", subject: update
            )
          end
        end
      end
    end
  end
end
