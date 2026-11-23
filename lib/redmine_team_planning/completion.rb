# frozen_string_literal: true

module RedmineTeamPlanning
  # Abhaken im Plan ("mein Teil ist fertig") mit optionaler Abschluss-Aktion:
  # neuer Status, Zuweisung (bleibt, Ticketersteller oder Rolle im Projekt)
  # und Kommentar ins Ticket. Prüft Redmines Workflow und Zuweisbarkeit.
  class Completion
    Option = Struct.new(:id, :label, :status, :assignee, :assign_label, :comment, :disabled_reason, keyword_init: true) do
      def enabled?
        disabled_reason.nil?
      end
    end

    attr_reader :planner, :issue

    def initialize(planner, issue)
      @planner = planner
      @issue = issue
    end

    def item
      @item ||= TeamPlanningItem.joins(:period).merge(TeamPlanningPeriod.open)
                                .where(team_planning_periods: { user_id: planner.user.id }).find_by(issue_id: issue.id)
    end

    # Passende Aktionen für das Projekt des Tickets, mit Grund, falls gesperrt
    def options
      Settings.done_actions.select { |action| applies?(action) }.map { |action| option(action) }
    end

    def complete(action_id = nil)
      raise Planner::Error, I18n.t(:error_team_planning_not_allowed) unless planner.editable?
      raise Planner::Error, I18n.t(:error_team_planning_not_planned) unless item

      option = action_id.present? ? options.find { |o| o.id == action_id } : nil
      raise Planner::Error, I18n.t(:error_team_planning_unknown_action) if action_id.present? && option.nil?
      raise Planner::Error, option.disabled_reason if option && !option.enabled?

      TeamPlanningItem.transaction do
        item.previous_status_id = issue.status_id
        item.previous_assigned_to_id = issue.assigned_to_id
        item.done = true
        item.save!
        apply(option) if option
      end
      option
    end

    # Haken entfernen; eine Abschluss-Aktion wird zurückgenommen, solange
    # niemand das Ticket seitdem weiterbearbeitet hat
    def reopen
      raise Planner::Error, I18n.t(:error_team_planning_not_allowed) unless planner.editable?
      raise Planner::Error, I18n.t(:error_team_planning_not_planned) unless item

      TeamPlanningItem.transaction do
        if item.previous_status_id && issue.status_id != item.previous_status_id
          issue.init_journal(planner.viewer)
          issue.status_id = item.previous_status_id
          issue.assigned_to_id = item.previous_assigned_to_id
          raise Planner::Error, issue.errors.full_messages.to_sentence unless issue.save
        end
        item.update!(done: false, previous_status_id: nil, previous_assigned_to_id: nil)
      end
    end

    def comment_text
      period = item&.period || planner.current_period
      Settings['comment_template'].to_s
              .gsub('{zeitraum}', period.label)
              .gsub('{stunden}', format_hours(planner.booked_for(issue, period)))
              .gsub('{person}', planner.user.name)
              .gsub('{datum}', I18n.l(planner.today))
    end

    private

    def applies?(action)
      ids = action['project_ids']
      ids.empty? || (issue.project.self_and_ancestors.pluck(:id) & ids).any?
    end

    def option(action)
      status = IssueStatus.find_by(id: action['status_id'])
      assignee, assign_label, reason = resolve_assignee(action)
      reason ||= I18n.t(:error_team_planning_status_missing) unless status
      if status && reason.nil? && status != issue.status && !issue.new_statuses_allowed_to(planner.viewer).include?(status)
        reason = I18n.t(:error_team_planning_workflow, status: status.name, project: issue.project.name)
      end
      Option.new(id: action['id'], label: action['label'], status: status, assignee: assignee,
                 assign_label: assign_label, comment: action['comment'], disabled_reason: reason)
    end

    def resolve_assignee(action)
      case action['assign']
      when 'author'
        [issue.author, I18n.t(:label_team_planning_assign_author), assignable_reason(issue.author)]
      when /\Arole:(\d+)\z/
        role = Role.find_by(id: Regexp.last_match(1))
        user = role && Member.joins(:member_roles).where(project_id: issue.project_id, member_roles: { role_id: role.id })
                             .includes(:principal).map(&:principal).find { |p| p.is_a?(User) && p.active? }
        label = I18n.t(:label_team_planning_assign_role, role: role&.name)
        reason = user ? assignable_reason(user) : I18n.t(:error_team_planning_role_empty, role: role&.name, project: issue.project.name)
        [user, label, reason]
      else
        [nil, I18n.t(:label_team_planning_assign_keep), nil]
      end
    end

    def assignable_reason(user)
      return I18n.t(:error_team_planning_cannot_assign) unless user && issue.assignable_users.include?(user)

      nil
    end

    def apply(option)
      issue.init_journal(planner.viewer, option.comment ? comment_text : '')
      issue.status = option.status if option.status
      issue.assigned_to = option.assignee if option.assignee
      raise Planner::Error, issue.errors.full_messages.to_sentence unless issue.save
    end

    def format_hours(value)
      "#{format('%g', value.round(2)).tr('.', ',')} h"
    end
  end
end
