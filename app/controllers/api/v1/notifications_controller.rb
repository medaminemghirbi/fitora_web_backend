module Api
  module V1
    # The signed-in user's notification feed — the admin's own (documents/
    # contracts expiring, employee birthdays) or a Fitora superadmin's
    # (system_update, fanned out from Superadmin::AppUpdatesController). Real-time
    # pushes go over NotificationChannel; this is the REST side: history,
    # pagination and read state. Always scoped to current_user, so any role
    # can call it and only ever sees their own.
    class NotificationsController < BaseController
      before_action :require_notification_recipient!
      before_action :set_notification, only: [ :show, :read ]

      PER_PAGE = 10

      # GET /api/v1/notifications?page=1
      def index
        scope = recipient.notifications.recent
        page = [ params[:page].to_i, 1 ].max
        records = scope.limit(PER_PAGE).offset((page - 1) * PER_PAGE)
        total = scope.count

        render json: {
          notifications: records.map { |n| NotificationSerializer.new(n).as_json },
          meta: { page: page, per_page: PER_PAGE, total: total, total_pages: (total.to_f / PER_PAGE).ceil },
          unread_count: recipient.notifications.unread.count
        }
      end

      # GET /api/v1/notifications/:id
      def show
        render json: { notification: NotificationSerializer.new(@notification).as_json }
      end

      # PATCH /api/v1/notifications/:id/read
      def read
        @notification.mark_read!
        render json: { notification: NotificationSerializer.new(@notification).as_json }
      end

      # POST /api/v1/notifications/read_all
      def read_all
        recipient.notifications.unread.update_all(read_at: Time.current)
        NotificationChannel.broadcast_to(recipient, { type: "unread_count", count: 0 })
        head :no_content
      end

      # GET /api/v1/notifications/unread_count
      def unread_count
        render json: { count: recipient.notifications.unread.count }
      end

      private

      # Admins and Fitora superadmins here; a member reads theirs through
      # Api::V1::Me::NotificationsController, which overrides these two.
      def require_notification_recipient!
        render_forbidden unless current_user.admin? || current_user.superadmin?
      end

      def recipient
        current_user
      end

      def set_notification
        @notification = recipient.notifications.find(params[:id])
      end
    end
  end
end
