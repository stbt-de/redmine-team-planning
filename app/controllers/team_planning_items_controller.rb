# frozen_string_literal: true

# Änderungen auf dem Board und im Widget. Antwortet mit JSON:
#   { message:, undo: { url:, method:, params: } }   oder   { error: }
class TeamPlanningItemsController < ApplicationController
  before_action :require_login
  before_action :find_user
  before_action :find_issue, except: %i[create absence]

  helper :team_planning
  include TeamPlanningHelper

  rescue_from RedmineTeamPlanning::Planner::Error do |e|
    render json: { error: e.message }, status: 422
  end

  def move
    to = params[:to].to_s
    undo = planner.move(@issue, to: to, position: params[:position])
    message = if undo[:assigned]
                l(:notice_team_planning_assigned, issue: "##{@issue.id}", name: assignee_name, target: location_label(to))
              else
                l(:notice_team_planning_moved, issue: "##{@issue.id}", target: location_label(to))
              end
    respond(message, undo: undo_move(undo))
  end

  def create
    project = Project.visible.find_by(id: params[:project_id])
    raise RedmineTeamPlanning::Planner::Error, l(:error_team_planning_project_missing) unless project

    issue = planner.create_issue(subject: params[:subject], project: project, to: params[:to].to_s)
    respond(l(:notice_team_planning_created, issue: "##{issue.id}", target: location_label(params[:to].to_s)),
            issue_id: issue.id)
  end

  def update
    attributes = params.permit(:planned_hours, :kind, :until_on, :carry_ack).to_h.symbolize_keys
    attributes[:planned_hours] = parse_hours(attributes[:planned_hours]) if attributes.key?(:planned_hours)
    previous = planner.update_item(@issue, attributes)
    message = if attributes.key?(:carry_ack)
                l(:notice_team_planning_carry_ack, issue: "##{@issue.id}")
              elsif attributes.key?(:planned_hours)
                attributes[:planned_hours] ? l(:notice_team_planning_hours_planned, issue: "##{@issue.id}", hours: format_hours(attributes[:planned_hours])) : l(:notice_team_planning_hours_cleared, issue: "##{@issue.id}")
              elsif attributes[:kind] == 'long'
                l(:notice_team_planning_long, issue: "##{@issue.id}")
              else
                l(:notice_team_planning_normal, issue: "##{@issue.id}")
              end
    respond(message, undo: { url: team_planning_item_path(@issue, user_param), method: 'PATCH',
                             params: previous.transform_values { |v| v.is_a?(Date) ? v.iso8601 : v&.to_s } })
  end

  def done_options
    completion = RedmineTeamPlanning::Completion.new(planner, @issue)
    render json: completion.options.map { |o|
      { id: o.id, label: o.label, status: o.status&.name, assign: o.assign_label, comment: o.comment,
        disabled: o.disabled_reason }
    }
  end

  def complete
    option = RedmineTeamPlanning::Completion.new(planner, @issue).complete(params[:action_id])
    @issue.reload
    message = l(:notice_team_planning_done, issue: "##{@issue.id}")
    if option
      message += " #{l(:notice_team_planning_done_action, status: @issue.status.name,
                                                    assignee: @issue.assigned_to&.name || '–')}"
    end
    respond(message, undo: { url: team_planning_reopen_path(@issue, user_param), method: 'POST', params: {} })
  end

  def reopen
    RedmineTeamPlanning::Completion.new(planner, @issue).reopen
    respond(l(:notice_team_planning_reopened, issue: "##{@issue.id}"))
  end

  def unassign
    from = planner.location(@issue)
    position = planner.position_in(@issue, from)
    planner.unassign(@issue)
    respond(l(:notice_team_planning_unassigned, issue: "##{@issue.id}"),
            undo: { url: team_planning_move_path(@issue, user_param), method: 'POST', params: { to: from, position: position } })
  end

  def end_standing
    raise RedmineTeamPlanning::Planner::Error, l(:error_team_planning_not_allowed) unless planner.editable?

    TeamPlanningStanding.transaction { RedmineTeamPlanning::Closing.new(planner).end_standing!(@issue.id) }
    respond(l(:notice_team_planning_standing_ended, issue: "##{@issue.id}"))
  end

  def absence
    days = params[:days].to_i
    previous = planner.set_absence(params[:starts_on], days)
    respond(days.positive? ? l(:notice_team_planning_absence, count: days) : l(:notice_team_planning_absence_none),
            undo: { url: team_planning_absence_path(params[:starts_on], user_param), method: 'PATCH',
                    params: { days: previous } })
  end

  # Zeit buchen aus dem Widget: eigene Buchung, Redmines Rechte und Pflichtfelder
  def log_time
    raise RedmineTeamPlanning::Planner::Error, l(:error_team_planning_not_allowed) unless planner.own?

    entry = TimeEntry.new(project: @issue.project, issue: @issue, user: User.current, author: User.current,
                          spent_on: User.current.today)
    entry.safe_attributes = params.permit(:hours, :spent_on, :activity_id, :comments).to_h.compact_blank
    entry.hours = parse_hours(params[:hours])
    entry.activity ||= @issue.project.activities.detect(&:is_default?) || @issue.project.activities.first
    raise RedmineTeamPlanning::Planner::Error, entry.errors.full_messages.to_sentence unless entry.save

    render json: { message: l(:notice_team_planning_time_logged, hours: format_hours(entry.hours), issue: "##{@issue.id}"),
                   undo: entry.editable_by?(User.current) ? { url: team_planning_time_entry_path(@issue, entry), method: 'DELETE', params: {} } : nil }
  end

  # Rückgängig für eine eben gebuchte Zeit (nur eigene, bearbeitbare)
  def destroy_time
    entry = TimeEntry.find_by(id: params[:id], user_id: User.current.id, issue_id: @issue.id)
    raise RedmineTeamPlanning::Planner::Error, l(:error_team_planning_not_allowed) unless entry&.editable_by?(User.current)

    entry.destroy
    render json: { message: l(:notice_team_planning_time_removed) }
  end

  private

  def planner
    @planner ||= RedmineTeamPlanning::Planner.new(@user)
  end

  def find_user
    @user = params[:user_id].present? ? User.active.find_by(id: params[:user_id]) : User.current
    render json: { error: l(:error_team_planning_not_allowed) }, status: :forbidden unless @user && RedmineTeamPlanning::Access.view?(User.current, @user)
  end

  def find_issue
    @issue = Issue.visible.find_by(id: params[:issue_id])
    render json: { error: l(:error_team_planning_issue_missing) }, status: :not_found unless @issue
  end

  def user_param
    @user == User.current ? {} : { user_id: @user.id }
  end

  def assignee_name
    @user == User.current ? l(:label_team_planning_you) : @user.name
  end

  def location_label(location)
    case location
    when 'backlog' then l(:label_team_planning_backlog)
    when 'pool' then l(:label_team_planning_pool)
    when 'standing' then l(:label_team_planning_standing)
    when 'later' then l(:label_team_planning_later)
    else
      planner.periods.find { |p| p.starts_on.iso8601 == location }&.label || location
    end
  end

  def undo_move(undo)
    if undo[:assigned]
      { url: team_planning_unassign_path(@issue, user_param), method: 'POST', params: {} }
    else
      { url: team_planning_move_path(@issue, user_param), method: 'POST', params: { to: undo[:from], position: undo[:position] } }
    end
  end

  def respond(message, extra = {})
    TeamPlanningMailer.deliver_plan_changed(@user, User.current, message) unless @user == User.current
    render json: { message: message }.merge(extra)
  end

  def parse_hours(value)
    return nil if value.blank?

    number = value.to_s.tr(',', '.').to_f
    number.positive? ? number : nil
  end
end
