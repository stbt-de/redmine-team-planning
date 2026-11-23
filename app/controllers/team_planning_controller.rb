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
    return render(partial: 'team_planning/board', locals: { planner: @planner }) if params[:partial] == 'board'
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
                           focus: params[:focus])
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
