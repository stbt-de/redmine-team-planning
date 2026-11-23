# frozen_string_literal: true

module RedmineTeamPlanning
  # Abschluss des laufenden Zeitraums: Ergebnis je Ticket, Rückblick,
  # Fokus für den nächsten Zeitraum. Langläufer (bis zu ihrer Zielwoche)
  # und Dauerthemen laufen automatisch weiter.
  class Closing
    DECISIONS = %w[next backlog close].freeze

    attr_reader :planner

    def initialize(planner)
      @planner = planner
    end

    def period
      planner.current_period
    end

    def next_period
      planner.periods[1]
    end

    def items
      planner.items(period)
    end

    def done_items
      items.select { |item| planner.done?(item) }
    end

    # Langläufer, deren Zielwoche nicht vor dem nächsten Zeitraum liegt
    def automatic_items
      items.reject { |item| planner.done?(item) }.select do |item|
        item.long? && (item.until_on.nil? || item.until_on >= next_period.starts_on)
      end
    end

    def open_items
      items.reject { |item| planner.done?(item) } - automatic_items
    end

    # decisions: { issue_id => next|backlog|close }, end_standing: [issue_id],
    # review: { good:, bad:, change: }, focus: Fokus des nächsten Zeitraums
    def call(decisions:, end_standing: [], review: {}, focus: nil)
      raise Planner::Error, I18n.t(:error_team_planning_not_allowed) unless planner.editable?

      decisions = decisions.to_h.transform_keys(&:to_i)
      missing = open_items.reject { |item| DECISIONS.include?(decisions[item.issue_id]) }
      raise Planner::Error, I18n.t(:error_team_planning_decisions_missing, count: missing.size) if missing.any?

      closed_period = period
      TeamPlanningPeriod.transaction do
        target = next_period
        target.save! if target.new_record?
        position = target.items.maximum(:position).to_i + 1

        done_items.each { |item| item.update!(result: 'done') }
        automatic_items.each do |item|
          item.update!(result: 'carried')
          position = carry(item, target, position)
        end
        open_items.each do |item|
          case decisions[item.issue_id]
          when 'next'
            item.update!(result: 'carried')
            position = carry(item, target, position)
          when 'backlog'
            item.update!(result: 'backlog')
          when 'close'
            close_issue(item.issue)
            item.update!(result: 'closed')
          end
        end
        Array(end_standing).map(&:to_i).each { |issue_id| end_standing!(issue_id) }

        closed_period.update!(closed_at: Time.current, review_good: review[:good].presence,
                              review_bad: review[:bad].presence, review_change: review[:change].presence)
        target.update!(focus: focus.presence) if focus.present?
      end
      planner.reset
      closed_period
    end

    private

    def carry(item, target, position)
      return position if target.items.exists?(issue_id: item.issue_id)

      TeamPlanningItem.create!(period: target, issue_id: item.issue_id, position: position, kind: item.kind,
                               until_on: item.until_on, planned_hours: item.planned_hours, origin: 'carried',
                               carry_ack: item.carry_ack)
      position + 1
    end

    def close_issue(issue)
      status = issue.new_statuses_allowed_to(planner.viewer).find(&:is_closed?)
      raise Planner::Error, I18n.t(:error_team_planning_cannot_close, issue: "##{issue.id}") unless status

      issue.init_journal(planner.viewer)
      issue.status = status
      raise Planner::Error, issue.errors.full_messages.to_sentence unless issue.save
    end

    public

    # Dauerthema beenden: Ticket schließen und aus den Dauerthemen nehmen
    def end_standing!(issue_id)
      standing = TeamPlanningStanding.find_by(user_id: planner.user.id, issue_id: issue_id)
      return unless standing

      close_issue(standing.issue) unless standing.issue.closed?
      standing.destroy
    end
  end
end
