# frozen_string_literal: true

module RedmineTeamPlanning
  # Abschlüsse einer Woche: wer seinen Zeitraum abgeschlossen hat.
  # Jede Person schließt selbst ab; die Liste zeigt je Person den Zeitraum,
  # in dem die Woche liegt, und seinen Stand:
  #
  #   :closed   abgeschlossen (mit Datum, Link zur Detailansicht)
  #   :running  längerer Zeitraum, der nach dieser Woche weitergeht
  #   :open     endet mit dieser Woche, noch nicht abgeschlossen – oder ein
  #             früherer Zeitraum ist noch offen (dann liegt die Person zurück)
  #   :none     kein Zeitraum für diese Woche
  class ClosingOverview
    Entry = Struct.new(:user, :state, :period, keyword_init: true)

    STATE_ORDER = %i[open running closed none].freeze

    attr_reader :viewer, :week_start

    # Ohne Woche: die Woche vor der nächsten Teamrunde – die, die bis zur
    # Runde abgeschlossen sein soll
    def initialize(viewer = User.current, week: nil, today: nil)
      @viewer = viewer
      @today = today || viewer.today
      @week_start = Planner.monday(parse(week) || default_week)
    end

    def week_end
      week_start + 6
    end

    def label
      "KW #{week_start.cweek}"
    end

    def range_label
      "#{week_start.strftime('%-d.%-m.')}–#{(week_start + 4).strftime('%-d.%-m.')}"
    end

    def previous_week
      week_start - 7
    end

    def next_week
      week_start + 7
    end

    def default?
      week_start == Planner.monday(default_week)
    end

    def members
      Access.team_members.select { |user| Access.view?(viewer, user) }
    end

    # Offene zuerst (wer noch abschließen muss), dann nach Name
    def entries
      @entries ||= members.map { |user| entry_for(user) }
                          .sort_by { |entry| [STATE_ORDER.index(entry.state), entry.user.name.downcase] }
    end

    def closed_count
      entries.count { |entry| entry.state == :closed }
    end

    # Personen, für die diese Woche ein Abschluss fällig ist oder war
    def due_count
      entries.count { |entry| %i[closed open].include?(entry.state) }
    end

    private

    def entry_for(user)
      period = TeamPlanningPeriod.where(user_id: user.id).where(starts_on: ..week_start)
                                 .order(starts_on: :desc).detect { |p| p.include?(week_start) }
      period ||= TeamPlanningPeriod.open.where(user_id: user.id).where(starts_on: ...week_start)
                                   .order(:starts_on).first
      state = if period.nil? then :none
              elsif period.closed? then :closed
              elsif period.ends_on > week_end then :running
              else :open
              end
      Entry.new(user: user, state: state, period: period)
    end

    def default_week
      TeamRound.new(viewer, today: @today).meeting_week_start - 7
    end

    def parse(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
  end
end
