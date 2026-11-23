# frozen_string_literal: true

# Board, Abschluss und Teamrunde
class TeamPlanningController < ApplicationController
  before_action :require_login
  before_action :find_user, except: %i[team update_round]
  before_action :authorize_view, except: %i[team update_round]
  before_action :authorize_use, only: %i[team update_round]

  helper :team_planning
  include TeamPlanningHelper

  def show
    @planner = RedmineTeamPlanning::Planner.new(@user)
    # Im Board durch frühere Zeiträume blättern: ?past=YYYY-MM-DD
    @past = @planner.closed_period(params[:past]) if params[:past].present?
    return render(partial: 'team_planning/board', locals: { planner: @planner, past: @past }) if params[:partial] == 'board'
  end

  # Alle abgeschlossenen Zeiträume einer Person
  def periods
    @planner = RedmineTeamPlanning::Planner.new(@user)
    @periods = @planner.closed_periods.includes(:items).to_a
  end

  # Ein abgeschlossener Zeitraum: Bilanz, Tickets, Rückblick, Notizen der Runde
  def period
    @planner = RedmineTeamPlanning::Planner.new(@user)
    @period = @planner.closed_period(params[:starts_on])
    return render_404 unless @period

    @editing = params[:edit].present? && @planner.editable?
  end

  # Nachträglich ändern: Rückblick, Fokus und Notizen der Teamrunden im Zeitraum
  def update_period
    @planner = RedmineTeamPlanning::Planner.new(@user)
    @period = @planner.closed_period(params[:starts_on])
    return render_404 unless @period
    return deny_access unless @planner.editable?

    review = params.fetch(:period, {}).permit(:review_good, :review_bad, :review_change, :focus, :notes).to_h
    TeamPlanningPeriod.transaction do
      @period.update!(review.transform_values(&:presence))
      notes = params.fetch(:rounds, {}).permit!.to_h
      @planner.round_notes(@period).where(id: notes.keys.map(&:to_i)).each do |round|
        round.update!(notes: notes[round.id.to_s].to_s)
      end
    end
    notify_owner(l(:text_team_planning_change_review, period: @period.label)) unless @user == User.current
    flash[:notice] = l(:notice_successful_update)
    redirect_to team_planning_period_path(@period.starts_on.iso8601, user_param)
  end

  def close
    @planner = RedmineTeamPlanning::Planner.new(@user)
    @closing = RedmineTeamPlanning::Closing.new(@planner)
  end

  def close_period
    @planner = RedmineTeamPlanning::Planner.new(@user)
    @closing = RedmineTeamPlanning::Closing.new(@planner)
    period = @closing.call(decisions: params[:decisions]&.permit!.to_h || {},
                           end_standing: params[:end_standing] || [],
                           review: params.fetch(:review, {}).permit(:good, :bad, :change).to_h.symbolize_keys,
                           focus: params[:focus], notes: params[:notes])
    flash[:notice] = l(:notice_team_planning_period_closed, period: period.label, next: @planner.current_period.label)
    notify_owner(l(:text_team_planning_change_closed, period: period.label))
    redirect_to team_planning_path(user_param)
  rescue RedmineTeamPlanning::Planner::Error => e
    flash.now[:error] = e.message
    render :close, status: 422
  end

  def team
    @team_round = RedmineTeamPlanning::TeamRound.new
    @mode = params[:mode] == 'project' ? 'project' : 'person'
  end

  def update_round
    team_round = RedmineTeamPlanning::TeamRound.new
    round = team_round.round
    round.notes = params[:notes].to_s
    round.save!
    render json: { saved: true }
  end

  def settings
    planner = RedmineTeamPlanning::Planner.new(@user)
    planner.update_settings(weeks: params[:weeks], limit: params[:limit])
    render json: { message: l(:notice_team_planning_settings_saved) }
  rescue RedmineTeamPlanning::Planner::Error => e
    render json: { error: e.message }, status: 422
  end

  private

  def find_user
    @user = params[:user_id].present? ? User.active.find_by(id: params[:user_id]) : User.current
    render_404 unless @user
  end

  def authorize_view
    deny_access unless RedmineTeamPlanning::Access.view?(User.current, @user)
  end

  def authorize_use
    deny_access unless RedmineTeamPlanning::Access.use?(User.current)
  end

  def user_param
    @user == User.current ? {} : { user_id: @user.id }
  end

  def notify_owner(change)
    TeamPlanningMailer.deliver_plan_changed(@user, User.current, change)
  end
end
