# frozen_string_literal: true

class NotificationsController < ApplicationController

  requires_login
  before_action :ensure_admin, only: [:create, :update, :destroy]
  before_action :set_notification, only: [:update, :destroy]

  def index
    user =
      if params[:username] && !params[:recent]
        user_record = User.find_by(username: params[:username].to_s)
        raise Discourse::NotFound if !user_record
        user_record
      else
        current_user
      end

    guardian.ensure_can_see_notifications!(user)

    if notification_types = params[:filter_by_types]&.split(",").presence
      notification_types.map! do |type|
        Notification.types[type.to_sym] || (
          raise Discourse::InvalidParameters.new("invalid notification type: #{type}")
        )
      end
    end

    if params[:recent].present?
      limit = (params[:limit] || 15).to_i
      limit = 50 if limit > 50

      include_reviewables = false

      if SiteSetting.legacy_navigation_menu?
        notifications = Notification.recent_report(current_user, limit, notification_types)
      else
        notifications = Notification.prioritized_list(current_user, count: limit, types: notification_types)
        # notification_types is blank for the "all notifications" user menu tab
        include_reviewables = notification_types.blank? && guardian.can_see_review_queue?
      end

      if notifications.present? && !(params.has_key?(:silent) || @readonly_mode)
        if current_user.bump_last_seen_notification!
          current_user.reload
          current_user.publish_notifications_state
        end
      end

      if !params.has_key?(:silent) && params[:bump_last_seen_reviewable] && !@readonly_mode && include_reviewables
        current_user_id = current_user.id
        Scheduler::Defer.later "bump last seen reviewable for user" do
          # we lookup current_user again in the background thread to avoid
          # concurrency issues where the user object returned by the
          # current_user controller method is changed by the time the deferred
          # block is executed
          User.find_by(id: current_user_id)&.bump_last_seen_reviewable!
        end
      end

      notifications = filter_inaccessible_notifications(notifications)

      json = {
        notifications: serialize_data(notifications, NotificationSerializer),
        seen_notification_id: current_user.seen_notification_id
      }

      if include_reviewables
        json[:pending_reviewables] = Reviewable.basic_serializers_for_list(
          Reviewable.user_menu_list_for(current_user),
          current_user
        ).as_json
      end

      render_json_dump(json)
    else
      offset = params[:offset].to_i

      notifications = Notification.where(user_id: user.id)
        .visible
        .includes(:topic)
        .order(created_at: :desc)

      notifications = notifications.where(read: true) if params[:filter] == "read"

      notifications = notifications.where(read: false) if params[:filter] == "unread"

      total_rows = notifications.dup.count
      notifications = notifications.offset(offset).limit(60)
      notifications = filter_inaccessible_notifications(notifications)
      render_json_dump(notifications: serialize_data(notifications, NotificationSerializer),
                       total_rows_notifications: total_rows,
                       seen_notification_id: user.seen_notification_id,
                       load_more_notifications: notifications_path(username: user.username, offset: offset + 60, filter: params[:filter]))
    end

  end

  def mark_read
    if params[:id]
      Notification.read(current_user, [params[:id].to_i])
    else
      if types = params[:dismiss_types]&.split(",").presence
        invalid = []
        types.map! do |type|
          type_id = Notification.types[type.to_sym]
          invalid << type if !type_id
          type_id
        end
        if invalid.size > 0
          raise Discourse::InvalidParameters.new("invalid notification types: #{invalid.inspect}")
        end
      end

      Notification.read_types(current_user, types)
      current_user.bump_last_seen_notification!
    end

    current_user.reload
    current_user.publish_notifications_state

    render json: success_json
  end

  def create
    @notification = Notification.consolidate_or_create!(notification_params)
    render_notification
  end

  def update
    @notification.update!(notification_params)
    render_notification
  end

  def destroy
    @notification.destroy!
    render json: success_json
  end

  private

  def set_notification
    @notification = Notification.find(params[:id])
  end

  def notification_params
    params.permit(:notification_type, :user_id, :data, :read, :topic_id, :post_number, :post_action_id)
  end

  def render_notification
    render_json_dump(NotificationSerializer.new(@notification, scope: guardian, root: false))
  end

  def filter_inaccessible_notifications(notifications)
    topic_ids = notifications.map { |n| n.topic_id }.compact.uniq
    accessible_topic_ids = guardian.can_see_topic_ids(topic_ids: topic_ids)
    notifications.select { |n| n.topic_id.blank? || accessible_topic_ids.include?(n.topic_id) }
  end
end
