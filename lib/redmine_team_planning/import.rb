# frozen_string_literal: true

module RedmineTeamPlanning
  # Übernahme aus einem Listenfeld mit Werten "KW 01" … "KW 53" (und
  # "Backlog"). "KW 48" wird zum Zeitraum der zugewiesenen Person, der in
  # dieser Woche beginnt; vergangene Wochen landen im laufenden Zeitraum
  # als übertragen, damit der erste Abschluss über sie entscheidet.
  # "Backlog" und leere Werte bleiben im Backlog. Das Feld selbst bleibt.
  class Import
    attr_reader :field, :year, :today

    def initialize(field, year:, today: Date.current)
      @field = field
      @year = year
      @today = today
    end

    def call
      result = { planned: 0, carried: 0, skipped: 0 }
      values.each do |issue, value|
        week = value[/\AKW\s*(\d{1,2})\z/i, 1]&.to_i
        next unless week

        user = issue.assigned_to
        unless user.is_a?(User)
          result[:skipped] += 1
          next
        end

        planner = Planner.new(user, User.current.admin? ? User.current : admin, today: today)
        next unless planner.location(issue) == 'backlog'

        start = Date.commercial(year, week, 1)
        target = planner.periods.find { |period| period.include?(start) }
        if target
          planner.move(issue, to: target.starts_on.iso8601)
          result[:planned] += 1
        elsif start < planner.current_period.starts_on
          planner.move(issue, to: planner.current_period.starts_on.iso8601)
          TeamPlanningItem.joins(:period).where(issue_id: issue.id, team_planning_periods: { user_id: user.id, closed_at: nil })
                          .update_all(origin: 'carried')
          result[:carried] += 1
        else
          planner.move(issue, to: 'later')
          result[:planned] += 1
        end
      rescue Date::Error
        next
      end
      result
    end

    private

    def admin
      @admin ||= User.active.find_by(admin: true)
    end

    def values
      CustomValue.where(custom_field_id: field.id, customized_type: 'Issue').where.not(value: [nil, ''])
                 .includes(customized: %i[status assigned_to]).filter_map do |custom_value|
        issue = custom_value.customized
        [issue, custom_value.value.strip] if issue && !issue.closed?
      end
    end
  end
end
