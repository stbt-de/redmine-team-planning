# frozen_string_literal: true

module RedmineTeamPlanning
  # Teamrunde: nächster Termin, Stand je Person, Gliederung nach Projekt
  class TeamRound
    Entry = Struct.new(:user, :planner, :state, :period, keyword_init: true) do
      def prepared?
        state == :prepared
      end

      def open?
        state == :open
      end
    end

    attr_reader :viewer, :today

    def initialize(viewer = User.current, today: nil)
      @viewer = viewer
      @today = today || viewer&.today || Date.current
    end

    # Nächster Termin am eingestellten Wochentag, heute eingeschlossen
    def meeting_on
      wday = Settings.meeting_wday
      today + ((wday - today.cwday) % 7)
    end

    def meeting_week_start
      Planner.monday(meeting_on)
    end

    def round
      @round ||= TeamPlanningRound.for(meeting_on)
    end

    def earlier_rounds
      TeamPlanningRound.where(held_on: ...meeting_on).where.not(notes: [nil, '']).order(held_on: :desc).limit(10)
    end

    # Ohne Betrachter (Erinnerungsmail): alle, die planen
    def members
      return Access.team_members.to_a if viewer.nil?

      Access.team_members.select { |user| Access.view?(viewer, user) }
    end

    # Vorbereitet: der laufende Zeitraum beginnt in der Woche der Runde.
    # Läuft weiter: ein längerer Zeitraum reicht über die Runde hinaus.
    def entries
      @entries ||= members.map { |user| entry_for(user) }
    end

    def entry_for(user)
      planner = Planner.new(user, viewer || user, today: today)
      current = planner.current_period
      if current.starts_on >= meeting_week_start
        Entry.new(user: user, planner: planner, state: :prepared, period: current)
      elsif current.ends_on >= meeting_week_start
        Entry.new(user: user, planner: planner, state: :running, period: current)
      else
        Entry.new(user: user, planner: planner, state: :open, period: planner.periods[1])
      end
    end

    # Alle Tickets der besprochenen Zeiträume und alle Dauerthemen nach Hauptprojekt
    def by_project
      rows = entries.flat_map do |entry|
        entry.planner.items(entry.period).map { |item| [item.issue, entry, item] } +
          entry.planner.standings.map { |standing| [standing.issue, entry, nil] }
      end
      rows.group_by { |issue, _, _| issue.project.root }.sort_by { |project, _| project.name.downcase }
    end

    # Empfänger der Erinnerung: wer noch nicht vorbereitet hat (oder alle)
    def reminder_recipients
      list = Settings['reminder_recipients'] == 'all' ? entries : entries.select(&:open?)
      list.map(&:user).select { |user| user.mail.present? }
    end

    def reminder_due?(now = Time.current)
      return false unless Settings.enabled?('reminder_enabled')
      return false if round.reminded_at.present?

      offset, hour = Settings::REMINDER_TIMES.fetch(Settings['reminder_time'], Settings::REMINDER_TIMES['eve16'])
      send_at = (meeting_on + offset).in_time_zone.change(hour: hour)
      now >= send_at && now.to_date <= meeting_on
    end
  end
end
